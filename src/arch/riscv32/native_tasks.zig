//! Permanent native owner: the same runtime/policy/call ABI as hosted tasks.
//! Each hart mutates only its own Owner on its private IRQ stack with MIE=0.
pub const context = @import("context.zig");
const runtime_module = @import("task_runtime.zig");
const calls = @import("task_calls.zig");
const control = @import("task_control");
const scheduler = @import("scheduler");
const tick_clock = @import("tick_clock");
const timer_group = @import("timer_group");

const Runtime = runtime_module.Runtime(4, 1);
const stack_bytes = 4096;
pub const period_us = 10_000;
const initial_state = context.ReturnState{ .mstatus = 0x1880, .mcause = 0 };
extern fn nih_native_task_trampoline() callconv(.c) void;
extern fn nih_native_task_failed() callconv(.c) noreturn;

const Owner = struct {
    runtime: Runtime = .{},
    clock: tick_clock.TickClock = tick_clock.TickClock.init(period_us).?,
    bootstrap: scheduler.TaskHandle = .{ .slot = 0, .generation = 0 },
    workers: [2]scheduler.TaskHandle = @splat(.{ .slot = 0, .generation = 0 }),
    lifecycle: scheduler.TaskHandle = .{ .slot = 0, .generation = 0 },
    phase: u32 = 0,
    captures: [2]u32 = .{ 0, 0 },
    switches: u32 = 0,
    calls: u32 = 0,
    reaped: u32 = 0,
    completed_runtime_ticks: u64 = 0,
    last_slot: u16 = 0,
    gp: u32 = 0,
    ready: bool = false,
};

pub const Report = struct {
    progress: [2]u32 = .{ 0, 0 },
    captures: [2]u32 = .{ 0, 0 },
    switches: u32 = 0,
    calls: u32 = 0,
    reaped: u32 = 0,
    sleeps: u32 = 0,
    ticks: u32 = 0,
};

var owners: [2]Owner = .{ .{}, .{} };
var stacks: [2][3][stack_bytes]u8 align(16) = undefined;
var reports: [2]Report = .{ .{}, .{} };

fn load(value: *const u32) u32 {
    return @atomicLoad(u32, value, .acquire);
}

fn store(value: *u32, next: u32) void {
    @atomicStore(u32, value, next, .release);
}

/// Only 32-bit atomic publications cross hart boundaries; no remote policy reads.
pub fn report(hart: u32) Report {
    const source = &reports[hart];
    return .{
        .progress = .{ load(&source.progress[0]), load(&source.progress[1]) },
        .captures = .{ load(&source.captures[0]), load(&source.captures[1]) },
        .switches = load(&source.switches),
        .calls = load(&source.calls),
        .reaped = load(&source.reaped),
        .sleeps = load(&source.sleeps),
        .ticks = load(&source.ticks),
    };
}

fn busy(argument: u32) callconv(.c) i32 {
    const hart = argument / 4;
    const worker = argument % 4;
    if (hart >= 2 or worker >= 2) nih_native_task_failed();
    const signature = 0x6e69_0000 | argument;
    var canary: [8]u32 = @splat(signature);
    const checked: *volatile [8]u32 = &canary;
    if (!onTaskStack(hart, worker, @intFromPtr(&canary), @sizeOf(@TypeOf(canary))))
        nih_native_task_failed();
    while (true) {
        for (0..8) |index| if (checked[index] != signature) nih_native_task_failed();
        _ = @atomicRmw(u32, &reports[hart].progress[worker], .Add, 1, .release);
        // No ECALL, yield, sleep, or function with a scheduling side effect.
    }
}

fn lifecycle(argument: u32) callconv(.c) i32 {
    const hart = argument / 4;
    const duration: u32 = if (argument % 4 == 2) 3 else 1;
    var marker: u32 = argument;
    if (!onTaskStack(hart, 2, @intFromPtr(&marker), @sizeOf(u32))) nih_native_task_failed();
    if (calls.current() == null) nih_native_task_failed();
    const before = calls.nowTicks();
    if (calls.sleep(duration) != 0 or calls.nowTicks() - before < duration)
        nih_native_task_failed();
    _ = @atomicRmw(u32, &reports[hart].sleeps, .Add, 1, .release);
    if (calls.yieldNow() != 0) nih_native_task_failed();
    return @intCast(40 + argument);
}

fn onTaskStack(hart: u32, index: u32, address: u32, bytes: u32) bool {
    const bottom = @intFromPtr(&stacks[hart][index]);
    return address >= bottom + 16 and address <= bottom + stack_bytes - bytes;
}

fn guardsValid(hart: u32) bool {
    for (&stacks[hart]) |*stack| {
        const guard: *volatile [4]u32 = @ptrCast(stack);
        for (0..4) |word| if (guard[word] != 0x6e69_7374) return false;
    }
    return true;
}

