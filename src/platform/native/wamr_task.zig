//! Opt-in headless normal scheduler owner. Backing stays pinned until reap.
const tasks = @import("native_tasks");
const runtime = @import("wamr_runtime.zig");
const Queue = @import("spsc_ring").SpscRing(u32, 16);
const clock = @import("timer_group").Timer.fromGroup(0x500c2000, 0).?;
const stack_offset = runtime.runtime_bytes + runtime.linear_bytes + runtime.module_bytes * runtime.module_count;
extern fn nih_wamr_run([*]u8, [*]u8, [*]u8, [*]u8, u32, *runtime.Report) callconv(.c) i32;
extern fn nih_rom_rx_one_char(*u8) callconv(.c) i32;
var backing: ?tasks.memory.reusable.Pin = null;
var handle: ?tasks.calls.Handle = null;
var input = Queue.init();
var report: runtime.Report = .{};
var ready: u32 = 0;
var waits: u32 = 0;
var ready_at: u64 = 0;
var requested_stop = false;
var free_before: usize = 0;
var free_during: usize = 0;
var ticks_before: [2]u32 = .{ 0, 0 };
var round: u32 = 0;
var auto_index: usize = 0;
var previous_base: usize = 0;
var reused: u32 = 0;

export fn nih_wamr_task_uart_ready() callconv(.c) void {
    @atomicStore(u32, &ready, 1, .release);
}
export fn nih_wamr_task_receive() callconv(.c) i32 {
    const item = input.tryPop() orelse return -1;
    return if (item == 256) -2 else @intCast(item);
}
export fn nih_wamr_task_wait() callconv(.c) i32 {
    _ = @atomicRmw(u32, &waits, .Add, 1, .monotonic);
    return switch (tasks.calls.waitEvents(1)) {
        .received => 0,
        .failed => |status| status,
    };
}
fn entry(argument: u32) callconv(.c) i32 {
    const current = tasks.calls.current() orelse return -91;
    if (argument != (@as(u32, current.generation) << 16 | current.slot)) return -93;
    const bytes = (backing orelse return -94).allocation.bytes;
    // This function entered through the registered image/trampoline. No SP switch.
    return nih_wamr_run(bytes.ptr, bytes[runtime.runtime_bytes..].ptr, bytes[runtime.runtime_bytes + runtime.linear_bytes ..].ptr, bytes[runtime.runtime_bytes + runtime.linear_bytes + runtime.module_bytes ..].ptr, runtime.package_max_bytes, &report);
}

pub fn start() bool {
    if (backing != null) return false;
    input = Queue.init();
    @atomicStore(u32, &ready, 0, .release);
    @atomicStore(u32, &waits, 0, .release);
    ready_at = 0;
    requested_stop = false;
    auto_index = 0;
    const old_handle = handle;
    free_before = (tasks.memory.reusable.localUsage() orelse return false).free;
    const pin = tasks.memory.reusable.allocPinnedTask(runtime.lease_bytes, 64) catch return false;
    backing = pin;
    const bytes = pin.allocation.bytes;
    var registered = false;
    var bound = false;
    defer if (!registered) {
        if (bound) runtime.detachTaskStorage();
        @memset(bytes, 0);
        tasks.memory.reusable.releasePinnedTask(pin) catch @panic("Wasm pin release failed");
        backing = null;
    };
    @memset(bytes, 0);
    const stack = bytes[stack_offset..][0..runtime.stack_bytes];
    @memset(stack, 0xa5);
    if (!runtime.bindTaskStorage(stack, bytes[stack_offset + runtime.stack_bytes ..][0..runtime.surface_bytes])) return false;
    bound = true;
    // Ordinary free must refuse the backing even before the borrower starts.
    if (tasks.memory.freeExternal(pin.allocation)) |_| return false else |err| {
        if (err != error.Pinned) return false;
    }
    const child = tasks.registerWasm(pin, stack_offset, &entry) orelse return false;
    registered = true;
    // A second registration may not overwrite a live image/binding.
    if (tasks.registerWasm(pin, stack_offset, &entry) != null) return false;
    handle = .{ .slot = child.slot, .generation = child.generation };
    if (old_handle) |old| {
        if (child.generation == old.generation or tasks.calls.notify(old, 1) != tasks.calls.Status.not_found) return false;
    }
    reused = @intFromBool(previous_base != 0 and previous_base == @intFromPtr(bytes.ptr));
    round += 1;
    ticks_before = .{ tasks.report(0).ticks, tasks.report(1).ticks };
    free_during = (tasks.memory.reusable.localUsage() orelse return false).free;
    return true;
}

