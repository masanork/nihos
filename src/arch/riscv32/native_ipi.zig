//! Bounded native inbox/IPI/idle qualification, with periodic alarms disarmed.
//! A protocol task is each inbox's sole producer; the target IRQ is its sole
//! consumer. Bootstrap contexts park only while all local workers are blocked.
const std = @import("std");
const calls = @import("task_calls.zig");
const control = @import("task_control");
const events = @import("remote_events");
const ring = @import("spsc_ring");
const software_ipi = @import("software_ipi");
const park = @import("park");
const idle = @import("idle.zig");
const Inbox = events.Inbox(ring.SpscRing(events.Notification, 8));
const Atomic = std.atomic.Value(u32);
extern fn nih_native_task_failed() callconv(.c) noreturn;

pub const exchanges = 64;
var start = std.atomic.Value(bool).init(false);
var all_done = std.atomic.Value(bool).init(false);
var completed_mask = Atomic.init(0);
var handles: [2]Atomic = @splat(.init(0));
var inboxes: [2]Inbox = .{ .{}, .{} };
var sequence: [2]Atomic = @splat(.init(0));
var payload: [2]Atomic = @splat(.init(0));
var parked: [2]std.atomic.Value(bool) = @splat(.init(false));

const Counters = struct {
    sent: Atomic = .init(0),
    received: Atomic = .init(0),
    ipis: Atomic = .init(0),
    delivered: Atomic = .init(0),
    woken: Atomic = .init(0),
    rejected: Atomic = .init(0),
    from_idle: Atomic = .init(0),
    entries: Atomic = .init(0),
    returns: Atomic = .init(0),
    pending_before_wfi: Atomic = .init(0),
    timer_start: Atomic = .init(0),
    timer_end: Atomic = .init(0),
};
var counters: [2]Counters = .{ .{}, .{} };

pub const Report = struct {
    sent: u32,
    received: u32,
    ipis: u32,
    delivered: u32,
    woken: u32,
    rejected: u32,
    from_idle: u32,
    entries: u32,
    returns: u32,
    pending_before_wfi: u32,
    timer_start: u32,
    timer_end: u32,
    queued: u32,
    finished: bool,
};

pub fn request() void {
    start.store(true, .release);
}

pub fn requested() bool {
    return start.load(.acquire);
}

pub fn done() bool {
    return all_done.load(.acquire);
}

pub fn active(hart: u32) bool {
    return handles[hart].load(.acquire) != 0;
}

pub fn bell(hart: u32) software_ipi.Doorbell {
    // HP_SYSTEM_CPU_INT_FROM_CPU_0/1, one dedicated target per source.
    return software_ipi.Doorbell.fromRegister(0x500e5010 + hart * 4).?;
}

pub fn ownerStarted(hart: u32, handle: anytype, timer_interrupts: u32) void {
    counters[hart].timer_start.store(timer_interrupts, .release);
    counters[hart].timer_end.store(timer_interrupts, .release);
    handles[hart].store(control.encodeHandle(handle), .release);
}

pub fn ownerFinished(hart: u32, timer_interrupts: u32) void {
    counters[hart].timer_end.store(timer_interrupts, .release);
    // One RMW publication prevents both finishers from observing an old
    // peer flag and leaving the shared completion condition false forever.
    const bit = @as(u32, 1) << @intCast(hart);
    const previous = completed_mask.fetchOr(bit, .acq_rel);
    if (previous | bit == 3) all_done.store(true, .release);
    // Completion is a persistent atomic condition. An empty-inbox IPI also
    // releases a peer already parked after its protocol task has exited.
    bell(hart ^ 1).raise();
}

pub fn drain(hart: u32, policy: anytype, was_bootstrap: bool) void {
    var doorbell = bell(hart);
    doorbell.acknowledge(); // Before acquiring queue data, including empty IPIs.
    _ = counters[hart].ipis.fetchAdd(1, .release);
    if (was_bootstrap and parked[hart].load(.acquire))
        _ = counters[hart].from_idle.fetchAdd(1, .release);
    const drained = inboxes[hart].drain(policy, 4, &doorbell);
    _ = counters[hart].delivered.fetchAdd(drained.delivered, .release);
    _ = counters[hart].woken.fetchAdd(drained.woken, .release);
    _ = counters[hart].rejected.fetchAdd(drained.rejected, .release);
}

