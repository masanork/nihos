//! Opt-in two-task storage qualification after the ordinary SMP/IPI fixture.
//! Queue payloads/FS state live in reserved PSRAM; IRQs touch resident flags only.
const std = @import("std");
const rpc = @import("storage_rpc");
const calls = @import("task_calls");
pub const panic = std.debug.no_panic;
const timer_group = @import("timer_group");
extern fn nih_storage_controller_begin() callconv(.c) u32;
extern fn nih_storage_controller_end() callconv(.c) void;
const A = std.atomic.Value(u32);
const Info = extern struct { kind: u32, size: u32 };
const Entry = extern struct { kind: u32, size: u32, name: [256]u8 };
const Session = opaque {};
extern fn nih_ro_init(*[8192]u8, u32, *const fn (?*anyopaque, u32, *[512]u8) callconv(.c) i32, ?*anyopaque) callconv(.c) ?*Session;
extern fn nih_ro_mount(*Session, u32) callconv(.c) i32;
extern fn nih_ro_stat(*Session, [*]const u8, u32, *Info) callconv(.c) i32;
extern fn nih_ro_list_root(*Session, u32, *Entry) callconv(.c) i32;
extern fn nih_ro_open(*Session, u32, [*]const u8, u32, *u32) callconv(.c) i32;
extern fn nih_ro_read_at(*Session, u32, u32, u32, [*]u8, u32) callconv(.c) i32;
extern fn nih_ro_close(*Session, u32, u32) callconv(.c) i32;
extern fn nih_ro_release_owner(*Session, u32) callconv(.c) i32;
extern fn nih_ro_destroy(*Session) callconv(.c) i32;
extern fn nih_task_identity() callconv(.c) u32;
extern fn nih_storage_clock_start() callconv(.c) u32;
extern fn nih_storage_read(u32, *[512]u8) callconv(.c) i32;
extern fn nih_native_task_failed() callconv(.c) noreturn;
extern fn nih_rom_putc(u8) callconv(.c) i32;
extern fn nih_sqlite_stack_paint(u32) callconv(.c) u32;

