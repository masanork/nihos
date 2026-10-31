//! Permanent native owner: the same runtime/policy/call ABI as hosted tasks.
//! Each hart mutates only its own Owner on its private IRQ stack with MIE=0.
pub const context = @import("context.zig");
pub const pmp = @import("pmp.zig");
const runtime_module = @import("task_runtime.zig");
pub const calls = @import("task_calls.zig");
const options = @import("native_options");
const control = @import("task_control");
const scheduler = @import("scheduler");
const tick_clock = @import("tick_clock");
const timer_group = @import("timer_group");
pub const ipi = @import("native_ipi.zig");
pub const floating = @import("native_floating.zig");
pub const memory = @import("native_memory");
pub const graphics = @import("native_graphics.zig");

const Runtime = runtime_module.Runtime(4, 2);
const stack_bytes = 4096;
comptime {
    if (stack_bytes != memory.stacks.layout.worker_bytes or memory.stacks.layout.guard_bytes != 16 or
        @sizeOf(context.IntegerContext) != memory.stacks.layout.frame_bytes)
        @compileError("native worker guard/context differs from the audited stack contract");
}
pub const period_us = 10_000;
const initial_state = context.ReturnState{ .mstatus = 0x1880, .mcause = 0 };
extern fn nih_native_task_trampoline() callconv(.c) void;
extern fn nih_storage_task_entry(u32) callconv(.c) i32;
extern fn nih_storage_register(u32, u32, u32, u32) callconv(.c) void;
extern fn nih_storage_pending(u32) callconv(.c) u32;
extern fn nih_storage_task_exited(u32, u32) callconv(.c) void;
extern fn nih_storage_cancel_requested() callconv(.c) u32;
extern fn nih_storage_cleanup_ready() callconv(.c) u32;
extern fn nih_storage_retired(u32) callconv(.c) void;
extern fn nih_broker_task_entry(u32) callconv(.c) i32;
extern fn nih_broker_register(u32, u32, u32) callconv(.c) void;
extern fn nih_broker_pending() callconv(.c) u32;
extern fn nih_broker_task_exited(u32) callconv(.c) void;
extern fn nih_broker_cleanup_ready() callconv(.c) u32;
extern fn nih_broker_round() callconv(.c) u32;
extern fn nih_broker_reaped() callconv(.c) void;
extern fn nih_broker_cancel_requested() callconv(.c) u32;
extern fn nih_broker_task_failed(u32) callconv(.c) noreturn;
extern fn nih_native_task_failed() callconv(.c) noreturn;
extern fn nih_normal_fs_task(u32) callconv(.c) i32;
// Linker symbols for the hardware probe. Referenced only when pmp_probe is
// true, so a product image does not take a relocation to this section.
extern const __user_probe_start: u8;
extern const __user_probe_end: u8;
extern fn nih_user_probe_trampoline() callconv(.c) void;
extern fn nih_user_probe_body() callconv(.c) void;

const normal_storage = @hasDecl(options, "normal_storage") and options.normal_storage;
const native_sqld = @hasDecl(options, "sqld") and options.sqld;
const normal_boot = @import("native_options").boot_fast;
const Phase = enum { normal, pmp_probe, initial_lifecycle, replacement_lifecycle, forced_lifecycle, preemption, ipi_protocol, complete, storage_service, storage_complete, broker_service, broker_complete, graphics };
const TaskKind = enum { busy, initial_lifecycle, replacement_lifecycle, forced_lifecycle, ipi_protocol, storage_protocol, broker_protocol, normal_storage };

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
    graphics_task: ?scheduler.TaskHandle = null,
    sqld_task: if (native_sqld) ?scheduler.TaskHandle else void = if (native_sqld) null else {},
    /// Protected task exited by a contained fault. Bootstrap reaps it after
    /// the ledger drain. This is not an extra scheduler slot.
    faulted: ?scheduler.TaskHandle = null,
    /// Live protected task. Its ticks stay in the publish sum until reaping
    /// moves them into completed_runtime_ticks. Null on every product boot.
    protected_task: ?scheduler.TaskHandle = null,
    /// Last contained fault observed by the hardware probe. Unused when the
    /// probe is not linked.
    probe_fault_cause: u32 = 0,
    probe_fault_mepc: u32 = 0,
    /// Code TOR read back from the unlocked entries. Entries 0 and 1 stay at
    /// the bootloader's locked NAPOT values, so they are not evidence.
    probe_pmpaddr4: u32 = 0,
    probe_pmpaddr5: u32 = 0,
    probe_mhint: u32 = 0,
    probe_user_timers: u32 = 0,
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
var stacks: [2][3][stack_bytes]u8 align(16) linksection(".native.task_stacks") = undefined;
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
    memory.reusable.lifecycleProbe();
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