fn cycle() u32 {
    return asm volatile ("csrr %[result], mcycle"
        : [result] "=r" (-> u32),
    );
}

fn waitForIdle(peer: u32, previous: *u32) void {
    const begin = cycle();
    while (true) {
        const entries = counters[peer].entries.load(.acquire);
        if (entries > previous.* and parked[peer].load(.acquire) and handles[peer].load(.acquire) != 0) {
            previous.* = entries;
            return;
        }
        if (cycle() -% begin > 100_000_000) nih_native_task_failed();
        std.atomic.spinLoopHint();
    }
}

fn send(hart: u32, number: u32) void {
    const peer = hart ^ 1;
    const handle = control.decodeHandle(handles[peer].load(.acquire)) orelse nih_native_task_failed();
    payload[peer].store(0x6e69_0000 ^ number, .monotonic);
    sequence[peer].store(number, .release);
    var doorbell = bell(peer);
    if (inboxes[peer].post(.{ .slot = handle.slot, .generation = handle.generation, .bits = 1 }, &doorbell) != .queued)
        nih_native_task_failed();
    _ = counters[hart].sent.fetchAdd(1, .release);
}

fn receive(hart: u32, number: u32) void {
    const result = calls.waitEvents(1);
    switch (result) {
        .received => |bits| if (bits != 1) nih_native_task_failed(),
        .failed => nih_native_task_failed(),
    }
    if (sequence[hart].load(.acquire) != number or
        payload[hart].load(.monotonic) != 0x6e69_0000 ^ number)
        nih_native_task_failed();
    _ = counters[hart].received.fetchAdd(1, .release);
}

pub fn run(hart: u32) callconv(.c) i32 {
    var previous_idle: u32 = 0;
    for (1..exchanges + 1) |number| {
        if (hart == 0) {
            waitForIdle(1, &previous_idle);
            send(0, @intCast(number));
            receive(0, @intCast(number));
        } else {
            receive(1, @intCast(number));
            waitForIdle(0, &previous_idle);
            send(1, @intCast(number));
        }
    }
    return @intCast(200 + hart);
}

const Interrupts = struct {
    hart: u32,
    machine: idle.InterruptWait = .{},

    pub fn mask(self: *Interrupts) u32 {
        return self.machine.mask();
    }

    pub fn wait(self: *Interrupts) void {
        parked[self.hart].store(true, .release);
        const previous = counters[self.hart].entries.fetchAdd(1, .release);
        if (previous == 0) {
            // Force the check-to-WFI arrival case once per hart. Handling
            // stays masked; the peer posts after observing this publication.
            const begin = cycle();
            while (bell(self.hart).pending.* == 0) {
                if (cycle() -% begin > 100_000_000) nih_native_task_failed();
                std.atomic.spinLoopHint();
            }
            counters[self.hart].pending_before_wfi.store(1, .release);
        }
        self.machine.wait();
        _ = counters[self.hart].returns.fetchAdd(1, .release);
    }

    pub fn restore(self: *Interrupts, previous: u32) void {
        self.machine.restore(previous);
        parked[self.hart].store(false, .release);
    }
};

pub fn idleOnce(hart: u32) void {
    var interrupts = Interrupts{ .hart = hart };
    _ = park.once(&all_done, &interrupts);
}

pub fn report(hart: u32) Report {
    const source = &counters[hart];
    return .{
        .sent = source.sent.load(.acquire),
        .received = source.received.load(.acquire),
        .ipis = source.ipis.load(.acquire),
        .delivered = source.delivered.load(.acquire),
        .woken = source.woken.load(.acquire),
        .rejected = source.rejected.load(.acquire),
        .from_idle = source.from_idle.load(.acquire),
        .entries = source.entries.load(.acquire),
        .returns = source.returns.load(.acquire),
        .pending_before_wfi = source.pending_before_wfi.load(.acquire),
        .timer_start = source.timer_start.load(.acquire),
        .timer_end = source.timer_end.load(.acquire),
        .queued = @intCast(inboxes[hart].ring.countApprox()),
        .finished = completed_mask.load(.acquire) & (@as(u32, 1) << @intCast(hart)) != 0,
    };
}