var flags: [2]A = @splat(.init(0));
var handles: [2]A = @splat(.init(0));
var identities: [2]A = @splat(.init(0));
var exited = A.init(0);
var cleanup = A.init(0);
var retired = A.init(0);
var batch_ready = A.init(0);
var owner_ready = A.init(0);
var cancel_mode = A.init(0);
var inflight = A.init(0);
var cancel_requested = A.init(0);
var polls: [2]A = @splat(.init(0));
var bounds: [2]struct { low: u32 = 0, high: u32 = 0 } = @splat(.{});
pub const Report = @import("storage_service_abi.zig").Report;
const State = struct {
    queues: rpc.Queues(@import("spsc_ring")) = .{},
    report: Report = .{},
    client_request: rpc.Request = .{},
    client_response: rpc.Response = .{},
    client_path: [256]u8 = @splat(0),
    next_sequence: u32 = 3,
    client_epoch: u32 = 1,
    old_kernel_handle: u32 = 0,
    old_file_handle: u32 = 0,
    path_length: u32 = 0,
};
comptime {
    if (@sizeOf(State) > 8192) @compileError("storage IPC reservation too small");
}
fn state() *State {
    return @ptrFromInt(0x48004000);
}
fn clock() timer_group.Timer {
    return timer_group.Timer.fromGroup(0x500c3000, 0).?;
}
inline fn signal(hart: u32) void {
    _ = flags[hart].fetchOr(1, .release);
    @as(*volatile u32, @ptrFromInt(0x500e5010 + hart * 4)).* = 1;
    asm volatile ("fence iorw, iorw" ::: .{ .memory = true });
}
fn fail(step: u32, code: i32) noreturn {
    for ("NIHOS_STORAGE_RUNTIME_DETAIL ") |c| _ = nih_rom_putc(c);
    for ([_]u32{ step, @bitCast(code) }) |word| {
        var shift: u6 = 28;
        while (true) {
            const digit: u8 = @intCast((word >> @as(u5, @intCast(shift))) & 15);
            _ = nih_rom_putc(if (digit < 10) '0' + digit else 'a' + digit - 10);
            if (shift == 0) break;
            shift -= 4;
        }
        _ = nih_rom_putc(' ');
    }
    _ = nih_rom_putc('\n');
    nih_native_task_failed();
}
fn wait() void {
    switch (calls.waitEvents(1)) {
        .received => {},
        .failed => |code| fail(1, code),
    }
}
pub export fn nih_storage_runtime_init() callconv(.c) void {
    state().* = .{};
    if (nih_storage_clock_start() != 1) fail(2, -2);
    const t = clock();
    if (t.channel.config >> 13 & 0xffff != 40 or t.channel.config & timer_group.counter_enable == 0 or
        t.channel.config & timer_group.alarm_enable != 0 or t.counter() == null) fail(2, -1);
    state().report.clock_ok = 1;
}
// Called with MIE clear: no PSRAM, no backend calls, no allocation.
pub export fn nih_storage_register(hart: u32, handle: u32, low: u32, high: u32) linksection(".iram1.storage_hooks") callconv(.c) void {
    bounds[hart] = .{ .low = low, .high = high };
    if (hart == 1 and handles[1].load(.acquire) != 0) {
        // Both client execution and its first cleanup are complete. The owner
        // waits for the new identity; reset only resident handshake flags here.
        identities[1].store(0, .release);
        owner_ready.store(0, .release);
        exited.store(0, .release);
        cancel_mode.store(0, .release);
        cancel_requested.store(0, .release);
        cleanup.store(0, .release);
    }
    handles[hart].store(handle, .release);
    if (flags[hart].load(.acquire) != 0) signal(hart);
    signal(hart ^ 1);
}
pub export fn nih_storage_pending(hart: u32) linksection(".iram1.storage_hooks") callconv(.c) u32 {
    return flags[hart].swap(0, .acq_rel);
}
pub export fn nih_storage_task_exited(hart: u32, handle: u32) linksection(".iram1.storage_hooks") callconv(.c) void {
    if (hart == 1 and handles[1].load(.acquire) == handle) {
        exited.store(1, .release);
        signal(0);
    }
}
pub export fn nih_storage_cancel_requested() linksection(".iram1.storage_hooks") callconv(.c) u32 {
    return cancel_requested.load(.acquire);
}
pub export fn nih_storage_cleanup_ready() linksection(".iram1.storage_hooks") callconv(.c) u32 {
    return cleanup.load(.acquire);
}
pub export fn nih_storage_retired(hart: u32) linksection(".iram1.storage_hooks") callconv(.c) void {
    _ = retired.fetchOr(@as(u32, 1) << @intCast(hart), .release);
}
fn finished() bool {
    return retired.load(.acquire) == 3;
}
pub export fn nih_storage_runtime_finished() callconv(.c) u32 {
    return @intFromBool(finished());
}
pub export fn nih_storage_runtime_poll(hart: u32) callconv(.c) void {
    _ = polls[hart].fetchAdd(1, .monotonic);
}

