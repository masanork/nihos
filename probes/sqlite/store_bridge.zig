//! Host bridge: actual SQLite C VFS calls only the copy-owned store service.
const std = @import("std");
const experiment = @import("build_options").cache_experiment;
comptime {
    if (experiment) _ = @import("host_allocator");
}
extern fn nih_store_allocator_quotas() [*:0]const u8;
extern fn nih_store_rows() c_int;
extern fn nih_store_cache_pages() c_int;
extern fn nih_sqlite_checked_version() c_int;
extern fn nih_store_allocator_class_peaks() [*:0]const u8;
extern fn nih_store_memory_setup([*:0]const u8) c_int;
extern fn nih_store_memory_shutdown_ok() c_int;
extern fn nih_store_cache_kib() c_int;
extern fn nih_store_allocator_is_bounded() c_int;
extern fn nih_store_allocator_attempts() u64;
extern fn nih_store_allocator_injected() u64;
extern fn nih_store_allocator_rejected() u64;
extern fn nih_store_allocator_max_request() u64;
extern fn nih_store_allocator_parent_bytes() u64;
extern fn nih_store_allocator_reserved_bytes() u64;
extern fn nih_store_pagecache_bytes() u64;
extern fn nih_store_pagecache_cell_bytes() u64;
extern fn nih_store_pagecache_cells() u64;
const api = @import("checkpoint_service");
const model = api.model;
const File = @import("file_media").Media(16 * 1024 * 1024 * 1024);
const Device = struct {
    pub const capacity = File.capacity;
    file: *File,
    fail_sync: bool = false,
    pub fn read(self: *@This(), offset: u64, bytes: []u8) error{Io}!void {
        return self.file.read(offset, bytes);
    }
    pub fn write(self: *@This(), offset: u64, bytes: []const u8) error{Io}!void {
        return self.file.write(offset, bytes);
    }
    pub fn sync(self: *@This()) error{Io}!void {
        if (self.fail_sync) {
            self.fail_sync = false;
            return error.Io;
        }
        return self.file.sync();
    }
};
const Store = model.Store(Device, .{ .index_pages = 256, .payload_start_page = Device.capacity / 4096 - 32768, .payload_reserve_pages = 16, .leaf_cache_pages = 128 });
const Owner = api.Owner(Store);
const Queues = api.Queues(@import("spsc_ring"));
const Handle = extern struct { slot: u32, reserved: u32, generation: u64 };
var store = Store{};
// SAFETY: main assigns the open file before Store I/O or C callbacks.
var device: Device = undefined;
// SAFETY: main initializes the owner before publishing active to C callbacks.
var owner: Owner = undefined;
var queues = Queues{};
// SAFETY: both grants are initialized before active becomes true.
var handles: [2]api.Handle = undefined;
// SAFETY: main assigns process I/O before reporting or invoking C.
var host_io: std.Io = undefined;
var command: []const u8 = "";
var active = false;
var sync_error_injected = false;
var unknown_publications: usize = 0;
var requests: usize = 0;
extern fn nih_sqlite_store_run([*:0]const u8) c_int;
extern fn nih_sqlite_peak() u64;
extern fn nih_sqlite_committed() c_int;
extern fn nih_sqlite_failure_cleanup() c_int;
extern fn nih_sqlite_observed_error() c_int;
extern fn nih_sqlite_version() [*:0]const u8;
fn call(handle: api.Handle, operation: api.Operation, offset: u64, length: u32, input: ?[]const u8) api.Response {
    var request = api.Request{ .epoch = owner.epoch, .sequence = owner.next_sequence, .handle = handle, .operation = @backingInt(operation), .offset = offset, .length = length };
    if (input) |bytes| @memcpy(request.data[0..bytes.len], bytes);
    if (!queues.requests.tryPush(request)) return .{ .status = .busy };
    requests += 1;
    while (true) switch (owner.step(&queues, .{})) {
        .pending => {},
        .idle => return .{ .status = .recovery_required },
        .completed => {
            const reply = queues.responses.tryPop() orelse return .{ .status = .recovery_required };
            if (!api.matches(&reply, request.epoch, request.sequence)) return .{ .status = .recovery_required };
            return reply;
        },
    };
}
fn key(handle: *const Handle) ?api.Handle {
    if (!active or handle.reserved != 0) return null;
    return .{ .slot = handle.slot, .generation = handle.generation };
}
pub export fn nih_store_open(kind: u32, out: *Handle) c_int {
    if (!active or kind == 0 or kind > 2) return -22;
    const h = handles[kind - 1];
    out.* = .{ .slot = h.slot, .reserved = 0, .generation = h.generation };
    return 0;
}
pub export fn nih_store_size(handle: *const Handle, length: *u64) c_int {
    const h = key(handle) orelse return -9;
    const result = call(h, .stat, 0, 0, null);
    length.* = result.size;
    return @backingInt(result.status);
}
pub export fn nih_store_resize(handle: *const Handle, length: u64) c_int {
    const h = key(handle) orelse return -9;
    return @backingInt(call(h, .truncate, length, 0, null).status);
}
pub export fn nih_store_read(handle: *const Handle, offset: u64, data: [*]u8, bytes: u32, actual: *u32) c_int {
    const h = key(handle) orelse return -9;
    actual.* = 0;
    if (offset > Device.capacity or bytes > Device.capacity - offset) return -22;
    while (actual.* < bytes) {
        const n = @min(api.io_bytes, bytes - actual.*);
        const result = call(h, .read, offset + actual.*, n, null);
        if (result.status != .ok) return @backingInt(result.status);
        @memcpy(data[actual.*..][0..result.length], result.data[0..result.length]);
        actual.* += result.length;
        if (result.length < n) break;
    }
    return 0;
}
pub export fn nih_store_write(handle: *const Handle, offset: u64, data: [*]const u8, bytes: u32) c_int {
    const h = key(handle) orelse return -9;
    if (offset > Device.capacity or bytes > Device.capacity - offset) return -22;
    var length: u64 = 0;
    const stat = nih_store_size(handle, &length);
    if (stat != 0) return stat;
    if (offset + bytes > length) {
        const resize = nih_store_resize(handle, offset + bytes);
        if (resize != 0) return resize;
    }
    var done: u32 = 0;
    while (done < bytes) {
        const n = @min(api.io_bytes, bytes - done);
        const result = call(h, .write, offset + done, n, data[done..][0..n]);
        if (result.status != .ok) return @backingInt(result.status);
        if (result.transferred != n) return -5;
        done += n;
    }
    return 0;
}
pub export fn nih_store_sync(handle: *const Handle) c_int {
    const h = key(handle) orelse return -9;
    if (std.mem.eql(u8, command, "sync-error") and !sync_error_injected) {
        device.fail_sync = true;
        sync_error_injected = true;
    }
    const result = call(h, .sync, 0, 0, null);
    if (result.status == .publication_unknown) unknown_publications += 1;
    return @backingInt(result.status);
}
fn journalHot() bool {
    const result = call(handles[1], .read, 0, 8, null);
    return result.status == .ok and result.length == 8 and std.mem.eql(u8, result.data[0..8], &.{ 0xd9, 0xd5, 0x05, 0xf9, 0x20, 0xa1, 0x63, 0xd7 });
}
fn report(point: u32, committed: bool) !void {
    const hot = if (!owner.alive or owner.recovery_required) false else journalHot();
    var buffer: [2048]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(host_io, &buffer);
    try stdout.interface.print("{{\"phase\":\"{s}\",\"sqlite_version\":\"{s}\",\"sqlite_peak_bytes\":{d},\"sqlite_error\":{d},\"cache_kib\":{d},\"cache_pages\":{d},\"rows\":{d},\"checked_version\":{d},\"allocator_quotas\":{s},\"bounded_allocator\":{},\"allocator_clean\":{},\"allocator_class_peaks\":{s},\"allocator_attempts\":{d},\"allocator_injected\":{d},\"allocator_rejected\":{d},\"allocator_max_request\":{d},\"allocator_parent_bytes\":{d},\"allocator_reserved_bytes\":{d},\"pagecache_bytes\":{d},\"pagecache_cell_bytes\":{d},\"pagecache_cells\":{d},", .{ command, std.mem.span(nih_sqlite_version()), nih_sqlite_peak(), nih_sqlite_observed_error(), if (experiment) nih_store_cache_kib() else @as(c_int, 32), if (experiment) nih_store_cache_pages() else @as(c_int, 8), if (experiment) nih_store_rows() else @as(c_int, 64), nih_sqlite_checked_version(), if (experiment) std.mem.span(nih_store_allocator_quotas()) else "[]", experiment and nih_store_allocator_is_bounded() != 0, !experiment or nih_store_memory_shutdown_ok() != 0, if (experiment) std.mem.span(nih_store_allocator_class_peaks()) else "[]", if (experiment) nih_store_allocator_attempts() else @as(u64, 0), if (experiment) nih_store_allocator_injected() else @as(u64, 0), if (experiment) nih_store_allocator_rejected() else @as(u64, 0), if (experiment) nih_store_allocator_max_request() else @as(u64, 0), if (experiment) nih_store_allocator_parent_bytes() else @as(u64, 0), if (experiment) nih_store_allocator_reserved_bytes() else @as(u64, 0), if (experiment) nih_store_pagecache_bytes() else @as(u64, 0), if (experiment) nih_store_pagecache_cell_bytes() else @as(u64, 0), if (experiment) nih_store_pagecache_cells() else @as(u64, 0) });
    try stdout.interface.print("\"point\":{d},\"sql_committed\":{},\"generation\":{d},\"journal_hot\":{},\"writes\":{d},\"syncs\":{d},\"requests\":{d},\"unknown_publications\":{d},\"recovery_required\":{},\"payload_high_water_pages\":{d},\"store_bytes\":{d},\"owner_bytes\":{d},\"queue_bytes\":{d}}}\n", .{ point, committed, store.generation(), hot, device.file.writes, device.file.syncs, requests, unknown_publications, owner.recovery_required, store.current.payload_next - Store.payload_start, @sizeOf(Store), @sizeOf(Owner), @sizeOf(Queues) });
    try stdout.interface.flush();
}
fn wait() !void {
    var byte: [1]u8 = undefined;
    _ = try std.Io.File.stdin().readStreaming(host_io, &.{&byte});
    return error.UnexpectedResume;
}
pub export fn nih_store_cutpoint(kind: u32) void {
    if ((kind == 1 and std.mem.eql(u8, command, "db-sync-wait")) or (kind == 2 and std.mem.eql(u8, command, "journal-sync-wait"))) {
        report(kind, false) catch @panic("report failed");
        wait() catch @panic("unexpected resume");
    }
}
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 3 or args.len > 4) return error.Usage;
    command = args[1];
    host_io = init.io;
    var file = try File.open(init.io, .cwd(), args[2]);
    defer file.close();
    device = .{ .file = &file };
    if (std.mem.eql(u8, command, "seed")) {
        try store.format(&device);
        try store.begin();
        try store.put(1, "");
        try store.put(2, "");
        try store.commit();
    } else try store.recover(&device);
    owner = try Owner.init(&store, 11);
    handles[0] = try owner.grant(1, true);
    handles[1] = try owner.grant(2, true);
    active = true;
    if (std.mem.eql(u8, command, "export-db")) {
        if (args.len != 4) return error.Usage;
        const output = try std.Io.Dir.cwd().createFile(init.io, args[3], .{ .exclusive = true });
        defer output.close(init.io);
        const size = call(handles[0], .stat, 0, 0, null).size;
        var offset: u64 = 0;
        while (offset < size) {
            const result = call(handles[0], .read, offset, @intCast(@min(api.io_bytes, size - offset)), null);
            if (result.status != .ok or result.length == 0) return error.ExportFailed;
            try output.writeStreamingAll(init.io, result.data[0..result.length]);
            offset += result.length;
        }
        try output.sync(init.io);
        return report(0, false);
    }
    var command_z: [64:0]u8 = @splat(0);
    if (command.len >= command_z.len) return error.Usage;
    @memcpy(command_z[0..command.len], command);
    if (experiment) {
        if (args.len != 4) return error.ProfileRequired;
        var profile: [64:0]u8 = @splat(0);
        if (args[3].len >= profile.len) return error.Usage;
        @memcpy(profile[0..args[3].len], args[3]);
        if (nih_store_memory_setup(&profile) != 0) return error.MemorySetupFailed;
    }
    const result = nih_sqlite_store_run(&command_z);
    if (result != 0) {
        _ = try owner.clientExited(11, &queues);
        if (experiment) {
            if (nih_sqlite_failure_cleanup() != 0 or nih_store_memory_shutdown_ok() == 0) return error.AllocatorLeak;
            try report(0, nih_sqlite_committed() != 0);
        }
        return error.SQLiteProbeFailed;
    }
    if (std.mem.eql(u8, command, "commit-wait")) {
        try report(0, true);
        return wait();
    }
    if (std.mem.eql(u8, command, "sync-error") and (!owner.recovery_required or unknown_publications != 1)) return error.ErrorNotPropagated;
    _ = try owner.clientExited(11, &queues);
    try report(0, std.mem.eql(u8, command, "seed") or std.mem.eql(u8, command, "update"));
    active = false;
}