fn forced(argument: u32) callconv(.c) i32 {
    var marker = argument;
    if (!onTaskStack(argument / 4, 2, @intFromPtr(&marker), @sizeOf(u32))) nih_native_task_failed();
    memory.reusable.lifecycleProbe();
    _ = calls.block();
    nih_native_task_failed(); // A terminated task must never resume.
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

fn compiledResources() callconv(.c) void {
    memory.reusable.lifecycleProbe();
}

comptime {
    if (floating.compiled) {
        @export(&compiledStop, .{ .name = "nih_fp_native_stop" });
        @export(&compiledProgress, .{ .name = "nih_fp_native_progress" });
        @export(&compiledSlept, .{ .name = "nih_fp_native_slept" });
        @export(&compiledProtocol, .{ .name = "nih_fp_native_protocol" });
        @export(&compiledResources, .{ .name = "nih_fp_native_resources" });
    }
}

fn onTaskStack(hart: u32, index: u32, address: u32, bytes: u32) bool {
    const bottom = @intFromPtr(&stacks[hart][index]);
    return address >= bottom + 16 and address <= bottom + stack_bytes - bytes;
}

fn guardsValid(hart: u32) bool {
    for (&stacks[hart]) |*stack| {
        const guard: *volatile [4]u32 = @ptrCast(stack);
        for (0..4) |word| if (guard[word] != memory.stacks.layout.worker_guard) return false;
    }
    return true;
}

fn add(hart: u32, index: u32, kind: TaskKind) ?scheduler.TaskHandle {
    const owner = &owners[hart];
    const stack = &stacks[hart][index];
    const bottom = @intFromPtr(stack);
    const guard: *[4]u32 = @ptrCast(stack);
    guard.* = @splat(memory.stacks.layout.worker_guard);
    const address = context.initialTaskFrameAddress(bottom, stack_bytes) orelse return null;
    const frame: *context.IntegerContext = @ptrFromInt(address);
    context.initialize(frame, .{
        .entry = switch (kind) {
            .busy => if (floating.enabled) @intFromPtr(&floatingBusy) else @intFromPtr(&busy),
            .initial_lifecycle, .replacement_lifecycle => if (floating.enabled) @intFromPtr(&floatingLifecycle) else @intFromPtr(&lifecycle),
            .ipi_protocol => if (floating.enabled) @intFromPtr(&floatingProtocol) else @intFromPtr(&ipi.run),
            .forced_lifecycle => @intFromPtr(&forced),
            .storage_protocol => if (options.storage_service) @intFromPtr(&nih_storage_task_entry) else 0,
            .broker_protocol => if (options.broker) @intFromPtr(&nih_broker_task_entry) else 0,
            .normal_storage => if (normal_storage) @intFromPtr(&nih_normal_fs_task) else 0,
        },
        .argument = if (kind == .ipi_protocol or kind == .storage_protocol or kind == .broker_protocol) hart else hart * 4 + index + @intFromBool(kind == .replacement_lifecycle),
        .trampoline = @intFromPtr(&nih_native_task_trampoline),
        .global_pointer = owner.gp,
    });
    const handle = owner.runtime.add(0, .{
        .frame = frame,
        .state = initial_state,
        .stack_min = bottom + 16,
        .stack_max = bottom + stack_bytes,
    }) orelse return null;
    if (!memory.reusable.openTask(hart, .{ .slot = handle.slot, .generation = handle.generation })) return null;
    const bank = if (kind == .forced_lifecycle or kind == .storage_protocol or kind == .normal_storage) 0 else floating.prepare(hart, index, handle.generation, handle.slot);
    owner.runtime.images[handle.slot].?.floating_context = bank;
    if (bank != 0) owner.runtime.images[handle.slot].?.state = initial_state.floatingReady();
    return handle;
}

/// Called on the corresponding bootstrap stack before that hart enables MIE.
pub fn prepare(hart: u32, stack_min: u32, stack_max: u32, gp: u32) bool {
    const owner = &owners[hart];
    if (options.pmp_probe) owner.runtime.protected_admission = .diagnostic;
    owner.gp = gp;
    owner.bootstrap = owner.runtime.add(0, .{ .stack_min = stack_min, .stack_max = stack_max }) orelse return false;
    if (!memory.reusable.openTask(hart, key(owner.bootstrap))) return false;
    memory.reusable.selectTask(hart, key(owner.bootstrap));
    _ = owner.runtime.policy.schedule() orelse return false;
    owner.last_slot = owner.bootstrap.slot;
    if (normal_boot or options.pmp_probe) {
        for (&stacks[hart]) |*stack| {
            const guard: *[4]u32 = @ptrCast(stack);
            guard.* = @splat(memory.stacks.layout.worker_guard);
        }
        owner.phase = if (options.pmp_probe) .pmp_probe else .normal;
        if (normal_storage and hart == 0 and !options.pmp_probe) owner.workers[0] = add(hart, 0, .normal_storage) orelse return false;
        owner.ready = true;
        return true;
    }
    for (0..2) |index| owner.workers[index] = add(hart, @intCast(index), .busy) orelse return false;
    owner.lifecycle = add(hart, 2, .initial_lifecycle) orelse return false;
    owner.ready = true;
    return true;
}

// CPU0 bootstrap's synchronous renderer. Both calls require MIE=0; the
// assembly bridge enables interrupts only after moving to the admitted stack.
pub inline fn beginForegroundStack(low: u32, high: u32) ?runtime_module.Image {
    if (asm volatile ("csrr %[v], mstatus"
        : [v] "=r" (-> u32),
    ) & 8 != 0 or !owners[0].ready) return null;
    return owners[0].runtime.beginStackSwitch(owners[0].bootstrap, low, high);
}
pub inline fn endForegroundStack(original: runtime_module.Image) bool {
    if (asm volatile ("csrr %[v], mstatus"
        : [v] "=r" (-> u32),
    ) & 8 != 0) return false;
    return owners[0].runtime.endStackSwitch(owners[0].bootstrap, original);
}

pub fn ready(hart: u32) bool {
    return owners[hart].ready;
}

/// Trusted CPU0 foreground wake; no MMIO/FS work occurs on the IRQ stack.
pub fn wakeNormalStorage() void {
    if (!normal_storage) return;
    const previous = asm volatile ("csrrci %[v],mstatus,8"
        : [v] "=r" (-> u32),
        :
        : .{ .memory = true });
    _ = owners[0].runtime.policy.notify(owners[0].workers[0], 1);
    if (previous & 8 != 0) asm volatile ("csrsi mstatus,8" ::: .{ .memory = true });
}

fn maintain(hart: u32, device: timer_group.Timer) bool {
    if (normal_boot or options.pmp_probe) return true;
    const owner = &owners[hart];
    if (options.broker and owner.phase == .broker_complete) return true;
    if (options.broker and owner.phase == .broker_service) {
        const completion = owner.runtime.policy.snapshot(owner.lifecycle) orelse return false;
        if (completion.state != .exited) return true;
        const round = nih_broker_round();
        const expected: i32 = if (round == 3) -97 else @intCast(400 + round);
        if (completion.exit_code != expected) return false;
        if (!memory.reusable.taskCleaned(hart, key(owner.lifecycle)) or nih_broker_cleanup_ready() != round) return true;
        owner.completed_runtime_ticks += completion.runtime_ticks;
        if (!owner.runtime.reap(owner.lifecycle)) return false;
        nih_broker_reaped();
        if (round < 4) return admitBroker(hart);
        owner.phase = .broker_complete;
        return true;
    }
    if (options.storage_service and owner.phase == .storage_service) {
        const completion = owner.runtime.policy.snapshot(owner.lifecycle) orelse return false;
        if (completion.state != .exited) return true;
        const restart = hart == 1 and completion.exit_code == -98;
        if (!restart and completion.exit_code != 300 + hart) return false;
        if (!memory.reusable.taskCleaned(hart, key(owner.lifecycle)) or nih_storage_cleanup_ready() != (if (restart) @as(u32, 1) else 2)) return true;
        owner.completed_runtime_ticks += completion.runtime_ticks;
        if (!owner.runtime.reap(owner.lifecycle)) return false;
        if (restart) return admitStorage(hart);
        owner.phase = .storage_complete;
        nih_storage_retired(hart);
        return true;
    }
    if (owner.phase != .initial_lifecycle and owner.phase != .replacement_lifecycle and owner.phase != .forced_lifecycle)
        return maintainProtocol(hart, device);
    const completion = owner.runtime.policy.snapshot(owner.lifecycle) orelse return false;
    if (completion.state != .exited) return true;
    const expected: i32 = if (owner.phase == .forced_lifecycle) -99 else @intCast(42 + hart * 4 + @intFromBool(owner.phase == .replacement_lifecycle));
    if (completion.exit_code != expected) return false;
    if (!memory.reusable.taskCleaned(hart, key(owner.lifecycle))) return true;
    owner.completed_runtime_ticks += completion.runtime_ticks;
    const old = owner.lifecycle;
    if ((owner.phase != .forced_lifecycle and !floating.retire(hart, 2)) or
        !owner.runtime.reap(old) or owner.runtime.policy.snapshot(old) != null) return false;
    // A scalar call using the old generation must fail even after slot reuse.
    owner.reaped += 1;
    owner.phase = switch (owner.phase) {
        .initial_lifecycle => .replacement_lifecycle,
        .replacement_lifecycle => .forced_lifecycle,
        else => .preemption,
    };
    if (owner.phase == .replacement_lifecycle or owner.phase == .forced_lifecycle) {
        owner.lifecycle = add(hart, 2, if (owner.phase == .replacement_lifecycle) .replacement_lifecycle else .forced_lifecycle) orelse return false;
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
            if (!memory.reusable.taskCleaned(hart, key(handle))) continue;
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
            if (!memory.reusable.taskCleaned(hart, key(owner.lifecycle))) return true;
            owner.completed_runtime_ticks += completion.runtime_ticks;
            if (!floating.retire(hart, 2) or !owner.runtime.reap(owner.lifecycle)) return false;
            owner.reaped += 1;
            owner.phase = .complete;
            ipi.ownerFinished(hart, owner.timer_interrupts);
        }
    }
    return true;
}

