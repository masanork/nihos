//! Foreground common-session hooks; only the registered worker enters WAMR.
const app = @import("app_session");
const tasks = @import("native_tasks");
const runtime = @import("wamr_runtime.zig");
const mailbox = @import("frame_mailbox");
const stack_offset = runtime.runtime_bytes + runtime.linear_bytes + runtime.module_bytes * runtime.module_count;
extern fn nih_wamr_session_run([*]u8, [*]u8, [*]u8, [*]u8, *EngineReport) callconv(.c) i32;
extern fn nih_app_fill_rect(i32, i32, u32, u32, u32) callconv(.c) i32;
const EngineReport = extern struct { recovered: u32 = 0, calls: u32 = 0, denied: u32 = 0, frames: u32 = 0 };
pub const Metrics = struct {
    captures: u32 = 0,
    timers: u32 = 0,
    waits: u32 = 0,
    guards: u32 = 0,
    reaped: u32 = 0,
    recovered: u32 = 0,
    wiped: u32 = 0,
    detached: u32 = 0,
    stack_used: u32 = 0,
    calls: u32 = 0,
    denied: u32 = 0,
    generation: u32 = 0,
};
pub var observed: Metrics = .{};
var box: mailbox.Mailbox = .{};
var backing: ?tasks.memory.reusable.Pin = null;
var frame_lease: ?tasks.memory.reusable.Allocation = null;
var child: ?tasks.calls.Handle = null;
var completion: ?tasks.WasmCompletion = null;
var engine_report: EngineReport = .{};
var engine_open = false;
var fault: u32 = 0;
var presenter: ?*const fn ([*]const u8, u32) callconv(.c) i32 = null;
var owner: app.Session = .{ .hooks = .{
    .context = null,
    .acquire = acquire,
    .open = open,
    .render = render,
    .present = present,
    .close = close,
    .release = release,
} };

