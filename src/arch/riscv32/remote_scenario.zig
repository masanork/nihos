//! CPU1 remains an IDF task. It publishes replies and owner notifications;
//! only CPU0's native IPI tail touches the scheduler or saved task frames.
const std = @import("std");
const calls = @import("task_calls.zig");
const rings = @import("spsc_ring");
const remote = @import("remote_events");
const Doorbell = @import("software_ipi").Doorbell;
const Inbox = remote.Inbox(rings.SpscRing(remote.Notification, 4));
const Ring = rings.SpscRing(Message, 3);
const Message = struct { sequence: u32, payload: u32 };
const messages: u32 = 64;
const response_bit: u32 = 1;
const finished_bit: u32 = 2;
const timeout_us: u64 = 300_000;

pub const Report = struct {
    messages: u32,
    worker_cpu: u32,
    registered_waits: u32,
    ipi_interrupts: u32,
    delivered: u32,
    rejected: u32,
    woken: u32,
    checksum: u32,
};

var inbox: Inbox = .{};
var requests = Ring.init();
var responses = Ring.init();
var doorbell: ?Doorbell = null;
var handles: [2]calls.Handle = @splat(.{ .slot = 0, .generation = 0 });
var active = std.atomic.Value(bool).init(false);
var stop = std.atomic.Value(bool).init(false);
var done = std.atomic.Value(bool).init(true);
var failed = std.atomic.Value(bool).init(false);
var worker_cpu = std.atomic.Value(u32).init(0);
var registered_waits = std.atomic.Value(u32).init(0);
var checked_messages = std.atomic.Value(u32).init(0);
var checksum = std.atomic.Value(u32).init(0);
var stack_addresses: [2]std.atomic.Value(u32) = @splat(.init(0));
var started_us: u64 = 0;
var ipi_interrupts: u32 = 0;
var drained: remote.DrainReport = .{};
var host_task_cpu = std.atomic.Value(u32).init(std.math.maxInt(u32));

extern fn nih_platform_monotonic_us() callconv(.c) u64;
extern fn nih_platform_cpu_id() callconv(.c) u32;
extern fn nih_platform_cpu_start(cpu_id: u32, entry: *const fn (?*anyopaque) callconv(.c) void, argument: ?*anyopaque) callconv(.c) i32;
extern fn nih_espidf_native_ipi_probe_host_yield() callconv(.c) void;

fn expired() bool {
    return nih_platform_monotonic_us() - started_us >= timeout_us;
}

fn abortTask(code: i32) noreturn {
    failed.store(true, .release);
    calls.exit(code);
}

fn payload(sequence: u32) u32 {
    return (sequence *% 2_654_435_761) ^ 0x5a5a_a5a5;
}

fn post(handle: calls.Handle, bits: u32) bool {
    const notification = remote.Notification{ .slot = handle.slot, .generation = handle.generation, .bits = bits };
    while (!stop.load(.acquire) and !expired()) {
        switch (inbox.post(notification, doorbell.?)) {
            .queued => return true,
            .invalid => return false,
            .full => std.atomic.spinLoopHint(),
        }
    }
    return false;
}

fn worker(_: ?*anyopaque) callconv(.c) void {
    defer done.store(true, .release);
    worker_cpu.store(nih_platform_cpu_id(), .release);
    while (!active.load(.acquire)) {
        if (stop.load(.acquire) or expired()) return;
        std.atomic.spinLoopHint();
    }
    // A real IDF request must survive native acknowledgement of the shared
    // hardware level. Its reason is consumed only after vector restoration.
    nih_espidf_native_ipi_probe_host_yield();
    if (!post(.{ .slot = handles[0].slot, .generation = handles[0].generation + 1 }, response_bit)) {
        failed.store(true, .release);
        return;
    }
    for (0..messages) |index| {
        const request = while (true) {
            if (stop.load(.acquire) or expired()) return;
            if (requests.tryPop()) |item| break item;
            std.atomic.spinLoopHint();
        };
        if (request.sequence != index or request.payload != payload(@intCast(index))) {
            failed.store(true, .release);
            return;
        }
        // This test gate proves each response wakes a registered native
        // waiter; timer polling cannot consume or deliver the notification.
        while (registered_waits.load(.acquire) <= index) {
            if (stop.load(.acquire) or expired()) return;
            std.atomic.spinLoopHint();
        }
        if (!responses.tryPush(.{ .sequence = request.sequence, .payload = request.payload ^ 0xa5a5_5a5a }) or
            !post(handles[0], response_bit))
        {
            failed.store(true, .release);
            return;
        }
    }
    if (!post(handles[1], finished_bit)) failed.store(true, .release);
}

