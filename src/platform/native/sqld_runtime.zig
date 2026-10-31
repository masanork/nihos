//! Permanent CPU0 SQLite owner. I/O belongs to the separate normal SD task.
const std = @import("std");
pub const panic = std.debug.no_panic;
const calls = @import("task_calls");
const control = @import("task_control");
const timers = @import("timer_group");
const options = @import("native_options");
const abi = @import("sqld_wire.zig");
const layout = @import("sqld_layout.zig");
extern fn nih_normal_sqld_grant(u32, u32) callconv(.c) i32;
extern fn nih_normal_sqld_io(u32, u32, *[512]u8) callconv(.c) i32;
extern fn nih_sqld_wake(u32) callconv(.c) void;
extern fn nih_sqld_size() callconv(.c) usize;
extern fn nih_store_size() callconv(.c) usize;
extern fn nih_store_mount(*anyopaque, usize, *const Device, c_int) callconv(.c) c_int;
extern fn nih_store_generation(*anyopaque) callconv(.c) u64;
extern fn nih_sqld_native_allocator(*anyopaque, u32) callconv(.c) c_int;
extern fn nih_sqld_start(*anyopaque, usize, *anyopaque, *const Platform, u32, u32) callconv(.c) c_int;
extern fn nih_sqld_submit(*anyopaque, u32, *const abi.Request) callconv(.c) c_int;
extern fn nih_sqld_take(*anyopaque, u32, *abi.Response) callconv(.c) c_int;
extern fn nih_sqld_step(*anyopaque) callconv(.c) c_int;
extern fn nih_sqld_failed(*anyopaque) callconv(.c) c_int;
extern fn sqlite3_memory_used() callconv(.c) i64;
const Device = extern struct {
    context: ?*anyopaque,
    read: *const fn (?*anyopaque, u64, [*]u8, usize) callconv(.c) c_int,
    write: *const fn (?*anyopaque, u64, [*]const u8, usize) callconv(.c) c_int,
    sync: *const fn (?*anyopaque) callconv(.c) c_int,
};
const Platform = extern struct {
    context: ?*anyopaque,
    identity: *const fn (?*anyopaque) callconv(.c) u32,
    random: *const fn (?*anyopaque, [*]u8, c_int) callconv(.c) c_int,
    time_ms: *const fn (?*anyopaque) callconv(.c) i64,
    sleep_us: *const fn (?*anyopaque, c_int) callconv(.c) c_int,
    monotonic_ms: *const fn (?*anyopaque) callconv(.c) i64,
    transaction_timeout_ms: u32,
};
const State = struct {
    principal: u32 = 0,
    owner: u32 = 0,
    epoch: u32 = 1,
    sequence: u32 = 0,
    granted: bool = false,
    started: bool = false,
    allocator_ready: bool = false,
    report: abi.Report = .{},
    sector: [512]u8 = @splat(0),
    last_wake: u64 = 0,
    cache: PageCache = .{ .backing = .{}, .pages = @ptrFromInt(layout.cache) },
};
fn state() *State {
    return @ptrFromInt(layout.base);
}
fn store() *anyopaque {
    return @ptrFromInt(layout.store);
}
fn service() *anyopaque {
    return @ptrFromInt(layout.service);
}
fn now() u64 {
    return timers.Timer.fromGroup(0x500c3000, 0).?.counter() orelse 0;
}
fn identity(_: ?*anyopaque) callconv(.c) u32 {
    return if (calls.current()) |h| control.encodeHandle(h) else 0;
}
fn random(_: ?*anyopaque, out: [*]u8, n: c_int) callconv(.c) c_int {
    if (n < 0 or n > 256) return 0;
    // Dedicated P4 hardware RNG, no credential/key generation API is exposed.
    for (out[0..@intCast(n)], 0..) |*byte, i| {
        if (i % 4 == 0) asm volatile ("fence iorw,iorw" ::: .{ .memory = true });
        byte.* = @truncate(@as(*const volatile u32, @ptrFromInt(0x501101a4)).* >> @as(u5, @intCast((i % 4) * 8)));
    }
    return n;
}
fn clock(_: ?*anyopaque) callconv(.c) i64 {
    return @intCast(now() / 1000);
}
fn wall(_: ?*anyopaque) callconv(.c) i64 {
    // RTC/NTP wall clock is not yet an SQL capability. Refuse time acquisition.
    return -1;
}
fn sleep(_: ?*anyopaque, us: c_int) callconv(.c) c_int {
    if (us < 0) return 0;
    _ = calls.sleep(@max(1, (@as(u32, @intCast(us)) + 9999) / 10000));
    return us;
}
fn block(op: u32, lba: u32) i32 {
    return nih_normal_sqld_io(op, lba, &state().sector);
}
const RawDevice = struct {
    pub const capacity: u64 = layout.sector_count * 512;
    pub fn read(_: @This(), offset: u64, out: []u8) error{Io}!void {
        var done: usize = 0;
        while (done < out.len) : (done += 512) {
            if (block(1, layout.first_sector + @as(u32, @intCast((offset + done) / 512))) != 0) return error.Io;
            @memcpy(out[done..][0..512], &state().sector);
            state().report.io_reads +|= 1;
        }
    }
    pub fn write(_: @This(), offset: u64, data: []const u8) error{Io}!void {
        var done: usize = 0;
        while (done < data.len) : (done += 512) {
            @memcpy(&state().sector, data[done..][0..512]);
            if (block(2, layout.first_sector + @as(u32, @intCast((offset + done) / 512))) != 0) return error.Io;
            state().report.io_writes +|= 1;
        }
    }
    pub fn sync(_: @This()) error{Io}!void {
        if (block(3, 0) != 0) return error.Io;
        state().report.syncs +|= 1;
    }
};
const PageCache = @import("sqld_page_cache.zig").Cache(RawDevice, 128, 66);
comptime {
    if (@sizeOf(State) > layout.client_request - layout.base) @compileError("sqld state overlaps copied client buffers");
}
fn read(_: ?*anyopaque, offset: u64, out: [*]u8, length: usize) callconv(.c) c_int {
    state().cache.read(offset, out[0..length]) catch return -1;
    return 0;
}
fn write(_: ?*anyopaque, offset: u64, data: [*]const u8, length: usize) callconv(.c) c_int {
    state().cache.write(offset, data[0..length]) catch return -1;
    return 0;
}
fn sync(_: ?*anyopaque) callconv(.c) c_int {
    state().cache.sync() catch return -1;
    return 0;
}
fn recognized(bytes: *const [512]u8) bool {
    return std.mem.eql(u8, bytes[400..408], "NIHSQLD1") and bytes[450] == 0xda and
        bytes[510] == 0x55 and bytes[511] == 0xaa and
        std.mem.readInt(u32, bytes[454..458], .little) == layout.first_sector and
        std.mem.readInt(u32, bytes[458..462], .little) == layout.sector_count;
}
fn begin() i32 {
    const s = state();
    if (nih_sqld_size() > layout.service_bytes or nih_store_size() > layout.store_bytes) return -12;
    if (block(0, 0) != 0) return -19;
    s.report.sectors = std.mem.readInt(u32, s.sector[0..4], .little);
    s.report.cid_crc = std.mem.readInt(u32, s.sector[4..8], .little);
    if (s.report.sectors < layout.first_sector + layout.sector_count) return -28;
    if (block(1, 0) != 0) return -5;
    const known = recognized(&s.sector);
    const format = !known and options.sqld_provision_cid != 0 and options.sqld_provision_cid == s.report.cid_crc;
    if (!known and !format) return -84;
    if (block(if (format) 5 else 4, s.report.cid_crc) != 0) return -13;
    if (format) {
        s.sector = @splat(0xff);
        for (0..16) |i| if (block(2, layout.first_sector + @as(u32, @intCast(i))) != 0) return -5;
        if (sync(null) != 0) return -5;
    }
    const device = Device{ .context = null, .read = read, .write = write, .sync = sync };
    const mounted = nih_store_mount(store(), layout.store_bytes, &device, @intFromBool(format));
    if (mounted != 0) return mounted;
    if (format) {
        s.sector = @splat(0);
        @memcpy(s.sector[400..408], "NIHSQLD1");
        s.sector[450] = 0xda;
        std.mem.writeInt(u32, s.sector[454..458], layout.first_sector, .little);
        std.mem.writeInt(u32, s.sector[458..462], layout.sector_count, .little);
        s.sector[510] = 0x55;
        s.sector[511] = 0xaa;
        if (block(2, 0) != 0 or sync(null) != 0) return -5;
    }
    if (!s.allocator_ready) {
        const allocator_rc = nih_sqld_native_allocator(@ptrFromInt(layout.heap), layout.heap_bytes);
        if (allocator_rc != 0) return -10000 - allocator_rc;
        s.allocator_ready = true;
    }
    const platform = Platform{ .context = null, .identity = identity, .random = random, .time_ms = wall, .sleep_us = sleep, .monotonic_ms = clock, .transaction_timeout_ms = 30000 };
    return nih_sqld_start(service(), layout.service_bytes, store(), &platform, s.principal, s.epoch);
}
pub export fn nih_sqld_native_prepare(principal: u32, owner: u32) void {
    state().* = .{ .principal = principal, .owner = owner, .report = .{ .phase = 1 } };
    if (nih_normal_sqld_grant(principal, owner) == 0) {
        @atomicStore(bool, &state().granted, true, .release);
        nih_sqld_wake(1);
    }
}
pub export fn nih_sqld_native_task(_: u32) i32 {
    const s = state();
    if (identity(null) != s.owner) return -13;
    while (!@atomicLoad(bool, &s.granted, .acquire)) _ = calls.waitEvents(1);
    const rc = begin();
    s.report.error_code = rc;
    s.report.phase = if (rc == 0) 2 else 3;
    s.started = rc == 0;
    if (s.started) {
        s.report.generation = @truncate(nih_store_generation(store()));
        s.report.heap_used = @intCast(@max(0, sqlite3_memory_used()));
    }
    while (true) {
        if (s.started) {
            const step_result = nih_sqld_step(service());
            if (step_result < 0) {
                s.report.error_code = step_result;
                s.report.phase = 4;
                s.started = false;
                nih_sqld_wake(4);
            }
            if (step_result > 0) {
                const stack: [*]const u8 = @ptrFromInt(layout.stack);
                var untouched: u32 = 0;
                while (untouched < layout.stack_bytes and stack[untouched] == 0xa5) : (untouched += 1) {}
                s.report.stack_used = layout.stack_bytes - untouched;
                s.report.completed +|= 1;
                s.report.generation = @truncate(nih_store_generation(store()));
                s.report.heap_used = @intCast(@max(0, sqlite3_memory_used()));
                if (nih_sqld_failed(service()) != 0) s.report.phase = 4;
                nih_sqld_wake(4);
                continue;
            }
        }
        _ = calls.waitEvents(1);
    }
}
pub export fn nih_sqld_native_status() i32 {
    return @intCast(state().report.phase);
}
pub export fn nih_sqld_native_submit(q: *abi.Request) i32 {
    const s = state();
    if (identity(null) != s.principal) return -13;
    if (s.report.phase != 2) return -19;
    if (s.sequence == 0x7fffffff) return -7;
    q.epoch = s.epoch;
    s.sequence += 1;
    q.sequence = s.sequence;
    const rc = nih_sqld_submit(service(), s.principal, q);
    if (rc == 0) {
        s.report.requests +|= 1;
        nih_sqld_wake(1);
    }
    return rc;
}
pub export fn nih_sqld_native_take(r: *abi.Response) i32 {
    if (identity(null) != state().principal) return -13;
    return nih_sqld_take(service(), state().principal, r);
}
pub export fn nih_sqld_native_poll() void {
    if (now() -| state().last_wake > 100_000) {
        state().last_wake = now();
        nih_sqld_wake(1);
    }
}
pub export fn nih_sqld_native_report(out: *abi.Report) void {
    out.* = state().report;
}
