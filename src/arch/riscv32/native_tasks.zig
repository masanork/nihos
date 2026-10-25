//! Permanent native owner: the same runtime/policy/call ABI as hosted tasks.
//! Each hart mutates only its own Owner on its private IRQ stack with MIE=0.
pub const context = @import("context.zig");
const runtime_module = @import("task_runtime.zig");
const calls = @import("task_calls.zig");
const control = @import("task_control");
const scheduler = @import("scheduler");
const tick_clock = @import("tick_clock");
const timer_group = @import("timer_group");
pub const ipi = @import("native_ipi.zig");
pub const floating = @import("native_floating.zig");
pub const memory = @import("native_memory");

const Runtime = runtime_module.Runtime(4, 2);
const stack_bytes = 4096;
pub const period_us = 10_000;
const initial_state = context.ReturnState{ .mstatus = 0x1880, .mcause = 0 };
extern fn nih_native_task_trampoline() callconv(.c) void;
extern fn nih_native_task_failed() callconv(.c) noreturn;

const Phase = enum { initial_lifecycle, replacement_lifecycle, preemption, ipi_protocol, complete };
const TaskKind = enum { busy, initial_lifecycle, replacement_lifecycle, ipi_protocol };

const Owner = struct {
    runtime: Runtime = .{},
    clock: tick_clock.TickClock = tick_clock.TickClock.init(period_us).?,
    bootstrap: scheduler.TaskHandle = .{ .slot = 0, .generation = 0 },
    workers: [2]scheduler.TaskHandle = @splat(.{ .slot = 0, .generation = 0 }),
    lifecycle: scheduler.TaskHandle = .{ .slot = 0, .generation = 0 },
    phase: Phase = .initial_lifecycle,
    captures: [2]u32 = .{ 0, 0 },
    switches: u32 = 0,
    calls: u32 = 0,
    reaped: u32 = 0,
    completed_runtime_ticks: u64 = 0,
    last_slot: u16 = 0,
    gp: u32 = 0,
    ready: bool = false,
    worker_reaped: [2]bool = .{ false, false },
    timer_interrupts: u32 = 0,
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
        if (ipi.requested()) return @intCast(100 + argument);
        for (0..8) |index| if (checked[index] != signature) nih_native_task_failed();
        floating.check(hart, worker);
        memory.probe(argument);
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
    floating.check(hart, 2);
    const before = calls.nowTicks();
    if (calls.sleep(duration) != 0 or calls.nowTicks() - before < duration)
        nih_native_task_failed();
    floating.check(hart, 2);
    _ = @atomicRmw(u32, &reports[hart].sleeps, .Add, 1, .release);
    if (calls.yieldNow() != 0) nih_native_task_failed();
    floating.check(hart, 2);
    return @intCast(40 + argument);
}

fn floatingBusy(argument: u32) callconv(.c) i32 {
    floating.enter(argument / 4, argument % 4, if (floating.compiled) &floating.app.busy else &busy, argument);
}

fn floatingLifecycle(argument: u32) callconv(.c) i32 {
    floating.enter(argument / 4, 2, if (floating.compiled) &floating.app.lifecycle else &lifecycle, argument);
}

fn floatingProtocol(hart: u32) callconv(.c) i32 {
    floating.enter(hart, 2, if (floating.compiled) &floating.app.protocol else &ipi.run, hart);
}

fn compiledStop() callconv(.c) u32 {
    return @intFromBool(ipi.requested());
}

fn compiledProgress(argument: u32) callconv(.c) void {
    memory.probe(argument);
    _ = @atomicRmw(u32, &reports[argument / 4].progress[argument % 4], .Add, 1, .release);
}

fn compiledSlept(hart: u32) callconv(.c) void {
    _ = @atomicRmw(u32, &reports[hart].sleeps, .Add, 1, .release);
}

fn compiledProtocol(hart: u32) callconv(.c) i32 {
    return ipi.run(hart);
}

