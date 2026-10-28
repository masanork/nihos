//! Executes the real font fixture with the common task ABI and native trap ASM.
//! Only event delivery and mapped inputs are synthetic; no P4 boot claim.
const tasks = @import("task_runtime");
const context = tasks.context;
const scheduler = @import("scheduler");
const calls = @import("task_calls");
// Match the native freestanding root: safety failures trap, with no host IO.
pub const panic = @import("std").debug.no_panic;
const Runtime = tasks.Runtime(4, 2);
const Result = extern struct {
    stage: u32 = 0,
    failure: u32 = 0,
    font_rc: u32 = 0,
    peer_progress: u32 = 0,
    timer_traps: u32 = 0,
    call_traps: u32 = 0,
    font_captures: u32 = 0,
    switches: u32 = 0,
    reaped: u32 = 0,
    read_callbacks: u32 = 0,
    read_yields: u32 = 0,
    font_stack_min: u32 = 0,
    font_stack_max: u32 = 0,
    irq_samples: u32 = 0,
};
export var graphics_worker_result: Result = .{};
export var graphics_worker_current: u32 = 0;
export var graphics_worker_stack_bytes: u32 = 32768;
export var graphics_worker_yield_reads: u32 = 0;
export var nih_native_return_states: [2]context.ReturnState = @splat(.{ .mstatus = 0, .mcause = 0 });
var runtime: Runtime = .{};
var input: ?*const anyopaque = null;
var font_done: u32 = 0;
extern fn graphics_font_link_probe(*const anyopaque) callconv(.c) c_int;
extern fn nih_native_trap() callconv(.c) void;
extern fn nih_native_task_trampoline() callconv(.c) void;
extern var __stack0_bottom: u8;
extern var __stack0_top: u8;
extern var __irq_stack0_bottom: u8;
extern var __irq_stack0_top: u8;
extern var __irq_stack1_bottom: u8;
extern var __peer_stack_bottom: u8;
extern var __peer_stack_top: u8;
extern var __font_stack_top: u8;