pub noinline fn onProtectedFault(hart: u32, frame: *context.IntegerContext, state: context.ReturnState) linksection(pmp.text_section) ?context.TaskContext {
    const owner = &owners[hart];
    if (options.pmp_probe) {
        owner.probe_fault_cause = state.mcause;
        owner.probe_fault_mepc = frame.mepc;
        noteProbeGrant(owner);
    }
    const fault = owner.runtime.containFault();
    if (fault.exited) |handle| {
        if (!closeFaulted(hart, handle)) return null;
    }
    const selected = fault.next orelse return null;
    return publish(hart, selected);
}

/// Close the faulted task's ledger before the replacement is published.
/// The handle stays occupied until bootstrap drains the ledger and reaps it.
/// A non-zero floating bank is rejected: this class never owns one.
noinline fn closeFaulted(hart: u32, handle: scheduler.TaskHandle) linksection(pmp.text_section) bool {
    const owner = &owners[hart];
    if (!owner.runtime.faultCloseable(handle)) return false;
    if (!memory.reusable.closeTask(hart, key(handle))) return false;
    if (owner.faulted) |pending| {
        if (pending.slot != handle.slot or pending.generation != handle.generation) return false;
    } else owner.faulted = handle;
    return true;
}

noinline fn reclaimFaulted(hart: u32) linksection(pmp.text_section) bool {
    const owner = &owners[hart];
    const handle = owner.faulted orelse return true;
    switch (owner.runtime.reclaimIfClean(handle, memory.reusable.taskCleaned(hart, key(handle)), &owner.completed_runtime_ticks)) {
        .waiting => return true,
        .refused => return false,
        .reaped => {
            owner.faulted = null;
            owner.reaped += 1;
            return true;
        },
    }
}