comptime {
    if (floating.compiled) {
        @export(&compiledStop, .{ .name = "nih_fp_native_stop" });
        @export(&compiledProgress, .{ .name = "nih_fp_native_progress" });
        @export(&compiledSlept, .{ .name = "nih_fp_native_slept" });
        @export(&compiledProtocol, .{ .name = "nih_fp_native_protocol" });
    }
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

fn add(hart: u32, index: u32, kind: TaskKind) ?scheduler.TaskHandle {
    const owner = &owners[hart];
    const stack = &stacks[hart][index];
    const bottom = @intFromPtr(stack);
    const guard: *[4]u32 = @ptrCast(stack);
    guard.* = @splat(0x6e69_7374);
    const address = context.initialTaskFrameAddress(bottom, stack_bytes) orelse return null;
    const frame: *context.IntegerContext = @ptrFromInt(address);
    context.initialize(frame, .{
        .entry = switch (kind) {
            .busy => if (floating.enabled) @intFromPtr(&floatingBusy) else @intFromPtr(&busy),
            .initial_lifecycle, .replacement_lifecycle => if (floating.enabled) @intFromPtr(&floatingLifecycle) else @intFromPtr(&lifecycle),
            .ipi_protocol => if (floating.enabled) @intFromPtr(&floatingProtocol) else @intFromPtr(&ipi.run),
        },
        .argument = if (kind == .ipi_protocol) hart else hart * 4 + index + @intFromBool(kind == .replacement_lifecycle),
        .trampoline = @intFromPtr(&nih_native_task_trampoline),
        .global_pointer = owner.gp,
    });
    const handle = owner.runtime.add(0, .{
        .frame = frame,
        .state = initial_state,
        .stack_min = bottom + 16,
        .stack_max = bottom + stack_bytes,
    }) orelse return null;
    const bank = floating.prepare(hart, index, handle.generation, handle.slot);
    owner.runtime.images[handle.slot].?.floating_context = bank;
    if (bank != 0) owner.runtime.images[handle.slot].?.state = initial_state.floatingReady();
    return handle;
}

/// Called on the corresponding bootstrap stack before that hart enables MIE.
pub fn prepare(hart: u32, stack_min: u32, stack_max: u32, gp: u32) bool {
    const owner = &owners[hart];
    owner.gp = gp;
    owner.bootstrap = owner.runtime.add(0, .{ .stack_min = stack_min, .stack_max = stack_max }) orelse return false;
    _ = owner.runtime.policy.schedule() orelse return false;
    owner.last_slot = owner.bootstrap.slot;
    for (0..2) |index| owner.workers[index] = add(hart, @intCast(index), .busy) orelse return false;
    owner.lifecycle = add(hart, 2, .initial_lifecycle) orelse return false;
    owner.ready = true;
    return true;
}

pub fn ready(hart: u32) bool {
    return owners[hart].ready;
}

fn maintain(hart: u32, device: timer_group.Timer) bool {
    const owner = &owners[hart];
    if (owner.phase != .initial_lifecycle and owner.phase != .replacement_lifecycle)
        return maintainProtocol(hart, device);
    const completion = owner.runtime.policy.snapshot(owner.lifecycle) orelse return false;
    if (completion.state != .exited) return true;
    const expected: i32 = @intCast(42 + hart * 4 + @intFromBool(owner.phase == .replacement_lifecycle));
    if (completion.exit_code != expected) return false;
    owner.completed_runtime_ticks += completion.runtime_ticks;
    const old = owner.lifecycle;
    if (!floating.retire(hart, 2) or !owner.runtime.reap(old) or owner.runtime.policy.snapshot(old) != null) return false;
    // A scalar call using the old generation must fail even after slot reuse.
    owner.reaped += 1;
    owner.phase = if (owner.phase == .initial_lifecycle) .replacement_lifecycle else .preemption;
    if (owner.phase == .replacement_lifecycle) {
        owner.lifecycle = add(hart, 2, .replacement_lifecycle) orelse return false;
        if (owner.lifecycle.slot != old.slot or owner.lifecycle.generation == old.generation)
            return false;
    }
    const rejected = control.dispatch(&owner.runtime.policy, @backingInt(control.Number.wake), control.encodeHandle(old));
    return rejected.statusCode() == control.Status.not_found;
}

fn maintainProtocol(hart: u32, device: timer_group.Timer) bool {
    const owner = &owners[hart];
    if (owner.phase == .preemption and ipi.requested()) {
        for (owner.workers, 0..) |handle, index| {
            if (owner.worker_reaped[index]) continue;
            const completion = owner.runtime.policy.snapshot(handle) orelse return false;
            if (completion.state != .exited) continue;
            if (completion.exit_code != 100 + hart * 4 + index) return false;
            owner.completed_runtime_ticks += completion.runtime_ticks;
            if (!floating.retire(hart, @intCast(index)) or !owner.runtime.reap(handle)) return false;
            owner.worker_reaped[index] = true;
            owner.reaped += 1;
        }
        if (owner.worker_reaped[0] and owner.worker_reaped[1]) {
            owner.lifecycle = add(hart, 2, .ipi_protocol) orelse return false;
            if (!owner.runtime.policy.setPriority(owner.bootstrap, 1)) return false;
            owner.phase = .ipi_protocol;
            device.disarm(); // Counter still runs; no periodic wakeup fallback.
            ipi.ownerStarted(hart, owner.lifecycle, owner.timer_interrupts);
        }
    } else if (owner.phase == .ipi_protocol) {
        const completion = owner.runtime.policy.snapshot(owner.lifecycle) orelse return false;
        if (completion.state == .exited) {
            if (completion.exit_code != 200 + hart) return false;
            owner.completed_runtime_ticks += completion.runtime_ticks;
            if (!floating.retire(hart, 2) or !owner.runtime.reap(owner.lifecycle)) return false;
            owner.reaped += 1;
            owner.phase = .complete;
            ipi.ownerFinished(hart, owner.timer_interrupts);
        }
    }
    return true;
}

fn publish(hart: u32, selected: context.TaskContext) context.TaskContext {
    const owner = &owners[hart];
    floating.publish(hart);
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
    return owner.runtime.policy.elapse(advance.elapsed_ticks) and
        (alarmsDisarmed(owner) or device.armAt(advance.next_deadline));
}

fn alarmsDisarmed(owner: *const Owner) bool {
    return owner.phase == .ipi_protocol or owner.phase == .complete;
}

/// Only called from the permanent interrupt dispatcher, never a task stack.
pub fn onTimer(hart: u32, frame: *context.IntegerContext, state: context.ReturnState, device: timer_group.Timer) ?context.TaskContext {
    const owner = &owners[hart];
    if (alarmsDisarmed(owner)) return null;
    owner.timer_interrupts += 1;
    if (!guardsValid(hart) or !owner.runtime.capture(frame, state) or !refresh(hart, device)) return null;
    const current = owner.runtime.policy.current() orelse return null;
    floating.captured(hart, owner.runtime.images[current.slot].?.floating_context, .timer, frame.mepc);
    for (owner.workers, 0..) |handle, index| {
        if (current.slot == handle.slot) owner.captures[index] +%= 1;
    }
    if (!maintain(hart, device)) return null;
    return publish(hart, owner.runtime.select() orelse return null);
}

pub fn onCall(hart: u32, frame: *context.IntegerContext, state: context.ReturnState, device: timer_group.Timer) ?context.TaskContext {
    const owner = &owners[hart];
    if (!guardsValid(hart) or !refresh(hart, device)) return null;
    owner.calls +%= 1;
    const current = owner.runtime.policy.current() orelse return null;
    floating.captured(hart, owner.runtime.images[current.slot].?.floating_context, .calls, frame.mepc);
    const selected = owner.runtime.call(frame, state) orelse return null;
    if (!maintain(hart, device)) return null;
    return publish(hart, if (alarmsDisarmed(owner)) owner.runtime.select() orelse return null else selected);
}

pub fn onIpi(hart: u32, frame: *context.IntegerContext, state: context.ReturnState, device: timer_group.Timer) ?context.TaskContext {
    const owner = &owners[hart];
    if (!alarmsDisarmed(owner) or !guardsValid(hart) or !owner.runtime.capture(frame, state) or !refresh(hart, device)) return null;
    const current = owner.runtime.policy.current() orelse return null;
    floating.captured(hart, owner.runtime.images[current.slot].?.floating_context, .ipi, frame.mepc);
    ipi.drain(hart, &owner.runtime.policy, current.slot == owner.bootstrap.slot);
    return publish(hart, owner.runtime.select() orelse return null);
}

/// Bootstrap can park only after becoming the lower-priority idle context.
pub fn idleOnce(hart: u32) void {
    if (ipi.active(hart)) ipi.idleOnce(hart);
}
