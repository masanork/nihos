//! Both cores own bounded native windows. CPU0 schedules tasks; CPU1 is one
//! integer echo service whose foreground parks and whose IPI tail is bounded.
const std = @import("std");
const context = @import("context.zig");
const calls = @import("task_calls.zig");
const idle = @import("idle.zig");
const park = @import("park");
const rings = @import("spsc_ring");
const remote = @import("remote_events");
const Doorbell = @import("software_ipi").Doorbell;
const Inbox = remote.Inbox(rings.SpscRing(remote.Notification, 4));
const Message = struct { sequence: u32, payload: u32 };
const Ring = rings.SpscRing(Message, 3);
const Lease = extern struct { register_address: u32, interrupt_id: u32 };
const messages: u32 = 64;
const response_bit: u32 = 1;
const finished_bit: u32 = 2;
const timeout_us: u64 = 300_000;

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
};

var requests = Ring.init();
var responses = Ring.init();
var inbox: Inbox = .{};
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
// CPU0's serialized trap tail owns this accounting.
var cpu0_interrupts: u32 = 0;
var drained: remote.DrainReport = .{};

extern fn nih_platform_monotonic_us() callconv(.c) u64;
extern fn nih_platform_cpu_id() callconv(.c) u32;
extern fn nih_platform_cpu_start(cpu: u32, entry: *const fn (?*anyopaque) callconv(.c) void, argument: ?*anyopaque) callconv(.c) i32;
extern fn nih_espidf_native_service_acquire(out: *Lease) callconv(.c) i32;
extern fn nih_espidf_native_service_release() callconv(.c) i32;
extern fn nih_espidf_native_service_probe_yield() callconv(.c) void;
extern fn nih_espidf_native_service_verify_host() callconv(.c) i32;
extern fn nih_riscv_service_window() callconv(.c) u32;
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
    const returned = nih_riscv_service_window() == 1;
    native_active.store(false, .release);
    var minimum: u32 = 0;
    var maximum: u32 = 0;
    esp_hw_stack_guard_get_bounds(1, &minimum, &maximum);
    const released = nih_espidf_native_service_release() == calls.Status.ok;
    const restored = returned and released and minimum == service_stack_min and maximum == service_stack_max;
    worker_restored.store(restored, .release);
    if (!restored) failed.store(true, .release);
}

export fn nih_riscv_native_service_prepare() callconv(.c) u32 {
    native_active.store(true, .release);
    ready.store(true, .release); // Publish the route only after mtvec changes.
    return if (stopping.load(.acquire)) 0 else 1;
}

export fn nih_riscv_native_service_run() callconv(.c) u32 {
    var interrupts = idle.InterruptWait{};
    while (!service_exit.load(.acquire)) {
        if (park.once(&service_exit, &interrupts)) service_parks += 1;
    }
    return if (!failed.load(.acquire)) 1 else 0;
}

pub fn onServiceIpi(frame: *context.IntegerContext, state: context.ReturnState, reason: u12) ?context.TaskContext {
    if (!native_active.load(.acquire) or reason != service_interrupt_id) return null;
    const address = @intFromPtr(frame);
    if (address & 15 != 0 or address < service_stack_min or address > service_stack_max or
        context.integer_context_size > service_stack_max - address) return null;
    to_cpu1.?.acknowledge();
    service_interrupts += 1;
    if (stopping.load(.acquire)) {
        stop_interrupts += 1;
        service_exit.store(true, .release);
    } else if (active.load(.acquire)) {
        if (!service_started) {
            service_started = true;
            if (!post(.{ .slot = handles[0].slot, .generation = handles[0].generation + 1 }, response_bit)) return null;
        }
        for (0..4) |_| {
            const request = pending_request orelse requests.tryPop() orelse break;
            // Hold odd requests until CPU0 registers its wait. A later IPI
            // from that registration advances this test gate without polling.
            if (request.sequence & 1 != 0 and waiting_sequence.load(.acquire) != request.sequence + 1) {
                pending_request = request;
                break;
            }
            pending_request = null;
            if (request.sequence != processed or request.payload != payload(processed) or
                !responses.tryPush(.{ .sequence = request.sequence, .payload = request.payload ^ 0xa5a5_5a5a })) return null;
            if (!post(handles[0], response_bit)) return null;
            processed += 1;
            if (processed == messages and !post(handles[1], finished_bit)) return null;
        }
        if (pending_request == null and requests.countApprox() != 0) to_cpu1.?.raise();
    }
    return .{ .frame = frame, .state = state, .stack_min = service_stack_min, .stack_max = service_stack_max };
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
            to_cpu1.?.raise();
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

pub fn prepare(client_handle: calls.Handle, observer_handle: calls.Handle, device: Doorbell) bool {
    if (!done.load(.acquire)) return false;
    requests = Ring.init();
    responses = Ring.init();
    inbox = .{};
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
    to_cpu1.?.raise();
}

pub fn recordBlocked(slot: u16, mask: u32) void {
    if (slot == handles[0].slot and mask == response_bit) {
        _ = registered_waits.fetchAdd(1, .monotonic);
        waiting_sequence.store(published_sequence.load(.acquire), .release);
        to_cpu1.?.raise();
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
        requests.countApprox() != 0 or responses.countApprox() != 0 or inbox.ring.countApprox() != 0 or pending_request != null)
        return null;
    var expected: u32 = 0;
    for (0..messages) |index| expected +%= payload(@intCast(index)) ^ 0xa5a5_5a5a;
    if (checksum.load(.monotonic) != expected) return null;
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
    };
}