fn add(hart: u32, index: u32, replacement: bool) ?scheduler.TaskHandle {
    const owner = &owners[hart];
    const stack = &stacks[hart][index];
    const bottom = @intFromPtr(stack);
    const guard: *[4]u32 = @ptrCast(stack);
    guard.* = @splat(0x6e69_7374);
    const address = context.initialTaskFrameAddress(bottom, stack_bytes) orelse return null;
    const frame: *context.IntegerContext = @ptrFromInt(address);
    context.initialize(frame, .{
        .entry = if (index < 2) @intFromPtr(&busy) else @intFromPtr(&lifecycle),
        .argument = hart * 4 + index + @intFromBool(replacement),
        .trampoline = @intFromPtr(&nih_native_task_trampoline),
        .global_pointer = owner.gp,
    });
    return owner.runtime.add(0, .{
        .frame = frame,
        .state = initial_state,
        .stack_min = bottom + 16,
        .stack_max = bottom + stack_bytes,
    });
}

/// Called on the corresponding bootstrap stack before that hart enables MIE.
pub fn prepare(hart: u32, stack_min: u32, stack_max: u32, gp: u32) bool {
    const owner = &owners[hart];
    owner.gp = gp;
    owner.bootstrap = owner.runtime.add(0, .{ .stack_min = stack_min, .stack_max = stack_max }) orelse return false;
    _ = owner.runtime.policy.schedule() orelse return false;
    owner.last_slot = owner.bootstrap.slot;
    for (0..2) |index| owner.workers[index] = add(hart, @intCast(index), false) orelse return false;
    owner.lifecycle = add(hart, 2, false) orelse return false;
    owner.ready = true;
    return true;
}

pub fn ready(hart: u32) bool {
    return owners[hart].ready;
}

fn maintain(hart: u32) bool {
    const owner = &owners[hart];
    if (owner.phase == 2) return true;
    const completion = owner.runtime.policy.snapshot(owner.lifecycle) orelse return false;
    if (completion.state != .exited) return true;
    const expected: i32 = @intCast(42 + hart * 4 + owner.phase);
    if (completion.exit_code != expected) return false;
    owner.completed_runtime_ticks += completion.runtime_ticks;
    const old = owner.lifecycle;
    if (!owner.runtime.reap(old) or owner.runtime.policy.snapshot(old) != null) return false;
    // A scalar call using the old generation must fail even after slot reuse.
    owner.reaped += 1;
    owner.phase += 1;
    if (owner.phase == 1) {
        owner.lifecycle = add(hart, 2, true) orelse return false;
        if (owner.lifecycle.slot != old.slot or owner.lifecycle.generation == old.generation)
            return false;
    }
    const rejected = control.dispatch(&owner.runtime.policy, @backingInt(control.Number.wake), control.encodeHandle(old));
    return rejected.statusCode() == control.Status.not_found;
}

fn publish(hart: u32, selected: context.TaskContext) context.TaskContext {
    const owner = &owners[hart];
    var total = owner.completed_runtime_ticks;
    for ([_]scheduler.TaskHandle{ owner.bootstrap, owner.workers[0], owner.workers[1], owner.lifecycle }) |handle| {
        if (owner.runtime.policy.snapshot(handle)) |snapshot| total += snapshot.runtime_ticks;
    }
    if (total != owner.runtime.policy.now()) nih_native_task_failed();
    const current = owner.runtime.policy.current() orelse nih_native_task_failed();
    if (current.slot != owner.last_slot) owner.switches +%= 1;
    owner.last_slot = current.slot;
    store(&reports[hart].captures[0], owner.captures[0]);
    store(&reports[hart].captures[1], owner.captures[1]);
    store(&reports[hart].switches, owner.switches);
    store(&reports[hart].calls, owner.calls);
    store(&reports[hart].reaped, owner.reaped);
    store(&reports[hart].ticks, @truncate(owner.runtime.policy.now()));
    return selected;
}

fn refresh(hart: u32, device: timer_group.Timer) bool {
    const owner = &owners[hart];
    const now = device.counter() orelse return false;
    const advance = owner.clock.observe(now) orelse return false;
    return owner.runtime.policy.elapse(advance.elapsed_ticks) and device.armAt(advance.next_deadline);
}

/// Only called from the permanent interrupt dispatcher, never a task stack.
pub fn onTimer(hart: u32, frame: *context.IntegerContext, state: context.ReturnState, device: timer_group.Timer) ?context.TaskContext {
    const owner = &owners[hart];
    if (!guardsValid(hart) or !owner.runtime.capture(frame, state) or !refresh(hart, device)) return null;
    const current = owner.runtime.policy.current() orelse return null;
    for (owner.workers, 0..) |handle, index| {
        if (current.slot == handle.slot) owner.captures[index] +%= 1;
    }
    if (!maintain(hart)) return null;
    return publish(hart, owner.runtime.select() orelse return null);
}

pub fn onCall(hart: u32, frame: *context.IntegerContext, state: context.ReturnState, device: timer_group.Timer) ?context.TaskContext {
    const owner = &owners[hart];
    if (!guardsValid(hart) or !refresh(hart, device)) return null;
    owner.calls +%= 1;
    const selected = owner.runtime.call(frame, state) orelse return null;
    if (!maintain(hart)) return null;
    return publish(hart, selected);
}