pub fn armProtection(hart: u32, selected: context.TaskContext) void {
    pmp.arm(hart, selected.protection);
}

fn publish(hart: u32, selected: context.TaskContext) context.TaskContext {
    const owner = &owners[hart];
    floating.publish(hart);
    var total = owner.completed_runtime_ticks;
    for ([_]scheduler.TaskHandle{ owner.bootstrap, owner.workers[0], owner.workers[1], owner.lifecycle }) |handle| {
        if (owner.runtime.policy.snapshot(handle)) |snapshot| total += snapshot.runtime_ticks;
    }
    if (native_sqld) if (owner.sqld_task) |handle| if (owner.runtime.policy.snapshot(handle)) |snapshot| {
        total += snapshot.runtime_ticks;
    };
    if (owner.graphics_task) |handle| if (owner.runtime.policy.snapshot(handle)) |snapshot| {
        total += snapshot.runtime_ticks;
    };
    if (owner.protected_task) |handle| if (owner.runtime.policy.snapshot(handle)) |snapshot| {
        total += snapshot.runtime_ticks;
    };
    if (total != owner.runtime.policy.now()) {
        if (options.broker and owner.phase == .broker_service) nih_broker_task_failed(64);
        nih_native_task_failed();
    }
    const current = owner.runtime.policy.current() orelse nih_native_task_failed();
    memory.reusable.selectTask(hart, key(current));
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
    return owner.clock.refresh(&owner.runtime.policy, device, !alarmsDisarmed(owner));
}

fn alarmsDisarmed(owner: *const Owner) bool {
    return owner.phase == .ipi_protocol or owner.phase == .complete or owner.phase == .storage_service or owner.phase == .storage_complete or owner.phase == .broker_service or owner.phase == .broker_complete;
}

/// Only called from the permanent interrupt dispatcher, never a task stack.
pub fn onTimer(hart: u32, frame: *context.IntegerContext, state: context.ReturnState, device: timer_group.Timer) ?context.TaskContext {
    const owner = &owners[hart];
    if (alarmsDisarmed(owner)) return null;
    owner.timer_interrupts += 1;
    if (!guardsValid(hart) or !owner.runtime.capture(frame, state) or !refresh(hart, device)) return null;
    const current = owner.runtime.policy.current() orelse return null;
    if (options.pmp_probe and state.mstatus & pmp.mpp_mask == pmp.user_mpp and
        owner.runtime.images[current.slot].?.protection != null) owner.probe_user_timers += 1;
    if (@import("native_options").graphics and hart == 0) graphics.exchange.composer.captureTimer(frame.mepc);
    if (@import("native_options").graphics and owner.graphics_task != null and current.slot == owner.graphics_task.?.slot) graphics.capture(frame, true);
    floating.captured(hart, owner.runtime.images[current.slot].?.floating_context, .timer, frame.mepc);
    for (owner.workers, 0..) |handle, index| {
        if (!normal_boot and current.slot == handle.slot) owner.captures[index] +%= 1;
    }
    if (!maintain(hart, device)) return null;
    return publish(hart, owner.runtime.select() orelse return null);
}

fn noteProbeGrant(owner: *Owner) void {
    if (comptime !options.pmp_probe) return;
    owner.probe_mhint = asm volatile ("csrr %[result], 0x7c5"
        : [result] "=r" (-> u32),
    );
    owner.probe_pmpaddr4 = asm volatile ("csrr %[result], pmpaddr4"
        : [result] "=r" (-> u32),
    );
    owner.probe_pmpaddr5 = asm volatile ("csrr %[result], pmpaddr5"
        : [result] "=r" (-> u32),
    );
}

