//! Foreground common-session hooks; only the registered worker enters WAMR.
const app = @import("app_session");
const tasks = @import("native_tasks");
const runtime = @import("wamr_runtime.zig");
const mailbox = @import("frame_mailbox");
const startup = @import("async_start");
const clock = @import("timer_group").Timer.fromGroup(0x500c2000, 0).?;
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
    open_us: u32 = 0,
    render_max_us: u32 = 0,
    close_us: u32 = 0,
};
pub var observed: Metrics = .{};
var box: mailbox.Mailbox = .{};
var backing: ?tasks.memory.reusable.Pin = null;
var frame_lease: ?tasks.memory.reusable.Allocation = null;
var child: ?tasks.calls.Handle = null;
var completion: ?tasks.WasmCompletion = null;
var engine_report: EngineReport = .{};
var engine_open = false;
var async_policy: startup.Startup = .{};
var async_id: u32 = 0;
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
    // Emulator fault injection: exercise worker exit before close acknowledgement.
    if (fault == 5 and box.request.operation == 3) return;
    if (!box.complete(id, status)) @panic("invalid Wasm response");
}
fn entry(argument: u32) callconv(.c) i32 {
    const current = tasks.calls.current() orelse return -91;
    if (argument != (@as(u32, current.generation) << 16 | current.slot)) return -93;
    const bytes = (backing orelse return -94).allocation.bytes;
    return nih_wamr_session_run(bytes.ptr, bytes[runtime.runtime_bytes..].ptr, bytes[runtime.runtime_bytes + runtime.linear_bytes ..].ptr, bytes[runtime.runtime_bytes + runtime.linear_bytes + runtime.module_bytes ..].ptr, &engine_report);
}
fn request(command: mailbox.Command) i32 {
    const started = clock.counter() orelse return -90;
    defer {
        if (clock.counter()) |now| {
            const elapsed: u32 = @intCast(@min(now -| started, 0xffffffff));
            switch (command.operation) {
                1 => observed.open_us = elapsed,
                2, 4 => observed.render_max_us = @max(observed.render_max_us, elapsed),
                3 => observed.close_us = elapsed,
                else => {},
            }
        }
    }
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
    if (fault == 3) return -4;
    if (frame_lease != null or (backing != null and !engine_open)) return -3;
    const lease = tasks.memory.allocExternal(app.lease_bytes, 64) catch return -4;
    frame_lease = lease;
    bytes.* = lease.bytes.ptr;
    len.* = @intCast(lease.bytes.len);
    return 0;
}
fn open(_: ?*anyopaque) callconv(.c) i32 {
    if (engine_open) return 0;
    const status = launch();
    if (status != 0) return status;
    const result = request(.{ .operation = 1, .selected = fault });
    engine_open = result == 0;
    return result;
}
fn launch() i32 {
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
    return 0;
}

/// Begin the signed package open without waiting for the worker.
pub fn beginAsync(callback: *const fn ([*]const u8, u32) callconv(.c) i32) i32 {
    if (backing != null or active() or owner.busy != 0) return -3;
    async_policy = .{};
    presenter = callback;
    const status = launch();
    if (status != 0) return status;
    const handle = child.?;
    if (async_policy.begin(handle.generation) == null) @panic("async generation");
    async_id = box.submit(.{ .operation = 1, .selected = fault }) orelse @panic("async mailbox");
    if (tasks.calls.notify(handle, 1) != 0) @panic("async notify");
    return 0;
}
pub fn cancelAsync() bool {
    if (async_policy.phase != .opening) return false;
    _ = async_policy.cancel();
    return true;
}
/// Returns null while opening/closing/reaping, 0 when ready, 1 when cancelled.
pub fn pollAsync() ?i32 {
    const generation = async_policy.generation;
    switch (async_policy.phase) {
        .opening, .cancelling => {
            const result = box.collect(async_id) orelse blk: {
                completion = tasks.finishWasm() orelse return null;
                break :blk -90;
            };
            const action = async_policy.opened(generation, result) orelse @panic("async open");
            if (action == .publish_ready) {
                engine_open = true;
                var status = app.start(&owner);
                // If frame allocation failed before Session opened the backend,
                // Session could not close the already initialized worker.
                if (status != 0 and backing != null and close(null) != 0) status = -90;
                if (status != 0) {
                    async_policy.phase = .done;
                    async_policy.result = status;
                }
                return status;
            }
            if (action == .start_close) {
                async_id = box.submit(.{ .operation = 3 }) orelse @panic("async close mailbox");
                if (tasks.calls.notify(child.?, 1) != 0) @panic("async close notify");
            }
            return null;
        },
        .closing => {
            const result = box.collect(async_id) orelse blk: {
                completion = tasks.finishWasm() orelse return null;
                break :blk -90;
            };
            _ = async_policy.closed(generation, result) orelse @panic("async close");
            return null;
        },
        .reaping => {
            if (completion == null) completion = tasks.finishWasm() orelse return null;
            const action = async_policy.reaped(generation, engine_report.recovered == 1) orelse @panic("async reap");
            if (action == .fail) {
                async_policy.result = -90; // Keep a damaged allocation pinned.
                return -90;
            }
            const result = async_policy.result;
            _ = close(null);
            if (observed.guards != 1 or observed.recovered != 1 or observed.detached != 1) {
                async_policy.result = -90;
                return -90;
            }
            return if (result == 0) 1 else result;
        },
        .ready => return if (active()) 0 else -90,
        .done => return if (async_policy.result == 0) 1 else async_policy.result,
        .idle => return -5,
    }
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
    if (active() or owner.busy != 0 or backing != null) return -3;
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

// Internal bridge between the display owner module and the single worker.
export fn nih_wasm_ui_begin(callback: *const fn ([*]const u8, u32) callconv(.c) i32) callconv(.c) i32 {
    return beginAsync(callback);
}
export fn nih_wasm_ui_poll(status: *i32) callconv(.c) bool {
    status.* = pollAsync() orelse return false;
    return true;
}
export fn nih_wasm_ui_cancel_open() callconv(.c) bool {
    return cancelAsync();
}
export fn nih_wasm_ui_cancel() callconv(.c) i32 {
    return cancel();
}
export fn nih_wasm_ui_input(byte: u32) callconv(.c) i32 {
    return input(byte);
}
export fn nih_wasm_ui_active() callconv(.c) bool {
    return active();
}
