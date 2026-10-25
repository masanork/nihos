//! Both cores own bounded native windows. CPU0 schedules tasks; CPU1 is one
//! integer echo service whose foreground parks and whose IPI tail is bounded.
const std = @import("std");
const context = @import("context.zig");
const calls = @import("task_calls.zig");
const idle = @import("idle.zig");
const park = @import("park");
const cpu1_tasks = @import("cpu1_tasks.zig");
const timer_group = @import("timer_group");
const rings = @import("spsc_ring");
const remote = @import("remote_events");
const Doorbell = @import("software_ipi").Doorbell;
const Inbox = remote.Inbox(rings.SpscRing(remote.Notification, 4));
const Message = struct { sequence: u32, payload: u32 };
const Ring = rings.SpscRing(Message, 3);
const Lease = extern struct { register_address: u32, interrupt_id: u32 };
const TimerLease = extern struct { group_address: u32, channel_id: u32, interrupt_id: u32 };
const messages: u32 = 64;
const response_bit: u32 = 1;
const finished_bit: u32 = 2;
const timeout_us: u64 = 300_000;
pub const Execution = enum { interrupt_echo, task_service, preemptive_tasks };

pub const Report = struct {
    messages: u32,
    registered_waits: u32,
    preposted_waits: u32,
    cpu0_interrupts: u32,
    cpu1_interrupts: u32,
    cpu1_parks: u32,
    stop_interrupts: u32,
    delivered: u32,
    rejected: u32,
    checksum: u32,
    task_payloads: u32,
    tasks: ?cpu1_tasks.Report = null,
};

var requests = Ring.init();
var responses = Ring.init();
var inbox: Inbox = .{};
var worker_inbox: Inbox = .{};
var execution: Execution = .interrupt_echo;
var to_cpu0: ?Doorbell = null;
var to_cpu1: ?Doorbell = null;
var handles: [2]calls.Handle = @splat(.{ .slot = 0, .generation = 0 });
var ready = std.atomic.Value(bool).init(false);
var active = std.atomic.Value(bool).init(false);
var stopping = std.atomic.Value(bool).init(false);
var done = std.atomic.Value(bool).init(true);
var failed = std.atomic.Value(bool).init(false);
var native_active = std.atomic.Value(bool).init(false);
var service_exit = std.atomic.Value(bool).init(false);
var worker_restored = std.atomic.Value(bool).init(false);
var published_sequence = std.atomic.Value(u32).init(0);
var waiting_sequence = std.atomic.Value(u32).init(0);
var registered_waits = std.atomic.Value(u32).init(0);
var checked_messages = std.atomic.Value(u32).init(0);
var checksum = std.atomic.Value(u32).init(0);
var stack_addresses: [2]std.atomic.Value(u32) = @splat(.init(0));
// CPU1 owns these until done's release store; CPU0 reports after joining.
var service_interrupt_id: u32 = 0;
var service_stack_min: u32 = 0;
var service_stack_max: u32 = 0;
var service_interrupts: u32 = 0;
var service_parks: u32 = 0;
var stop_interrupts: u32 = 0;
var processed: u32 = 0;
var service_started = false;
var pending_request: ?Message = null;
var task_payloads: u32 = 0;
var service_timer: ?timer_group.Timer = null;
var service_timer_interrupt_id: u32 = 0;
// CPU0's serialized trap tail owns this accounting.
var cpu0_interrupts: u32 = 0;
var drained: remote.DrainReport = .{};