pub fn service(log: anytype) bool {
    const pin = backing orelse return false;
    if (tasks.finishWasm()) |completed| {
        const bytes = pin.allocation.bytes;
        var guards: u32 = 1;
        for (bytes[stack_offset..][0..128]) |byte| if (byte != 0xa5) {
            guards = 0;
        };
        var used: usize = 128;
        while (used < runtime.stack_bytes and bytes[stack_offset + used] == 0xa5) : (used += 1) {}
        runtime.detachTaskStorage();
        const old_high: u32 = @intCast(@intFromPtr(bytes.ptr) + stack_offset + runtime.stack_bytes);
        if (tasks.acceptsWasmFrame(0, 0x1880, old_high - 128, old_high)) return false;
        previous_base = @intFromPtr(bytes.ptr);
        @memset(bytes, 0);
        tasks.memory.reusable.releasePinnedTask(pin) catch return false;
        backing = null;
        const free_after = (tasks.memory.reusable.localUsage() orelse return false).free;
        const record: extern struct {
            round: u32,
            generation: u32,
            reused: u32,
            status: u32,
            reaped: u32,
            captures: u32,
            timers: u32,
            waits: u32,
            guards: u32,
            stack_used: u32,
            requested: u32,
            charged: u32,
            recovered: u32,
            released: u32,
            ticks0: u32,
            ticks1: u32,
            calls: u32,
            uart_status: u32,
            uart_bytes: u32,
            uart_frames: u32,
            owner_checks: u32,
            owners_released: u32,
            surface_checks: u32,
        } = .{
            .round = round,
            .generation = handle.?.generation,
            .reused = reused,
            .status = @bitCast(completed.exit_code),
            .reaped = 1,
            .captures = completed.captures,
            .timers = completed.timers,
            .waits = @atomicLoad(u32, &waits, .acquire),
            .guards = guards,
            .stack_used = @intCast(runtime.stack_bytes - used),
            .requested = runtime.lease_bytes,
            .charged = @intCast(free_before - free_during),
            .recovered = report.recovered,
            .released = @intFromBool(free_before == free_after),
            .ticks0 = tasks.report(0).ticks -% ticks_before[0],
            .ticks1 = tasks.report(1).ticks -% ticks_before[1],
            .calls = report.calls,
            .uart_status = report.uart_status,
            .uart_bytes = report.uart_bytes,
            .uart_frames = report.uart_frames,
            .owner_checks = report.owner_checks,
            .owners_released = report.owners_released,
            .surface_checks = report.surface_checks,
        };
        log.record("NIHOS_WASM_TASK", null, .{ "round", "generation", "reused", "status", "reaped", "captures", "timers", "waits", "guards", "stack_used", "requested", "charged", "recovered", "released", "ticks0", "ticks1", "calls", "uart_status", "uart_bytes", "uart_frames", "owner_checks", "owners_released", "surface_checks" }, &record);
        if (round < 2) return start();
        return false;
    }
    if (@atomicLoad(u32, &ready, .acquire) != 0 and !requested_stop) {
        const now = clock.counter() orelse return false;
        if (ready_at == 0) ready_at = now;
        var byte: u8 = 0;
        var value: ?u32 = null;
        if (round > 1 and auto_index < 5) {
            value = "0x10q"[auto_index];
            auto_index += 1;
            if (auto_index == 5) requested_stop = true;
        } else if (nih_rom_rx_one_char(&byte) == 0) {
            value = byte;
            if (byte == 'q') requested_stop = true;
        } else if (now - ready_at > 500_000) {
            value = 256;
            requested_stop = true;
        }
        if (value) |item| {
            if (!input.tryPush(item)) return false;
            if (tasks.calls.notify(handle.?, 1) != 0) return false;
        }
    }
    return true;
}