fn fail(code: u32) noreturn {
    graphics_worker_result.failure = code;
    asm volatile ("ebreak" ::: .{ .memory = true });
    while (true) {}
}
fn require(good: bool, code: u32) void {
    if (!good) fail(code);
}
fn guard(low: u32) *volatile [4]u32 {
    return @ptrFromInt(low);
}
fn guards() bool {
    for ([_]u32{ @intFromPtr(&__stack0_bottom), @intFromPtr(&__irq_stack0_bottom), @intFromPtr(&__irq_stack1_bottom), @intFromPtr(&__peer_stack_bottom), graphics_worker_result.font_stack_min - 16 }) |low| {
        for (guard(low)) |word| if (word != 0x67726166) return false;
    }
    return true;
}
fn font(_: u32) callconv(.c) i32 {
    graphics_worker_result.stage = 10;
    const rc = graphics_font_link_probe(input orelse fail(11));
    graphics_worker_result.font_rc = @bitCast(rc);
    require(rc == 0 and guards(), 12);
    @atomicStore(u32, &font_done, 1, .release);
    return rc;
}
fn peer(_: u32) callconv(.c) i32 {
    var canary: [8]u32 = @splat(0x70656572);
    const checked: *volatile [8]u32 = &canary;
    while (@atomicLoad(u32, &font_done, .acquire) == 0) {
        for (checked) |word| require(word == 0x70656572, 21);
        graphics_worker_result.peer_progress += 1;
        require(calls.yieldNow() == 0, 22);
    }
    return 0;
}
fn add(low: u32, high: u32, entry: u32, gp: u32) scheduler.TaskHandle {
    const address = context.initialTaskFrameAddress(low, high - low) orelse fail(30);
    const frame: *context.IntegerContext = @ptrFromInt(address);
    context.initialize(frame, .{ .entry = entry, .argument = 0, .trampoline = @intFromPtr(&nih_native_task_trampoline), .global_pointer = gp });
    return runtime.add(0, .{ .frame = frame, .state = .{ .mstatus = 0x1880, .mcause = 0 }, .stack_min = low + 16, .stack_max = high }) orelse fail(31);
}
export fn graphics_source_read_completed() callconv(.c) void {
    require(graphics_worker_current == 1, 40);
    graphics_worker_result.read_callbacks += 1;
    if (graphics_worker_yield_reads != 0 and graphics_worker_result.read_callbacks % 32 == 0) {
        graphics_worker_result.read_yields += 1;
        require(calls.yieldNow() == 0, 41);
    }
}
export fn nih_native_dispatch(frame: *context.IntegerContext, cause: u32, hart: u32, status: u32) callconv(.c) *context.IntegerContext {
    const sp = asm volatile ("mv %[value], sp"
        : [value] "=r" (-> u32),
    );
    const live_status = asm volatile ("csrr %[value], mstatus"
        : [value] "=r" (-> u32),
    );
    require(hart == 0 and live_status & 8 == 0 and sp >= @intFromPtr(&__irq_stack0_bottom) + 16 and sp < @intFromPtr(&__irq_stack0_top), 50);
    require(guards() and frame.sp == @intFromPtr(frame) + 128, 51);
    graphics_worker_result.irq_samples += 1;
    const old = runtime.policy.current() orelse fail(52);
    const state = context.ReturnState{ .mstatus = status, .mcause = cause };
    const selected = if (cause == 11) call: {
        graphics_worker_result.call_traps += 1;
        break :call runtime.call(frame, state) orelse fail(53);
    } else timer: {
        require(cause == 0x80000010, 54);
        graphics_worker_result.timer_traps += 1;
        if (old.slot == 1) graphics_worker_result.font_captures += 1;
        require(runtime.capture(frame, state) and runtime.policy.elapse(1), 55);
        break :timer runtime.select() orelse fail(56);
    };
    const current = runtime.policy.current() orelse fail(57);
    if (old.slot != current.slot) graphics_worker_result.switches += 1;
    graphics_worker_current = current.slot;
    nih_native_return_states[0] = selected.state.integerOnly().returningFrom(state);
    return selected.frame;
}
export fn graphics_worker_entry(inputs: *const anyopaque) callconv(.c) c_int {
    asm volatile ("csrci mstatus, 8" ::: .{ .memory = true });
    require(graphics_worker_stack_bytes == 16384 or graphics_worker_stack_bytes == 32768, 60);
    input = inputs;
    const high = @intFromPtr(&__font_stack_top);
    const low = high - graphics_worker_stack_bytes;
    graphics_worker_result.font_stack_min = low + 16;
    graphics_worker_result.font_stack_max = high;
    for ([_]u32{ @intFromPtr(&__stack0_bottom), @intFromPtr(&__irq_stack0_bottom), @intFromPtr(&__irq_stack1_bottom), @intFromPtr(&__peer_stack_bottom), low }) |bottom| guard(bottom).* = @splat(0x67726166);
    asm volatile ("csrw mtvec, %[entry]"
        :
        : [entry] "r" (@intFromPtr(&nih_native_trap)),
        : .{ .memory = true });
    const gp = asm volatile ("mv %[value], gp"
        : [value] "=r" (-> u32),
    );
    const boot = runtime.add(0, .{ .stack_min = @intFromPtr(&__stack0_bottom) + 16, .stack_max = @intFromPtr(&__stack0_top) }) orelse fail(61);
    require((runtime.policy.schedule() orelse fail(62)).slot == boot.slot, 63);
    const worker = add(low, high, @intFromPtr(&font), gp);
    const other = add(@intFromPtr(&__peer_stack_bottom), @intFromPtr(&__peer_stack_top), @intFromPtr(&peer), gp);
    require(worker.slot == 1 and other.slot == 2, 64);
    graphics_worker_result.stage = 2;
    asm volatile ("csrsi mstatus, 8" ::: .{ .memory = true });
    while ((runtime.policy.snapshot(worker) orelse fail(65)).state != .exited or (runtime.policy.snapshot(other) orelse fail(66)).state != .exited) require(calls.yieldNow() == 0, 67);
    asm volatile ("csrci mstatus, 8" ::: .{ .memory = true });
    require(guards() and runtime.reap(worker) and runtime.reap(other), 68);
    graphics_worker_result.reaped = 2;
    graphics_worker_result.stage = 100;
    return 0;
}
export fn nih_native_main() callconv(.c) noreturn {
    fail(70);
}
export fn nih_native_cpu1_main() callconv(.c) noreturn {
    fail(71);
}