extern fn nih_platform_monotonic_us() callconv(.c) u64;
extern fn nih_platform_cpu_id() callconv(.c) u32;
extern fn nih_platform_cpu_start(cpu: u32, entry: *const fn (?*anyopaque) callconv(.c) void, argument: ?*anyopaque) callconv(.c) i32;
extern fn nih_espidf_native_service_acquire(out: *Lease) callconv(.c) i32;
extern fn nih_espidf_native_service_release() callconv(.c) i32;
extern fn nih_espidf_native_service_timer_acquire(out: *TimerLease) callconv(.c) i32;
extern fn nih_espidf_native_service_timer_release() callconv(.c) i32;
extern fn nih_espidf_native_service_probe_yield() callconv(.c) void;
extern fn nih_espidf_native_service_verify_host() callconv(.c) i32;
extern fn nih_riscv_service_window() callconv(.c) u32;
extern fn nih_riscv_read_gp() callconv(.c) u32;
extern fn nih_riscv_read_tp() callconv(.c) u32;
extern fn nih_riscv_task_trampoline() callconv(.c) void;
extern fn esp_hw_stack_guard_get_bounds(core: u32, minimum: *u32, maximum: *u32) callconv(.c) void;

fn payload(sequence: u32) u32 {
    return (sequence *% 2_654_435_761) ^ 0x1357_9bdf;
}

fn abortTask(code: i32) noreturn {
    failed.store(true, .release);
    calls.exit(code);
}

fn post(handle: calls.Handle, bits: u32) bool {
    // IRQ work never spins on full. This fixture has one outstanding reply;
    // the four-slot inbox also accommodates its stale and final records.
    const result = inbox.post(.{ .slot = handle.slot, .generation = handle.generation, .bits = bits }, to_cpu0.?);
    if (result != .queued) {
        failed.store(true, .release);
        service_exit.store(true, .release);
        return false;
    }
    return true;
}

fn notifyWorker(stale: bool) bool {
    if (execution == .interrupt_echo) {
        to_cpu1.?.raise();
        return true;
    }
    // CPU0 is this endpoint's only producer. Mask its local handling across
    // publication so task-side and trap-tail submissions cannot reenter it.
    var interrupts = idle.InterruptWait{};
    const previous = interrupts.mask();
    defer interrupts.restore(previous);
    const target = cpu1_tasks.serviceHandle(); // Published by ready's release.
    const result = worker_inbox.post(.{
        .slot = target.slot,
        .generation = target.generation + @as(u16, @intFromBool(stale)),
        .bits = cpu1_tasks.request_bit,
    }, to_cpu1.?);
    if (result != .queued) failed.store(true, .release);
    return result == .queued;
}

fn processRequests() bool {
    if (!service_started) {
        service_started = true;
        if (!post(.{ .slot = handles[0].slot, .generation = handles[0].generation + 1 }, response_bit)) return false;
    }
    const budget: usize = if (execution != .interrupt_echo) 1 else 4;
    for (0..budget) |_| {
        const request = pending_request orelse requests.tryPop() orelse break;
        if (request.sequence & 1 != 0 and waiting_sequence.load(.acquire) != request.sequence + 1) {
            pending_request = request;
            break;
        }
        pending_request = null;
        if (execution != .interrupt_echo) {
            var marker: u32 = 0;
            const checked: *volatile u32 = &marker;
            checked.* = request.sequence;
            if (!cpu1_tasks.containsServiceAddress(@intFromPtr(&marker))) return false;
            task_payloads += 1;
        }
        if (request.sequence != processed or request.payload != payload(processed) or
            !responses.tryPush(.{ .sequence = request.sequence, .payload = request.payload ^ 0xa5a5_5a5a })) return false;
        if (!post(handles[0], response_bit)) return false;
        processed += 1;
        if (processed == messages and !post(handles[1], finished_bit)) return false;
    }
    if (pending_request == null and requests.countApprox() != 0) {
        if (execution != .interrupt_echo) {
            // Several records can share one doorbell. Retain local work when
            // this task's budget ends after remote metadata was consumed.
            if (calls.notify(cpu1_tasks.serviceHandle(), cpu1_tasks.request_bit) != calls.Status.ok) return false;
        } else to_cpu1.?.raise();
    }
    return true;
}