pub fn onCall(hart: u32, frame: *context.IntegerContext, state: context.ReturnState, device: timer_group.Timer) ?context.TaskContext {
    const owner = &owners[hart];
    if (!guardsValid(hart) or !refresh(hart, device)) return null;
    if (options.pmp_probe and state.mstatus & pmp.mpp_mask == pmp.user_mpp) noteProbeGrant(owner);
    owner.calls +%= 1;
    const current = owner.runtime.policy.current() orelse return null;
    if (@import("native_options").graphics and owner.graphics_task != null and current.slot == owner.graphics_task.?.slot) graphics.capture(frame, false);
    floating.captured(hart, owner.runtime.images[current.slot].?.floating_context, .calls, frame.mepc);
    const selected = owner.runtime.call(frame, state) orelse return null;
    // Closing is common to every native EXIT caller, independent of fixture
    // kind. It only marks the internal ledger; bootstrap performs the frees.
    if ((owner.runtime.policy.snapshot(current) orelse return null).state == .exited and
        !memory.reusable.closeTask(hart, key(current))) return null;
    if (options.storage_service and owner.phase == .storage_service and (owner.runtime.policy.snapshot(current) orelse return null).state == .exited)
        nih_storage_task_exited(hart, control.encodeHandle(current));
    if (options.broker and owner.phase == .broker_service and (owner.runtime.policy.snapshot(current) orelse return null).state == .exited)
        nih_broker_task_exited(control.encodeHandle(current));
    if (!maintain(hart, device)) return null;
    return publish(hart, if (alarmsDisarmed(owner)) owner.runtime.select() orelse return null else selected);
}

pub fn onIpi(hart: u32, frame: *context.IntegerContext, state: context.ReturnState, device: timer_group.Timer) ?context.TaskContext {
    const owner = &owners[hart];
    if (!alarmsDisarmed(owner) or !guardsValid(hart) or !owner.runtime.capture(frame, state) or !refresh(hart, device)) return null;
    const current = owner.runtime.policy.current() orelse return null;
    floating.captured(hart, owner.runtime.images[current.slot].?.floating_context, .ipi, frame.mepc);
    if (options.broker and (owner.phase == .broker_service or owner.phase == .broker_complete)) {
        ipi.bell(hart).acknowledge();
        if (owner.phase == .broker_service and nih_broker_pending() != 0) _ = owner.runtime.policy.notify(owner.lifecycle, 1);
        if (!maintain(hart, device)) return null;
    } else if (options.storage_service and (owner.phase == .storage_service or owner.phase == .storage_complete)) {
        ipi.bell(hart).acknowledge();
        if (nih_storage_pending(hart) != 0) _ = owner.runtime.policy.notify(owner.lifecycle, 1);
        if (!maintain(hart, device)) return null;
    } else ipi.drain(hart, &owner.runtime.policy, current.slot == owner.bootstrap.slot);
    return publish(hart, owner.runtime.select() orelse return null);
}

/// Bootstrap can park only after becoming the lower-priority idle context.
pub fn idleOnce(hart: u32) void {
    if (service(hart)) return;
    if (normal_boot or options.pmp_probe) asm volatile ("wfi" ::: .{ .memory = true }) else if (ipi.active(hart)) ipi.idleOnce(hart);
}

fn key(handle: scheduler.TaskHandle) memory.reusable.Key {
    return .{ .slot = handle.slot, .generation = handle.generation };
}

/// Called only by the running bootstrap. No PSRAM access occurs on IRQ stacks.
pub fn service(hart: u32) bool {
    const owner = &owners[hart];
    const status = asm volatile ("csrrci %[result], mstatus, 8"
        : [result] "=r" (-> u32),
        :
        : .{ .memory = true });
    var terminated = false;
    if (options.broker and owner.phase == .broker_service and nih_broker_pending() != 0) {
        _ = owner.runtime.policy.notify(owner.lifecycle, 1);
    }
    if (options.broker and hart == 1 and owner.phase == .broker_service and nih_broker_cancel_requested() == 1) {
        const snapshot = owner.runtime.policy.snapshot(owner.lifecycle) orelse nih_broker_task_failed(61);
        if (snapshot.state == .waiting) {
            if (!owner.runtime.policy.terminate(owner.lifecycle, -97)) nih_broker_task_failed(62);
            if (!memory.reusable.closeTask(hart, key(owner.lifecycle))) nih_broker_task_failed(63);
            memory.reusable.terminatedTask(hart);
            nih_broker_task_exited(control.encodeHandle(owner.lifecycle));
            terminated = true;
        }
    }
    if (owner.phase == .forced_lifecycle) {
        const snapshot = owner.runtime.policy.snapshot(owner.lifecycle) orelse nih_native_task_failed();
        if (snapshot.state == .blocked) {
            if (!owner.runtime.policy.terminate(owner.lifecycle, -99)) nih_native_task_failed();
            if (!memory.reusable.closeTask(hart, key(owner.lifecycle))) nih_native_task_failed();
            memory.reusable.terminatedTask(hart);
            terminated = true;
        }
    }
    if (options.storage_service and hart == 1 and owner.phase == .storage_service and nih_storage_cancel_requested() == 1) {
        const snapshot = owner.runtime.policy.snapshot(owner.lifecycle) orelse nih_native_task_failed();
        // waitEvents parks in .waiting; .blocked belongs to the scalar block call.
        if (snapshot.state == .waiting) {
            if (!owner.runtime.policy.terminate(owner.lifecycle, -98)) nih_native_task_failed();
            if (!memory.reusable.closeTask(hart, key(owner.lifecycle))) nih_native_task_failed();
            memory.reusable.terminatedTask(hart);
            nih_storage_task_exited(hart, control.encodeHandle(owner.lifecycle));
            terminated = true;
        }
    }
    if (status & 8 != 0) asm volatile ("csrsi mstatus, 8" ::: .{ .memory = true });
    const cleaned = memory.reusable.cleanupOne();
    if (owner.faulted != null) {
        const saved = asm volatile ("csrrci %[result], mstatus, 8"
            : [result] "=r" (-> u32),
            :
            : .{ .memory = true });
        defer if (saved & 8 != 0) asm volatile ("csrsi mstatus, 8" ::: .{ .memory = true });
        if (!reclaimFaulted(hart)) nih_native_task_failed();
    }
    if (cleaned == .complete or terminated) {
        if (calls.yieldNow() != 0) nih_native_task_failed();
    }
    return cleaned != .none or terminated;
}