export fn nih_wasm_session_receive(command: *mailbox.Command) callconv(.c) i32 {
    while (true) {
        if (box.take()) |message| {
            command.* = message;
            return 0;
        }
        observed.waits += 1;
        switch (tasks.calls.waitEvents(1)) {
            .received => {},
            .failed => return -90,
        }
    }
}
export fn nih_wasm_session_complete(id: u32, status: i32) callconv(.c) void {
    if (!box.complete(id, status)) @panic("invalid Wasm response");
}
fn entry(argument: u32) callconv(.c) i32 {
    const current = tasks.calls.current() orelse return -91;
    if (argument != (@as(u32, current.generation) << 16 | current.slot)) return -93;
    const bytes = (backing orelse return -94).allocation.bytes;
    return nih_wamr_session_run(bytes.ptr, bytes[runtime.runtime_bytes..].ptr, bytes[runtime.runtime_bytes + runtime.linear_bytes ..].ptr, bytes[runtime.runtime_bytes + runtime.linear_bytes + runtime.module_bytes ..].ptr, &engine_report);
}
fn request(command: mailbox.Command) i32 {
    const handle = child orelse return -90;
    const id = box.submit(command) orelse return -3;
    if (tasks.calls.notify(handle, 1) != 0) return -90;
    while (true) {
        if (box.collect(id)) |status| return status;
        if (tasks.finishWasm()) |done| {
            completion = done;
            return -90;
        }
        tasks.idleOnce(0);
    }
}
fn acquire(_: ?*anyopaque, bytes: *?[*]u8, len: *u32) callconv(.c) i32 {
    if (frame_lease != null or backing != null) return -3;
    const lease = tasks.memory.allocExternal(app.lease_bytes, 64) catch return -4;
    frame_lease = lease;
    bytes.* = lease.bytes.ptr;
    len.* = @intCast(lease.bytes.len);
    return 0;
}
fn open(_: ?*anyopaque) callconv(.c) i32 {
    box = .{};
    observed = .{};
    engine_report = .{};
    completion = null;
    const pin = tasks.memory.reusable.allocPinnedTask(runtime.lease_bytes, 64) catch return -4;
    backing = pin;
    const bytes = pin.allocation.bytes;
    @memset(bytes, 0);
    const stack = bytes[stack_offset..][0..runtime.stack_bytes];
    @memset(stack, 0xa5);
    if (!runtime.bindTaskStorage(stack, bytes[stack_offset + runtime.stack_bytes ..][0..runtime.surface_bytes])) {
        @memset(bytes, 0);
        tasks.memory.reusable.releasePinnedTask(pin) catch @panic("Wasm pin release");
        backing = null;
        return -90;
    }
    const handle = tasks.registerWasm(pin, stack_offset, &entry) orelse {
        runtime.detachTaskStorage();
        @memset(bytes, 0);
        tasks.memory.reusable.releasePinnedTask(pin) catch @panic("Wasm pin release");
        backing = null;
        return -90;
    };
    child = .{ .slot = handle.slot, .generation = handle.generation };
    observed.generation = handle.generation;
    const result = request(.{ .operation = 1, .selected = fault });
    engine_open = result == 0;
    return result;
}
fn render(_: ?*anyopaque, selected: u32, bytes: [*]u8, len: u32) callconv(.c) i32 {
    const lease = frame_lease orelse return -5;
    if (!engine_open or bytes != lease.bytes.ptr + 16 or len != app.frame_bytes) return -5;
    return request(.{ .operation = if (fault == 2) 4 else 2, .selected = selected, .address = @intCast(@intFromPtr(bytes)), .length = len });
}
fn present(_: ?*anyopaque, bytes: [*]const u8, len: u32) callconv(.c) i32 {
    if (box.phase.load(.acquire) != 0 or box.request.address != 0) return -90;
    if (nih_app_fill_rect(0, 0, 1, 1, 0) != -3) return -90;
    return (presenter orelse return -5)(bytes, len);
}
fn close(_: ?*anyopaque) callconv(.c) i32 {
    const pin = backing orelse return 0;
    var result: i32 = 0;
    if (engine_open) result = request(.{ .operation = 3 });
    engine_open = false;
    while (completion == null) {
        completion = tasks.finishWasm();
        if (completion == null) tasks.idleOnce(0);
    }
    const done = completion.?;
    observed.captures = done.captures;
    observed.timers = done.timers;
    observed.reaped = 1;
    observed.recovered = engine_report.recovered;
    observed.calls = engine_report.calls;
    observed.denied = engine_report.denied;
    const bytes = pin.allocation.bytes;
    observed.guards = 1;
    for (bytes[stack_offset..][0..128]) |byte| if (byte != 0xa5) {
        observed.guards = 0;
    };
    var used: usize = 128;
    while (used < runtime.stack_bytes and bytes[stack_offset + used] == 0xa5) : (used += 1) {}
    observed.stack_used = @intCast(runtime.stack_bytes - used);
    runtime.detachTaskStorage();
    @memset(bytes, 0);
    tasks.memory.reusable.releasePinnedTask(pin) catch @panic("Wasm pin release");
    backing = null;
    observed.detached = @intFromBool(nih_app_fill_rect(0, 0, 1, 1, 0) == -3);
    if (result == 0 and (done.exit_code != 0 or observed.guards != 1 or observed.recovered != 1)) result = -90;
    return result;
}
fn release(_: ?*anyopaque, bytes: [*]u8, len: u32) callconv(.c) i32 {
    const lease = frame_lease orelse return -5;
    if (backing != null or lease.bytes.ptr != bytes or lease.bytes.len != len) return -90;
    for (bytes[0..len]) |byte| if (byte != 0) return -90;
    tasks.memory.freeExternal(lease) catch return -4;
    frame_lease = null;
    observed.wiped = 1;
    return 0;
}
pub fn start(callback: *const fn ([*]const u8, u32) callconv(.c) i32) i32 {
    if (active() or owner.busy != 0) return -3;
    presenter = callback;
    return app.start(&owner);
}
pub fn input(byte: u32) i32 {
    return app.input(&owner, byte);
}
pub fn cancel() i32 {
    return app.cancel(&owner);
}
pub fn active() bool {
    return owner.state == .running;
}
pub fn frames() u32 {
    return owner.frames;
}
pub fn setFault(value: u32) void {
    fault = value;
}