fn serviceWorker(_: ?*anyopaque) callconv(.c) void {
    defer done.store(true, .release);
    if (nih_platform_cpu_id() != 1) {
        failed.store(true, .release);
        return;
    }
    var lease = std.mem.zeroes(Lease);
    if (nih_espidf_native_service_acquire(&lease) != calls.Status.ok) {
        failed.store(true, .release);
        return;
    }
    to_cpu1 = Doorbell.fromRegister(lease.register_address);
    service_interrupt_id = lease.interrupt_id;
    esp_hw_stack_guard_get_bounds(1, &service_stack_min, &service_stack_max);
    if (to_cpu1 == null or lease.interrupt_id < 16 or lease.interrupt_id >= 48 or service_stack_min >= service_stack_max) {
        _ = nih_espidf_native_service_release();
        failed.store(true, .release);
        return;
    }
    var timer_leased = false;
    if (execution == .preemptive_tasks) {
        var timer_lease = std.mem.zeroes(TimerLease);
        if (nih_espidf_native_service_timer_acquire(&timer_lease) != calls.Status.ok) {
            _ = nih_espidf_native_service_release();
            failed.store(true, .release);
            return;
        }
        timer_leased = true;
        service_timer = timer_group.Timer.fromGroup(timer_lease.group_address, timer_lease.channel_id);
        service_timer_interrupt_id = timer_lease.interrupt_id;
        if (service_timer == null or timer_lease.interrupt_id < 16 or timer_lease.interrupt_id >= 48 or
            timer_lease.interrupt_id == service_interrupt_id)
        {
            _ = nih_espidf_native_service_timer_release();
            _ = nih_espidf_native_service_release();
            failed.store(true, .release);
            return;
        }
    }
    if (execution != .interrupt_echo and !cpu1_tasks.prepare(
        service_stack_min,
        service_stack_max,
        nih_riscv_read_gp(),
        nih_riscv_read_tp(),
        @intCast(@intFromPtr(&nih_riscv_task_trampoline)),
        .{ .work = &processRequests },
        service_timer,
    )) {
        if (service_timer) |timer| timer.stop();
        if (timer_leased) _ = nih_espidf_native_service_timer_release();
        _ = nih_espidf_native_service_release();
        failed.store(true, .release);
        return;
    }
    const returned = nih_riscv_service_window() == 1;
    native_active.store(false, .release);
    // Covers a prepare hook that declined entry before service_run could stop.
    if (service_timer) |timer| timer.stop();
    var minimum: u32 = 0;
    var maximum: u32 = 0;
    esp_hw_stack_guard_get_bounds(1, &minimum, &maximum);
    const timer_released = if (timer_leased) nih_espidf_native_service_timer_release() == calls.Status.ok else true;
    const released = nih_espidf_native_service_release() == calls.Status.ok;
    const tasks_finished = if (execution != .interrupt_echo) cpu1_tasks.finalize() else true;
    const restored = returned and timer_released and released and tasks_finished and minimum == service_stack_min and maximum == service_stack_max;
    worker_restored.store(restored, .release);
    if (!restored) failed.store(true, .release);
}

export fn nih_riscv_native_service_prepare() callconv(.c) u32 {
    const timer_ready = if (execution == .preemptive_tasks and !stopping.load(.acquire)) cpu1_tasks.startTimer() else true;
    if (!timer_ready) failed.store(true, .release);
    native_active.store(true, .release);
    ready.store(true, .release); // Publish the route only after mtvec changes.
    return if (stopping.load(.acquire) or !timer_ready) 0 else 1;
}

export fn nih_riscv_native_service_finish() callconv(.c) void {
    // Also runs if prepare started the counter and then declined entry.
    if (execution == .preemptive_tasks) cpu1_tasks.stopTimer();
}

export fn nih_riscv_native_service_run() callconv(.c) u32 {
    var interrupts = idle.InterruptWait{};
    const exit = if (execution != .interrupt_echo) cpu1_tasks.exitFlag() else &service_exit;
    while (!exit.load(.acquire)) {
        if (park.once(exit, &interrupts)) service_parks += 1;
    }
    if (execution == .preemptive_tasks) cpu1_tasks.stopTimer();
    return if (!failed.load(.acquire)) 1 else 0;
}

