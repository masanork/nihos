//! CPU0 qualification transport. Bootstrap is the sole client dispatcher;
//! the font task is the sole library owner. Queues outlive both endpoints.
const protocol = @import("font_protocol");
const calls = @import("task_calls.zig");
const ring = @import("spsc_ring");
const channel = @import("spsc_channel");
extern fn nih_native_task_failed() callconv(.c) noreturn;
const Requests = channel.SpscChannel(ring.SpscRing(protocol.Request, 2), calls.EventPort);
const Replies = channel.SpscChannel(ring.SpscRing(protocol.Reply, 2), ReplyEvents);
const request_data = 0x100;
const request_space = 0x200;
const reply_data = 0x400;
const reply_space = 0x800;
const terminal_ack = 0x1000;

const ReplyEvents = struct {
    pub const Handle = calls.Handle;
    pub fn post(_: *ReplyEvents, target: Handle, bits: u32) i32 {
        if (bits == reply_space and metrics.sent == 5 and metrics.replies == 4) {
            // Force a task switch after the final reply slot is released but
            // before its space notification. Queue-empty alone cannot permit
            // worker EXIT: the client still needs a live notification target.
            if (calls.yieldNow() != 0) nih_native_task_failed();
            metrics.terminal_gap = 1;
        }
        return calls.notify(target, bits);
    }
    pub fn wait(_: *ReplyEvents, mask: u32) calls.EventResult {
        return calls.waitEvents(mask);
    }
};

pub const Report = struct {
    sent: u32 = 0,
    received: u32 = 0,
    replies: u32 = 0,
    waits: u32 = 0,
    blocked_ticks: u32 = 0,
    idle_runtime: u32 = 0,
    stop_ack: u32 = 0,
    terminal_gap: u32 = 0,
    queue_bytes: u32 = @sizeOf(Requests) + @sizeOf(Replies),
};
var metrics: Report = .{};
// SAFETY: bind initializes the queue before admitting its worker task.
var requests: Requests = undefined;
// SAFETY: bind initializes the queue before either endpoint can use it.
var replies: Replies = undefined;
var state: protocol.State = .{};
var bound = false;
var holding = false;
var hold_start: u64 = 0;
var hold_runtime: u64 = 0;
var expected: [16]u32 = @splat(0);

pub fn bind(client: calls.Handle, worker: calls.Handle) bool {
    if (bound) return false;
    requests = Requests.init(.{}, client, worker, request_data, request_space) orelse return false;
    replies = Replies.init(.{}, worker, client, reply_data, reply_space) orelse return false;
    bound = true;
    return true;
}

fn sendReply(reply: protocol.Reply) void {
    switch (replies.send(reply)) {
        .sent => {},
        else => nih_native_task_failed(),
    }
}

/// Font task only: publish a complete copied result, then block on requests.
pub fn next(completed: u32, retained: u32, hashes: [16]u32, runs: u32) u32 {
    if (!bound) nih_native_task_failed();
    if (completed != 0) {
        state.complete(completed) catch nih_native_task_failed();
        if (runs != 16) nih_native_task_failed();
        sendReply(.{ .id = completed, .operation = .render_matrix, .hashes = hashes, .runs = runs, .retained = retained });
    }
    const received = switch (requests.receive()) {
        .item => |item| item,
        else => nih_native_task_failed(),
    };
    if (received.space_notification != 0) nih_native_task_failed();
    state.accept(received.value) catch nih_native_task_failed();
    metrics.received += 1;
    if (received.value.operation == .render_matrix) return received.value.id;
    sendReply(.{ .id = received.value.id, .operation = .stop, .retained = retained });
    // A distinct, never-reused terminal bit acknowledges both the copy and
    // the channel's space notification. Queue-empty precedes that notification
    // and is insufficient to authorize destruction of the worker endpoint.
    switch (calls.waitEvents(terminal_ack)) {
        .received => |bits| if (bits != terminal_ack) nih_native_task_failed(),
        .failed => nih_native_task_failed(),
    }
    if (replies.ring.countApprox() != 0) nih_native_task_failed();
    metrics.stop_ack = 1;
    return 0;
}

/// Bootstrap only. Leave the worker waiting for two real ticks before each
/// request. Timer time must advance without charging the blocked font task.
pub fn poll(ticks: u64, runtime: u64, waiting: bool) void {
    while (true) {
        const reply = switch (replies.tryReceive()) {
            .item => |item| blk: {
                if (item.space_notification != 0) nih_native_task_failed();
                break :blk item.value;
            },
            .empty => break,
            else => nih_native_task_failed(),
        };
        if (reply.id != metrics.replies + 1 or reply.id > metrics.sent or reply.retained != 65792) nih_native_task_failed();
        if (reply.id <= 4) {
            if (reply.operation != .render_matrix or reply.runs != 16) nih_native_task_failed();
            if (reply.id == 1) expected = reply.hashes else {
                for (reply.hashes, expected) |actual, reference| if (actual != reference) nih_native_task_failed();
            }
        } else if (reply.id != 5 or reply.operation != .stop or reply.runs != 0) nih_native_task_failed();
        metrics.replies += 1;
        if (reply.operation == .stop and calls.notify(replies.producer, terminal_ack) != 0) nih_native_task_failed();
    }
    if (metrics.sent == 5 or !waiting) return;
    if (!holding) {
        holding = true;
        hold_start = ticks;
        hold_runtime = runtime;
        metrics.waits += 1;
    }
    if (runtime != hold_runtime) nih_native_task_failed();
    if (ticks - hold_start < 2) return;
    metrics.blocked_ticks += @intCast(ticks - hold_start);
    holding = false;
    metrics.sent += 1;
    const request = protocol.Request{ .id = metrics.sent, .operation = if (metrics.sent <= 4) .render_matrix else .stop };
    switch (requests.trySend(request)) {
        .sent => {},
        else => nih_native_task_failed(),
    }
}

pub fn report() Report {
    return metrics;
}

pub fn finished() bool {
    return bound and state.stopped and state.active == null and metrics.sent == 5 and metrics.received == 5 and
        metrics.replies == 5 and metrics.waits == 5 and metrics.blocked_ticks >= 10 and metrics.stop_ack == 1 and metrics.terminal_gap == 1 and
        requests.ring.countApprox() == 0 and replies.ring.countApprox() == 0;
}