/// Reuses the retired lifecycle stack after both ordinary IPI protocols end.
/// One new file owner/client task per hart; no task stack is reused while live.
pub fn startStorage(hart: u32) bool {
    if (!options.storage_service) return false;
    const status = asm volatile ("csrrci %[result], mstatus, 8"
        : [result] "=r" (-> u32),
        :
        : .{ .memory = true });
    defer if (status & 8 != 0) asm volatile ("csrsi mstatus, 8" ::: .{ .memory = true });
    const owner = &owners[hart];
    if (owner.phase != .complete and !(options.fatfs_native and owner.phase == .broker_complete)) return false;
    return admitStorage(hart);
}

noinline fn admitStorage(hart: u32) bool {
    const owner = &owners[hart];
    owner.lifecycle = add(hart, 2, .storage_protocol) orelse return false;
    owner.phase = .storage_service;
    const bottom = @intFromPtr(&stacks[hart][2]);
    nih_storage_register(hart, control.encodeHandle(owner.lifecycle), bottom + 16, bottom + stack_bytes);
    return true;
}

pub fn startBroker(hart: u32) bool {
    if (!options.broker or hart != 1) return false;
    const status = asm volatile ("csrrci %[result], mstatus, 8"
        : [result] "=r" (-> u32),
        :
        : .{ .memory = true });
    defer if (status & 8 != 0) asm volatile ("csrsi mstatus, 8" ::: .{ .memory = true });
    if (owners[hart].phase != .complete and owners[hart].phase != .storage_complete) return false;
    return admitBroker(hart);
}
noinline fn admitBroker(hart: u32) bool {
    const owner = &owners[hart];
    owner.lifecycle = add(hart, 2, .broker_protocol) orelse return false;
    owner.phase = .broker_service;
    const bottom = @intFromPtr(&stacks[hart][2]);
    nih_broker_register(control.encodeHandle(owner.lifecycle), bottom + 16, bottom + stack_bytes);
    return true;
}

/// One-shot post-soak fixture. Only bootstrap enters; fonts never run in IRQ.
pub fn runGraphics(device: timer_group.Timer) ?graphics.Report {
    const hart = asm volatile ("csrr %[result], mhartid"
        : [result] "=r" (-> u32),
    );
    const live_status = asm volatile ("csrr %[result], mstatus"
        : [result] "=r" (-> u32),
    );
    if (!@import("native_options").graphics or hart != 0 or live_status & 8 == 0) return null;
    const owner = &owners[0];
    const current = owner.runtime.policy.current() orelse return null;
    if (current.slot != owner.bootstrap.slot or current.generation != owner.bootstrap.generation or
        owner.phase != .complete or owner.graphics_task != null or !graphics.prepare()) return null;
    const status = asm volatile ("csrrci %[result], mstatus, 8"
        : [result] "=r" (-> u32),
        :
        : .{ .memory = true });
    if (status & 8 == 0 or owner.phase != .complete or owner.graphics_task != null) return null;
    const address = context.initialTaskFrameAddress(graphics.bottom(), 32768) orelse return null;
    const frame: *context.IntegerContext = @ptrFromInt(address);
    context.initialize(frame, .{ .entry = @intFromPtr(&graphics.entry), .argument = 0, .trampoline = @intFromPtr(&nih_native_task_trampoline), .global_pointer = owner.gp });
    const handle = owner.runtime.add(1, .{ .frame = frame, .state = initial_state, .stack_min = graphics.bottom() + 16, .stack_max = graphics.top() }) orelse return null;
    if (!memory.reusable.openTask(0, key(handle))) return null;
    if (!graphics.exchange.bind(.{ .slot = owner.bootstrap.slot, .generation = owner.bootstrap.generation }, .{ .slot = handle.slot, .generation = handle.generation })) return null;
    owner.graphics_task = handle;
    owner.phase = .graphics;
    if (!refresh(0, device)) return null;
    asm volatile ("csrsi mstatus, 8" ::: .{ .memory = true });
    while (true) {
        graphics.progress();
        _ = service(0);
        const waiting = owner.runtime.policy.snapshot(handle) orelse return null;
        graphics.exchange.poll(owner.runtime.policy.now(), waiting.runtime_ticks, waiting.state == .waiting);
        const snapshot = owner.runtime.policy.snapshot(handle) orelse return null;
        if (snapshot.state == .exited and memory.reusable.taskCleaned(0, key(handle))) {
            const saved = asm volatile ("csrrci %[result], mstatus, 8"
                : [result] "=r" (-> u32),
                :
                : .{ .memory = true });
            defer if (saved & 8 != 0) asm volatile ("csrsi mstatus, 8" ::: .{ .memory = true });
            if (snapshot.exit_code != 0 or !owner.runtime.reap(handle)) return null;
            owner.completed_runtime_ticks += snapshot.runtime_ticks;
            owner.graphics_task = null;
            owner.phase = .complete;
            device.disarm();
            const result = graphics.finish() orelse return null;
            if (!graphics.stack.reaped(.{ .acknowledged = graphics.exchange.finished(), .exited = snapshot.state == .exited, .cleaned = memory.reusable.taskCleaned(0, key(handle)), .reaped = owner.graphics_task == null })) return null;
            return result;
        }
        if (calls.yieldNow() != 0) return null;
    }
}