pub fn onServiceIpi(frame: *context.IntegerContext, state: context.ReturnState, reason: u12) ?context.TaskContext {
    if (!native_active.load(.acquire)) return null;
    if (execution == .preemptive_tasks and reason == service_timer_interrupt_id)
        return cpu1_tasks.onTimer(frame, state);
    if (reason != service_interrupt_id) return null;
    if (execution != .interrupt_echo) {
        // The registered runtime image supplies bounds for whichever native
        // task (or idle bootstrap) was interrupted, not just the IDF stack.
        to_cpu1.?.acknowledge();
        service_interrupts += 1;
        const stop_requested = stopping.load(.acquire);
        if (stop_requested) stop_interrupts += 1;
        return cpu1_tasks.onIpi(frame, state, &worker_inbox, to_cpu1.?, stop_requested);
    }
    const address = @intFromPtr(frame);
    if (address & 15 != 0 or address < service_stack_min or address > service_stack_max or
        context.integer_context_size > service_stack_max - address) return null;
    to_cpu1.?.acknowledge();
    service_interrupts += 1;
    if (stopping.load(.acquire)) {
        stop_interrupts += 1;
        service_exit.store(true, .release);
    } else if (active.load(.acquire)) {
        if (!processRequests()) return null;
    }
    return .{ .frame = frame, .state = state, .stack_min = service_stack_min, .stack_max = service_stack_max };
}

pub fn onServiceCall(frame: *context.IntegerContext, state: context.ReturnState) ?context.TaskContext {
    if (!native_active.load(.acquire) or execution == .interrupt_echo) return null;
    return cpu1_tasks.onCall(frame, state);
}

pub fn client(_: u32) callconv(.c) i32 {
    var canary: [4]u32 = @splat(0x6470_636c);
    const checked: *volatile [4]u32 = &canary;
    stack_addresses[0].store(@intCast(@intFromPtr(&canary)), .monotonic);
    var hash: u32 = 0;
    for (0..messages) |index| {
        const sequence: u32 = @intCast(index);
        if (!requests.tryPush(.{ .sequence = sequence, .payload = payload(sequence) })) abortTask(-160);
        published_sequence.store(sequence + 1, .release);
        if (sequence & 1 == 0) {
            if (!notifyWorker(false)) abortTask(-170);
            // Exercise a reply posted before WAIT, including while sleeping.
            if (calls.sleep(1) != calls.Status.ok) abortTask(-161);
        }
        switch (calls.waitEvents(response_bit)) {
            .received => |bits| if (bits != response_bit) abortTask(-162),
            .failed => abortTask(-163),
        }
        const response = responses.tryPop() orelse abortTask(-164);
        if (response.sequence != sequence or response.payload != payload(sequence) ^ 0xa5a5_5a5a) abortTask(-165);
        hash +%= response.payload;
        for (0..4) |slot| if (checked[slot] != 0x6470_636c) abortTask(-166);
    }
    checksum.store(hash, .monotonic);
    checked_messages.store(messages, .release);
    return 73;
}

pub fn observer(_: u32) callconv(.c) i32 {
    var canary: [4]u32 = @splat(0x6470_6f62);
    const checked: *volatile [4]u32 = &canary;
    stack_addresses[1].store(@intCast(@intFromPtr(&canary)), .monotonic);
    switch (calls.waitEvents(finished_bit)) {
        .received => |bits| if (bits != finished_bit) abortTask(-167),
        .failed => abortTask(-168),
    }
    for (0..4) |slot| if (checked[slot] != 0x6470_6f62) abortTask(-169);
    return 79;
}