fn backendRead(_: ?*anyopaque, lba: u32, data: *[512]u8) callconv(.c) i32 {
    return nih_storage_read(lba, data);
}
const Backend = struct {
    pub const flash_code = true;
    session: *Session,
    pub fn list(self: *@This(), index: u32, response: *rpc.Response) i32 {
        // SAFETY: C fills the complete entry on positive return; otherwise it is not read.
        var entry: Entry = undefined;
        const code = nih_ro_list_root(self.session, index, &entry);
        if (code > 0) {
            response.kind = entry.kind;
            response.size = entry.size;
            const n = std.mem.indexOfScalar(u8, &entry.name, 0) orelse return -5;
            response.length = @intCast(n);
            @memcpy(response.data[0..n], entry.name[0..n]);
        }
        return code;
    }
    pub fn stat(self: *@This(), path: []const u8, response: *rpc.Response) i32 {
        // SAFETY: C fills both fields on success; they are consumed only on success.
        var info: Info = undefined;
        const code = nih_ro_stat(self.session, path.ptr, @intCast(path.len), &info);
        if (code == 0) {
            response.kind = info.kind;
            response.size = info.size;
        }
        return code;
    }
    pub fn open(self: *@This(), owner: u32, path: []const u8, handle: *u32) i32 {
        return nih_ro_open(self.session, owner, path.ptr, @intCast(path.len), handle);
    }
    pub fn read(self: *@This(), owner: u32, handle: u32, offset: u32, data: []u8) i32 {
        const code = nih_ro_read_at(self.session, owner, handle, offset, data.ptr, @intCast(data.len));
        // Qualification barrier AFTER synchronous block/DMA completion. Do
        // not abort a controller transaction or release its workspace in IRQ.
        if (cancel_mode.load(.acquire) == 1 and offset == 1) {
            if (code != 512) fail(36, code);
            inflight.store(1, .release);
            signal(1);
            while (exited.load(.acquire) == 0) wait();
            state().report.inflight_completed = 1;
        }
        return code;
    }
    pub fn close(self: *@This(), owner: u32, handle: u32) i32 {
        return nih_ro_close(self.session, owner, handle);
    }
    pub fn release(self: *@This(), owner: u32) i32 {
        return nih_ro_release_owner(self.session, owner);
    }
};
fn measure(hart: u32, painted: u32) u32 {
    var first = bounds[hart].low;
    while (first < painted) : (first += 4) {
        if (@as(*const volatile u32, @ptrFromInt(first)).* != 0x5a7ec319) break;
    }
    if (first <= bounds[hart].low + 160) fail(3, @bitCast(first));
    return bounds[hart].high - first;
}
noinline fn serve() linksection(".flash.text.storage") i32 {
    const painted = nih_sqlite_stack_paint(bounds[0].low);
    while (identities[1].load(.acquire) == 0) wait();
    const began = clock().counter() orelse fail(4, -1);
    const peer_before = polls[1].load(.acquire);
    const sectors = nih_storage_controller_begin();
    if (sectors == 0) fail(5, -1);
    const session = nih_ro_init(@ptrFromInt(0x48001000), 8192, &backendRead, null) orelse fail(6, -1);
    const mounted = nih_ro_mount(session, sectors);
    if (mounted != 0) fail(7, mounted);
    var server = rpc.Owner(Backend){ .backend = .{ .session = session }, .client = identities[1].load(.acquire) };
    state().report.owner = server.client;
    owner_ready.store(1, .release);
    signal(1);
    while (batch_ready.load(.acquire) == 0) wait();
    while (exited.load(.acquire) == 0) {
        if (server.step(&state().queues)) {
            signal(1);
            continue;
        }
        wait();
    }
    state().report.exit_seen = 1;
    if (server.clientExited(&state().queues) != 0) fail(8, -1);
    state().report.released = 1;
    state().report.discarded_requests = server.discarded_requests;
    state().report.discarded_responses = server.discarded_responses;
    state().report.forced_exit = cancel_requested.load(.acquire);
    if (server.dispatch(.{ .sequence = 1, .operation = 4 }).status != -13) fail(9, -1);
    state().report.stale_rejected = 1;
    if (state().queues.requests.countApprox() != 0 or state().queues.responses.countApprox() != 0) fail(10, -1);
    // Keep the mount and monotonically increasing file tokens through the
    // endpoint restart. Ack lets CPU1 reap the stopped task and reuse its slot.
    cleanup.store(1, .release);
    signal(1);
    while (identities[1].load(.acquire) == 0 or identities[1].load(.acquire) == server.client) wait();
    if (!server.rebind(identities[1].load(.acquire), &state().queues)) fail(40, -1);
    state().report.rebound = 1;
    state().report.replacement_owner = server.client;
    // Deliberately inject an old-epoch reply with the matching sequence to
    // prove that the replacement does not accept it as its first response.
    if (!state().queues.responses.tryPush(.{ .epoch = 1, .sequence = 1, .status = -9 })) fail(41, -1);
    owner_ready.store(1, .release);
    signal(1);
    while (exited.load(.acquire) == 0) {
        if (server.step(&state().queues)) {
            signal(1);
            continue;
        }
        wait();
    }
    if (server.clientExited(&state().queues) != 0 or state().queues.requests.countApprox() != 0 or
        state().queues.responses.countApprox() != 0 or server.discarded_requests != 2 or server.discarded_responses != 2) fail(42, -1);
    state().report.replacement_exit = 1;
    state().report.requests = server.processed;
    state().report.rejected = server.rejected;
    if (nih_ro_destroy(session) != 0) fail(11, -1);
    const bytes: *volatile [8192]u8 = @ptrFromInt(0x48001000);
    for (bytes) |byte| if (byte != 0) fail(12, -1);
    state().report.fs_cleared = 1;
    nih_storage_controller_end();
    state().report.elapsed_us = @intCast((clock().counter() orelse fail(13, -1)) - began);
    state().report.peer_polls = polls[1].load(.acquire) -% peer_before;
    state().report.owner_stack = measure(0, painted);
    cleanup.store(2, .release);
    signal(1);
    return 300;
}
noinline fn receive() linksection(".flash.text.storage") *const rpc.Response {
    while (true) {
        if (state().queues.responses.tryPop()) |response| {
            signal(0);
            if (response.epoch != state().client_epoch) {
                state().report.old_reply_rejected += 1;
                continue;
            }
            state().client_response = response;
            state().report.responses += 1;
            return &state().client_response;
        }
        wait();
    }
}
noinline fn pushRequest() bool {
    return state().queues.requests.tryPush(state().client_request);
}
noinline fn exchange(operation: u32, handle: u32, offset: u32, length: u32, path_length: u32) linksection(".flash.text.storage") *const rpc.Response {
    const request = &state().client_request;
    request.epoch = state().client_epoch;
    request.sequence = state().next_sequence;
    state().next_sequence += 1;
    request.operation = operation;
    request.handle = handle;
    request.offset = offset;
    request.length = length;
    request.path_length = path_length;
    if (path_length != 0) @memcpy(request.path[0..path_length], state().client_path[0..path_length]);
    if (!pushRequest()) fail(14, -1);
    signal(0);
    const response = receive();
    if (!rpc.responseMatches(response, request.epoch, request.sequence)) fail(15, -1);
    return response;
}
noinline fn client() linksection(".flash.text.storage") i32 {
    const painted = nih_sqlite_stack_paint(bounds[1].low);
    while (owner_ready.load(.acquire) == 0) wait();
    state().client_request.epoch = 1;
    state().old_kernel_handle = handles[1].load(.acquire);
    for (1..3) |number| {
        state().client_request.sequence = @intCast(number);
        state().client_request.operation = 1;
        if (!pushRequest()) fail(16, -1);
    }
    state().client_request.sequence = 3;
    if (pushRequest()) fail(16, -2);
    state().report.queue_full = 1;
    batch_ready.store(1, .release);
    signal(0);
    if (receive().sequence != 1 or receive().sequence != 2) fail(17, -1);
    var size: u32 = 65537;
    var n: u32 = 0;
    for (0..128) |index| {
        const row = exchange(1, 0, @intCast(index), 0, 0);
        if (row.status == 0) break;
        if (row.status != 1) fail(18, row.status);
        if (row.kind == 1 and row.size != 0 and row.size < size and row.length <= 254) {
            size = row.size;
            n = row.length + 1;
            state().client_path[0] = '/';
            @memcpy(state().client_path[1..n], row.data[0..row.length]);
        }
    }
    if (n == 0) fail(19, -1);
    const info = exchange(2, 0, 0, 0, n);
    if (info.status != 0 or info.size != size or info.kind != 1) fail(35, info.status);
    const opened = exchange(3, 0, 0, 0, n);
    if (opened.status != 0) fail(20, opened.status);
    const handle = opened.handle;
    var crc: u32 = 0xffff_ffff;
    var offset: u32 = 0;
    while (offset < size) {
        const row = exchange(4, handle, offset, @min(512, size - offset), 0);
        if (row.status <= 0 or row.length != @as(u32, @intCast(row.status)) or row.length > size - offset) fail(21, row.status);
        for (row.data[0..row.length]) |byte| {
            crc ^= byte;
            for (0..8) |_| crc = (crc >> 1) ^ (if (crc & 1 != 0) @as(u32, 0xedb88320) else 0);
        }
        offset += row.length;
    }
    if (exchange(4, handle, size, 1, 0).status != 0) fail(22, -1);
    if (exchange(4, handle, 0, 513, 0).status != -22) fail(23, -1);
    if (exchange(99, 0, 0, 0, 0).status != -22) fail(24, -1);
    if (exchange(4, handle + 100, 0, 1, 0).status != -9) fail(25, -1);
    if (exchange(5, handle, 0, 0, 0).status != 0) fail(26, -1);
    if (exchange(4, handle, 0, 1, 0).status != -9) fail(27, -1);
    const abandoned = exchange(3, 0, 0, 0, n);
    if (abandoned.status != 0 or abandoned.handle == handle) fail(28, abandoned.status);
    const abandoned_handle = abandoned.handle;
    state().old_file_handle = abandoned_handle;
    state().path_length = n;
    if (exchange(5, handle, 0, 0, 0).status != -9) fail(29, -1);
    state().report.bytes = offset;
    state().report.crc = ~crc;
    // Leave a completed reply unread, then suspend the next read inside its
    // backend call. Once it is suspended, fill the request ring behind it.
    cancel_mode.store(1, .release);
    for (0..2) |index| {
        state().client_request = .{ .epoch = 1, .sequence = state().next_sequence, .operation = 4, .handle = abandoned_handle, .offset = @intCast(index), .length = if (index == 0) 1 else 512 };
        state().next_sequence += 1;
        if (!pushRequest()) fail(37, -1);
    }
    signal(0);
    while (inflight.load(.acquire) == 0) wait();
    if (state().queues.responses.countApprox() != 1) fail(38, -1);
    for (0..2) |_| {
        state().client_request.sequence = state().next_sequence;
        state().next_sequence += 1;
        if (!pushRequest()) fail(39, -1);
    }
    state().report.client_stack = measure(1, painted);
    cancel_requested.store(1, .release);
    // Bootstrap terminates this blocked task. No instruction after the wait
    // may execute once cancellation has been acknowledged by the scheduler.
    while (true) wait();
}
noinline fn replacement() linksection(".flash.text.storage") i32 {
    const painted = nih_sqlite_stack_paint(bounds[1].low);
    while (owner_ready.load(.acquire) == 0) wait();
    nih_storage_task_exited(1, state().old_kernel_handle);
    if (exited.load(.acquire) != 0) fail(43, -1);
    state().report.old_exit_rejected = 1;
    state().client_epoch = 2;
    state().client_request = .{ .epoch = 1, .sequence = 1, .operation = 4, .handle = state().old_file_handle, .length = 1 };
    if (!pushRequest()) fail(44, -1);
    signal(0);
    const stale = receive();
    if (!rpc.responseMatches(stale, 2, 1) or stale.status != -13) fail(45, stale.status);
    state().report.old_epoch_rejected = 1;
    state().next_sequence = 1;
    if (exchange(4, state().old_file_handle, 0, 1, 0).status != -9) fail(46, -1);
    state().report.old_handle_rejected = 1;
    const opened = exchange(3, 0, 0, 0, state().path_length);
    if (opened.status != 0 or opened.handle == state().old_file_handle) fail(47, opened.status);
    const handle = opened.handle;
    if (exchange(4, state().old_file_handle, 0, 1, 0).status != -9) fail(48, -1);
    state().report.old_handle_rejected += 1;
    var offset: u32 = 0;
    var crc: u32 = 0xffff_ffff;
    while (offset < state().report.bytes) {
        const row = exchange(4, handle, offset, @min(512, state().report.bytes - offset), 0);
        if (row.status <= 0 or row.length != @as(u32, @intCast(row.status)) or row.length > state().report.bytes - offset) fail(49, row.status);
        for (row.data[0..row.length]) |byte| {
            crc ^= byte;
            for (0..8) |_| crc = (crc >> 1) ^ (if (crc & 1 != 0) @as(u32, 0xedb88320) else 0);
        }
        offset += row.length;
    }
    state().report.replacement_bytes = offset;
    state().report.replacement_crc = ~crc;
    state().report.client_stack = @max(state().report.client_stack, measure(1, painted));
    return 301; // Leave the new file open to qualify a second owner release.
}
pub export fn nih_storage_task_entry(hart: u32) linksection(".flash.text.storage") callconv(.c) i32 {
    const current = calls.current() orelse fail(30, -1);
    if ((@as(u32, current.generation) << 16 | current.slot) != handles[hart].load(.acquire)) fail(31, -1);
    const identity = nih_task_identity();
    if (identity == 0) fail(32, -1);
    identities[hart].store(identity, .release);
    signal(hart ^ 1);
    return if (hart == 0) serve() else if (state().old_kernel_handle != 0) replacement() else client();
}
pub export fn nih_storage_runtime_finish(result: *Report) callconv(.c) void {
    if (!finished() or cleanup.load(.acquire) != 2 or polls[1].load(.acquire) == 0) fail(33, -1);
    var report = state().report;
    const bytes: *volatile [8192]u8 = @ptrFromInt(0x48004000);
    for (bytes) |*byte| byte.* = 0;
    for (bytes) |byte| if (byte != 0) fail(34, -1);
    clock().stop();
    report.ipc_cleared = 1;
    report.status = 1;
    result.* = report;
}
