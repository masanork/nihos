//! Two native tasks exchange bounded request/completion messages. Payload
//! progress uses channel waits; a timed service start forces backpressure.
const std = @import("std");
const calls = @import("task_calls.zig");
const Ring = @import("spsc_ring").SpscRing(Message, 3);
const Channel = @import("spsc_channel").SpscChannel(Ring, calls.EventPort);

const Message = struct { sequence: u32, payload: u32 };
const messages: u32 = 64;
const window: u32 = 4;
const request_readable: u32 = 1;
const request_writable: u32 = 2;
const response_readable: u32 = 4;
const response_writable: u32 = 8;
const completion_ack: u32 = 16;

pub const Report = struct {
    messages: u32,
    full_rejections: u32,
    readable_waits: u32,
    writable_waits: u32,
    checksum: u32,
    counters_wrapped: bool,
};

// SAFETY: prepare initializes the queue and endpoints before either task runs.
var requests: Channel = undefined;
// SAFETY: prepare initializes the queue and endpoints before either task runs.
var responses: Channel = undefined;
var checked_messages = std.atomic.Value(u32).init(0);
var full_rejections = std.atomic.Value(u32).init(0);
var checksum = std.atomic.Value(u32).init(0);
var stack_addresses: [2]std.atomic.Value(u32) = @splat(.init(0));
var failed = std.atomic.Value(bool).init(false);
// Written only by the serialized kernel hook; read after the native window.
var readable_waits: u32 = 0;
var writable_waits: u32 = 0;

fn payload(sequence: u32) u32 {
    return sequence *% 2_654_435_761;
}

fn fail(code: i32) noreturn {
    failed.store(true, .monotonic);
    calls.exit(code);
}

fn send(channel: *Channel, item: Message) void {
    switch (channel.send(item)) {
        .sent => {},
        else => fail(-140),
    }
}

fn receive(channel: *Channel) Message {
    return switch (channel.receive()) {
        .item => |item| if (item.space_notification == calls.Status.ok) item.value else fail(-141),
        else => fail(-142),
    };
}

fn checkCanary(canary: *volatile [4]u32, expected: u32) void {
    for (0..4) |index| if (canary[index] != expected) fail(-143);
}

pub fn client(_: u32) callconv(.c) i32 {
    var canary: [4]u32 = @splat(0x6970_636c);
    const checked: *volatile [4]u32 = &canary;
    stack_addresses[0].store(@intCast(@intFromPtr(&canary)), .monotonic);
    for (0..3) |index| {
        const sequence: u32 = @intCast(index);
        switch (requests.trySend(.{ .sequence = sequence, .payload = payload(sequence) })) {
            .sent => {},
            else => fail(-144),
        }
    }
    switch (requests.trySend(.{ .sequence = 3, .payload = payload(3) })) {
        .full => full_rejections.store(1, .monotonic),
        else => fail(-145),
    }
    send(&requests, .{ .sequence = 3, .payload = payload(3) });
    var hash: u32 = 0;
    for (0..messages) |index| {
        const sequence: u32 = @intCast(index);
        const response = receive(&responses);
        const expected = payload(sequence) ^ 0xa5a5_5a5a;
        if (response.sequence != sequence or response.payload != expected) fail(-146);
        hash +%= response.payload;
        if (sequence + window < messages) {
            const next = sequence + window;
            send(&requests, .{ .sequence = next, .payload = payload(next) });
        }
        checkCanary(checked, 0x6970_636c);
    }
    checksum.store(hash, .monotonic);
    checked_messages.store(messages, .monotonic);
    // The final pop must still be able to notify a live response producer.
    // Release its endpoint only after every value and space notice passed.
    if (calls.notify(responses.producer, completion_ack) != calls.Status.ok) fail(-149);
    return 53;
}

pub fn service(_: u32) callconv(.c) i32 {
    var canary: [4]u32 = @splat(0x6970_7376);
    const checked: *volatile [4]u32 = &canary;
    stack_addresses[1].store(@intCast(@intFromPtr(&canary)), .monotonic);
    // Keep requests queued long enough to exercise both the nonblocking full
    // result and a sender waiting for released space through a real ECALL.
    if (calls.sleep(2) != calls.Status.ok) fail(-147);
    for (0..messages) |index| {
        const request = receive(&requests);
        if (request.sequence != index or request.payload != payload(@intCast(index))) fail(-148);
        send(&responses, .{
            .sequence = request.sequence,
            .payload = request.payload ^ 0xa5a5_5a5a,
        });
        checkCanary(checked, 0x6970_7376);
    }
    switch (calls.waitEvents(completion_ack)) {
        .received => |bits| if (bits != completion_ack) fail(-150),
        .failed => fail(-151),
    }
    checkCanary(checked, 0x6970_7376);
    return 59;
}

pub fn prepare(client_handle: calls.Handle, service_handle: calls.Handle) void {
    requests = Channel.init(.{}, client_handle, service_handle, request_readable, request_writable).?;
    responses = Channel.init(.{}, service_handle, client_handle, response_readable, response_writable).?;
    // Force real RV32 counter wrap during this short run. The queues are
    // empty, so both owner-private slot positions legitimately remain zero.
    const near_wrap = std.math.maxInt(usize) - 1;
    for ([_]*Channel{ &requests, &responses }) |channel| {
        channel.ring.write.published.store(near_wrap, .monotonic);
        channel.ring.read.published.store(near_wrap, .monotonic);
    }
    checked_messages.store(0, .monotonic);
    full_rejections.store(0, .monotonic);
    checksum.store(0, .monotonic);
    failed.store(false, .monotonic);
    for (&stack_addresses) |*address| address.store(0, .monotonic);
    readable_waits = 0;
    writable_waits = 0;
}

pub fn recordBlocked(mask: u32) void {
    if (mask == request_readable or mask == response_readable) readable_waits += 1;
    if (mask == request_writable or mask == response_writable) writable_waits += 1;
}

pub fn stackAddress(index: usize) u32 {
    return stack_addresses[index].load(.monotonic);
}

pub fn report() ?Report {
    if (failed.load(.monotonic) or checked_messages.load(.monotonic) != messages or
        full_rejections.load(.monotonic) != 1 or readable_waits == 0 or writable_waits == 0)
        return null;
    var expected: u32 = 0;
    for (0..messages) |index| expected +%= payload(@intCast(index)) ^ 0xa5a5_5a5a;
    if (checksum.load(.monotonic) != expected) return null;
    for ([_]*Channel{ &requests, &responses }) |channel| {
        if (channel.ring.countApprox() != 0 or
            channel.ring.write.published.load(.monotonic) != messages - 2 or
            channel.ring.read.published.load(.monotonic) != messages - 2) return null;
    }
    return .{
        .messages = messages,
        .full_rejections = full_rejections.load(.monotonic),
        .readable_waits = readable_waits,
        .writable_waits = writable_waits,
        .checksum = expected,
        .counters_wrapped = true,
    };
}