pub fn prepare(client_handle: calls.Handle, observer_handle: calls.Handle, device: Doorbell, selected_execution: Execution) bool {
    if (!done.load(.acquire)) return false;
    requests = Ring.init();
    responses = Ring.init();
    inbox = .{};
    worker_inbox = .{};
    execution = selected_execution;
    to_cpu0 = device;
    to_cpu1 = null;
    handles = .{ client_handle, observer_handle };
    ready.store(false, .monotonic);
    active.store(false, .monotonic);
    stopping.store(false, .monotonic);
    done.store(false, .monotonic);
    failed.store(false, .monotonic);
    native_active.store(false, .monotonic);
    service_exit.store(false, .monotonic);
    worker_restored.store(false, .monotonic);
    published_sequence.store(0, .monotonic);
    waiting_sequence.store(0, .monotonic);
    registered_waits.store(0, .monotonic);
    checked_messages.store(0, .monotonic);
    checksum.store(0, .monotonic);
    for (&stack_addresses) |*address| address.store(0, .monotonic);
    service_interrupts = 0;
    service_parks = 0;
    stop_interrupts = 0;
    processed = 0;
    service_started = false;
    pending_request = null;
    task_payloads = 0;
    service_timer = null;
    service_timer_interrupt_id = 0;
    cpu0_interrupts = 0;
    drained = .{};
    if (nih_platform_cpu_start(1, &serviceWorker, null) != calls.Status.ok) {
        done.store(true, .release);
        return false;
    }
    const before = nih_platform_monotonic_us();
    while (!ready.load(.acquire)) {
        if (done.load(.acquire) or nih_platform_monotonic_us() - before >= timeout_us) return false;
        std.atomic.spinLoopHint();
    }
    return !failed.load(.acquire);
}

pub fn start() void {
    active.store(true, .release);
    nih_espidf_native_service_probe_yield();
    if (execution != .interrupt_echo) _ = notifyWorker(true);
    _ = notifyWorker(false);
}

pub fn recordBlocked(slot: u16, mask: u32) void {
    if (slot == handles[0].slot and mask == response_bit) {
        _ = registered_waits.fetchAdd(1, .monotonic);
        waiting_sequence.store(published_sequence.load(.acquire), .release);
        _ = notifyWorker(false);
    }
}

pub fn onIpi(policy: anytype) void {
    to_cpu0.?.acknowledge();
    const result = inbox.drain(policy, 4, to_cpu0.?);
    cpu0_interrupts += 1;
    drained.delivered += result.delivered;
    drained.rejected += result.rejected;
    drained.woken += result.woken;
}

pub fn stopAndJoin() bool {
    stopping.store(true, .release);
    const before = nih_platform_monotonic_us();
    var kicked = false;
    while (!done.load(.acquire)) {
        if (!kicked and ready.load(.acquire)) {
            to_cpu1.?.raise();
            kicked = true;
        }
        if (nih_platform_monotonic_us() - before >= timeout_us) return false;
        std.atomic.spinLoopHint();
    }
    return true;
}

pub fn verifyHostScheduler() bool {
    return nih_espidf_native_service_verify_host() == calls.Status.ok;
}

pub fn stackAddress(index: usize) u32 {
    return stack_addresses[index].load(.monotonic);
}

pub fn report() ?Report {
    const waits = registered_waits.load(.acquire);
    if (!done.load(.acquire) or !worker_restored.load(.acquire) or failed.load(.acquire) or
        processed != messages or checked_messages.load(.acquire) != messages or waits < messages / 2 or waits >= messages or
        service_parks == 0 or stop_interrupts == 0 or drained.delivered != messages + 1 or drained.rejected != 1 or
        requests.countApprox() != 0 or responses.countApprox() != 0 or inbox.ring.countApprox() != 0 or
        worker_inbox.ring.countApprox() != 0 or pending_request != null)
        return null;
    var expected: u32 = 0;
    for (0..messages) |index| expected +%= payload(@intCast(index)) ^ 0xa5a5_5a5a;
    if (checksum.load(.monotonic) != expected) return null;
    const tasks = if (execution != .interrupt_echo) cpu1_tasks.report() orelse return null else null;
    if (tasks) |value| if (task_payloads != messages or value.observer_rounds < messages or value.rejected != 1) return null;
    return .{
        .messages = messages,
        .registered_waits = waits,
        .preposted_waits = messages - waits,
        .cpu0_interrupts = cpu0_interrupts,
        .cpu1_interrupts = service_interrupts,
        .cpu1_parks = service_parks,
        .stop_interrupts = stop_interrupts,
        .delivered = drained.delivered,
        .rejected = drained.rejected,
        .checksum = expected,
        .task_payloads = task_payloads,
        .tasks = tasks,
    };
}