pub fn client(_: u32) callconv(.c) i32 {
    var canary: [4]u32 = @splat(0x726d_636c);
    const checked: *volatile [4]u32 = &canary;
    stack_addresses[0].store(@intCast(@intFromPtr(&canary)), .monotonic);
    var hash: u32 = 0;
    for (0..messages) |index| {
        const sequence: u32 = @intCast(index);
        if (!requests.tryPush(.{ .sequence = sequence, .payload = payload(sequence) })) abortTask(-150);
        switch (calls.waitEvents(response_bit)) {
            .received => |bits| if (bits != response_bit) abortTask(-151),
            .failed => abortTask(-152),
        }
        const response = responses.tryPop() orelse abortTask(-153);
        if (response.sequence != sequence or response.payload != payload(sequence) ^ 0xa5a5_5a5a) abortTask(-154);
        hash +%= response.payload;
        for (0..4) |slot| if (checked[slot] != 0x726d_636c) abortTask(-155);
    }
    checksum.store(hash, .monotonic);
    checked_messages.store(messages, .release);
    return 67;
}

pub fn observer(_: u32) callconv(.c) i32 {
    var canary: [4]u32 = @splat(0x726d_6f62);
    const checked: *volatile [4]u32 = &canary;
    stack_addresses[1].store(@intCast(@intFromPtr(&canary)), .monotonic);
    switch (calls.waitEvents(finished_bit)) {
        .received => |bits| if (bits != finished_bit) abortTask(-156),
        .failed => abortTask(-157),
    }
    for (0..4) |slot| if (checked[slot] != 0x726d_6f62) abortTask(-158);
    return 71;
}

pub fn prepare(client_handle: calls.Handle, observer_handle: calls.Handle, device: Doorbell) bool {
    if (!done.load(.acquire)) return false;
    inbox = .{};
    requests = Ring.init();
    responses = Ring.init();
    doorbell = device;
    handles = .{ client_handle, observer_handle };
    active.store(false, .monotonic);
    stop.store(false, .monotonic);
    done.store(false, .monotonic);
    failed.store(false, .monotonic);
    worker_cpu.store(0, .monotonic);
    registered_waits.store(0, .monotonic);
    checked_messages.store(0, .monotonic);
    checksum.store(0, .monotonic);
    for (&stack_addresses) |*address| address.store(0, .monotonic);
    ipi_interrupts = 0;
    drained = .{};
    started_us = nih_platform_monotonic_us();
    if (nih_platform_cpu_start(1, &worker, null) != calls.Status.ok) {
        done.store(true, .release);
        return false;
    }
    return true;
}

pub fn start() void {
    active.store(true, .release);
}

pub fn recordBlocked(slot: u16, mask: u32) void {
    if (slot == handles[0].slot and mask == response_bit) _ = registered_waits.fetchAdd(1, .release);
}

pub fn onIpi(policy: anytype) void {
    doorbell.?.acknowledge();
    const result = inbox.drain(policy, 4, doorbell.?);
    ipi_interrupts += 1;
    drained.delivered += result.delivered;
    drained.rejected += result.rejected;
    drained.woken += result.woken;
}

pub fn stopAndJoin() bool {
    stop.store(true, .release);
    const before = nih_platform_monotonic_us();
    while (!done.load(.acquire)) {
        if (nih_platform_monotonic_us() - before >= timeout_us) return false;
        std.atomic.spinLoopHint();
    }
    return true;
}

pub fn stackAddress(index: usize) u32 {
    return stack_addresses[index].load(.monotonic);
}

fn hostTask(_: ?*anyopaque) callconv(.c) void {
    host_task_cpu.store(nih_platform_cpu_id(), .release);
}

/// Run only after IDF's vector/interrupt state and source ownership return.
pub fn verifyHostScheduler() bool {
    host_task_cpu.store(std.math.maxInt(u32), .monotonic);
    if (nih_platform_cpu_start(0, &hostTask, null) != calls.Status.ok) return false;
    const before = nih_platform_monotonic_us();
    while (host_task_cpu.load(.acquire) == std.math.maxInt(u32)) {
        if (nih_platform_monotonic_us() - before >= timeout_us) return false;
        std.atomic.spinLoopHint();
    }
    return host_task_cpu.load(.acquire) == 0;
}

pub fn report() ?Report {
    if (!done.load(.acquire) or failed.load(.acquire) or worker_cpu.load(.acquire) != 1 or
        checked_messages.load(.acquire) != messages or registered_waits.load(.acquire) != messages or
        drained.delivered != messages + 1 or drained.rejected != 1 or drained.woken < messages or
        ipi_interrupts == 0 or inbox.ring.countApprox() != 0 or requests.countApprox() != 0 or responses.countApprox() != 0)
        return null;
    var expected: u32 = 0;
    for (0..messages) |index| expected +%= payload(@intCast(index)) ^ 0xa5a5_5a5a;
    if (checksum.load(.monotonic) != expected) return null;
    return .{
        .messages = messages,
        .worker_cpu = 1,
        .registered_waits = registered_waits.load(.acquire),
        .ipi_interrupts = ipi_interrupts,
        .delivered = drained.delivered,
        .rejected = drained.rejected,
        .woken = drained.woken,
        .checksum = expected,
    };
}