pub const ProbeStep = struct {
    exit_code: i32,
    reaped: u32,
    calls: u32,
    timer_interrupts: u32,
    user_timer_interrupts: u32,
    kernel_mstatus: u32,
    live_mstatus: u32,
    grant_hi: u32,
    slot: u16,
    generation: u16,
    data_word: u32,
    fault_cause: u32,
    fault_mepc: u32,
    pmpaddr4: u32,
    pmpaddr5: u32,
    user_mhint: u32,
    kernel_mhint: u32,
};

fn maskInterrupts() u32 {
    return asm volatile ("csrrci %[result], mstatus, 8"
        : [result] "=r" (-> u32),
        :
        : .{ .memory = true });
}

fn restoreInterrupts(status: u32) void {
    if (status & 8 != 0) asm volatile ("csrsi mstatus, 8" ::: .{ .memory = true });
}

fn probeArena() *align(128) [1024]u8 {
    const Store = struct {
        var bytes: [1024]u8 align(128) = undefined;
    };
    return &Store.bytes;
}

/// One protected case on CPU0. The caller is bootstrap. A null result means
/// this hart did not get back to the kernel with a reaped task.
pub fn runProbeCase(case_id: u32) ?ProbeStep {
    if (comptime !options.pmp_probe) return null;
    return runProbeCaseLive(case_id);
}

fn runProbeCaseLive(case_id: u32) ?ProbeStep {
    const hart = asm volatile ("csrr %[result], mhartid"
        : [result] "=r" (-> u32),
    );
    if (hart != 0 or case_id >= pmp.probe_cases) return null;
    const owner = &owners[hart];
    if (owner.phase != .pmp_probe or !owner.ready or owner.faulted != null or owner.protected_task != null) return null;
    owner.probe_fault_cause = 0;
    owner.probe_fault_mepc = 0;
    owner.probe_pmpaddr4 = 0;
    owner.probe_pmpaddr5 = 0;
    owner.probe_mhint = 0;
    const saved = maskInterrupts();
    if (!owner.runtime.policy.setPriority(owner.bootstrap, 1)) {
        restoreInterrupts(saved);
        return null;
    }
    const handle = admitProbe(hart, case_id) orelse {
        restoreInterrupts(saved);
        return null;
    };
    restoreInterrupts(saved);
    if (calls.yieldNow() != 0) return null;
    const pending = owner.runtime.policy.snapshot(handle) orelse return null;
    if (pending.state != .exited) return null;
    const exit_code = pending.exit_code;
    var spins: u32 = 0;
    while (owner.runtime.policy.snapshot(handle) != null) {
        spins += 1;
        if (spins > 8) return null;
        _ = service(hart);
        if (owner.faulted != null) continue;
        const snap = owner.runtime.policy.snapshot(handle) orelse break;
        if (snap.state != .exited or !memory.reusable.taskCleaned(hart, key(handle))) continue;
        const held = maskInterrupts();
        const current = owner.runtime.policy.snapshot(handle) orelse {
            restoreInterrupts(held);
            return null;
        };
        owner.completed_runtime_ticks += current.runtime_ticks;
        if (!owner.runtime.reap(handle)) {
            restoreInterrupts(held);
            return null;
        }
        owner.reaped += 1;
        owner.protected_task = null;
        restoreInterrupts(held);
        break;
    }
    if (owner.runtime.policy.snapshot(handle) != null or owner.faulted != null) return null;
    if (owner.protected_task) |live| {
        if (live.slot != handle.slot or live.generation != handle.generation) return null;
        const held = maskInterrupts();
        owner.protected_task = null;
        restoreInterrupts(held);
    }
    const image = owner.runtime.images[owner.bootstrap.slot] orelse return null;
    if (image.protection != null) return null;
    const live_mstatus = asm volatile ("csrr %[result], mstatus"
        : [result] "=r" (-> u32),
    );
    const data_word: u32 = if (comptime options.pmp_probe) @as(*const u32, @ptrCast(@alignCast(probeArena()))).* else 0;
    return .{
        .exit_code = exit_code,
        .reaped = owner.reaped,
        .calls = owner.calls,
        .timer_interrupts = owner.timer_interrupts,
        .user_timer_interrupts = owner.probe_user_timers,
        .kernel_mstatus = image.state.mstatus,
        .live_mstatus = live_mstatus,
        .grant_hi = pmp.publishedGrantHi(hart),
        .slot = handle.slot,
        .generation = handle.generation,
        .data_word = data_word,
        .fault_cause = owner.probe_fault_cause,
        .fault_mepc = owner.probe_fault_mepc,
        .pmpaddr4 = owner.probe_pmpaddr4,
        .pmpaddr5 = owner.probe_pmpaddr5,
        .user_mhint = owner.probe_mhint,
        .kernel_mhint = asm volatile ("csrr %[result], 0x7c5"
            : [result] "=r" (-> u32),
        ),
    };
}

fn admitProbe(hart: u32, case_id: u32) ?scheduler.TaskHandle {
    if (comptime !options.pmp_probe) return null;
    const owner = &owners[hart];
    const arena = probeArena();
    @memset(arena, 0);
    const data_lo: u32 = @intFromPtr(arena);
    const data_hi = data_lo + arena.len;
    const code_lo: u32 = @intFromPtr(&__user_probe_start);
    const code_hi: u32 = @intFromPtr(&__user_probe_end);
    if (data_lo & 127 != 0 or data_hi & 127 != 0 or code_lo & 127 != 0 or code_hi & 127 != 0 or code_lo >= code_hi) return null;
    const address = context.initialTaskFrameAddress(data_lo, arena.len) orelse return null;
    const frame: *context.IntegerContext = @ptrFromInt(address);
    context.initialize(frame, .{
        .entry = @intFromPtr(&nih_user_probe_body),
        .argument = case_id,
        .trampoline = @intFromPtr(&nih_user_probe_trampoline),
        .global_pointer = 0,
    });
    frame.a2 = data_lo;
    const handle = owner.runtime.add(0, .{
        .frame = frame,
        .state = .{ .mstatus = pmp.user_mstatus, .mcause = 0 },
        .stack_min = data_lo,
        .stack_max = data_hi,
        .protection = .{
            .code_lo = code_lo,
            .code_hi = code_hi,
            .data_lo = data_lo,
            .data_hi = data_hi,
        },
    }) orelse return null;
    if (!memory.reusable.openTask(hart, key(handle))) return null;
    owner.protected_task = handle;
    return handle;
}

extern fn nih_sqld_native_task(u32) callconv(.c) i32;
extern fn nih_sqld_native_prepare(u32, u32) callconv(.c) void;
pub noinline fn startSqld() linksection(".flash.sqldtext") bool {
    const owner = &owners[0];
    const bottom: u32 = 0x483c0000;
    const top: u32 = bottom + 65536;
    @memset(@as([*]u8, @ptrFromInt(bottom))[0..65536], 0xa5);
    const frame: *context.IntegerContext = @ptrFromInt(top - 128);
    context.initialize(frame, .{ .entry = @intFromPtr(&nih_sqld_native_task), .argument = 0, .trampoline = @intFromPtr(&nih_native_task_trampoline), .global_pointer = owner.gp });
    const previous = asm volatile ("csrrci %[v],mstatus,8"
        : [v] "=r" (-> u32),
        :
        : .{ .memory = true });
    defer {
        if (previous & 8 != 0) asm volatile ("csrsi mstatus,8" ::: .{ .memory = true });
    }
    const handle = owner.runtime.add(0, .{ .frame = frame, .state = initial_state, .stack_min = bottom + 256, .stack_max = top }) orelse return false;
    if (!memory.reusable.openTask(0, key(handle))) return false;
    owner.sqld_task = handle;
    nih_sqld_native_prepare(control.encodeHandle(owner.bootstrap), control.encodeHandle(handle));
    return true;
}
pub fn wakeSqld(bits: u32) void {
    const previous = asm volatile ("csrrci %[v],mstatus,8"
        : [v] "=r" (-> u32),
        :
        : .{ .memory = true });
    defer {
        if (previous & 8 != 0) asm volatile ("csrsi mstatus,8" ::: .{ .memory = true });
    }
    if (bits & 3 != 0) if (owners[0].sqld_task) |handle| {
        _ = owners[0].runtime.policy.notify(handle, bits & 3);
    };
    if (bits & 4 != 0) _ = owners[0].runtime.policy.notify(owners[0].bootstrap, 4);
}
