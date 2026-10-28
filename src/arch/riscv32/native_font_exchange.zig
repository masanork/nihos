//! CPU0 qualification transport. Bootstrap is the sole client dispatcher;
//! the font task is the sole library owner. Queues outlive both endpoints.
const std = @import("std");
const options = @import("native_options");
pub const composer = @import("native_surface.zig");
pub const raster = @import("native_raster.zig");
const lease = @import("raster_lease");
const protocol = @import("text_context").protocol;
const calls = @import("task_calls.zig");
const ring = @import("spsc_ring");
const channel = @import("spsc_channel");
extern fn nih_native_task_failed() callconv(.c) noreturn;
const Requests = channel.SpscChannel(ring.SpscRing(protocol.Request, 2), RequestEvents);
const Replies = channel.SpscChannel(ring.SpscRing(protocol.Reply, 2), ReplyEvents);
const request_data = 0x100;
const request_space = 0x200;
const reply_data = 0x400;
const reply_space = 0x800;
const terminal_ack = 0x1000;

const RequestEvents = struct {
    pub const Handle = calls.Handle;
    pub fn post(_: *RequestEvents, target: Handle, bits: u32) i32 {
        if (bits == request_data and submitted.operation == .render_text) {
            // The ring has published its own copy; poison caller storage
            // before waking the worker, so borrowing it cannot pass the test.
            @memset(&submitted.render.body, 0xff);
            @memset(&submitted.render.ruby, 0xff);
            submitted.render.pixels = 0;
            metrics.copied_inputs += 1;
        }
        return calls.notify(target, bits);
    }
    pub fn wait(_: *RequestEvents, mask: u32) calls.EventResult {
        return calls.waitEvents(mask);
    }
};

const ReplyEvents = struct {
    pub const Handle = calls.Handle;
    pub fn post(_: *ReplyEvents, target: Handle, bits: u32) i32 {
        if (bits == reply_space and metrics.sent == 10 and metrics.replies == 9) {
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
    copied_inputs: u32 = 0,
    text_success: u32 = 0,
    text_failed: u32 = 0,
    copied_outputs: u32 = 0,
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
var submitted: protocol.Request = .{ .id = 0, .operation = .stop };
var held: lease.Lease = .{};
var last_lease: lease.Lease = .{};
var held_id: u32 = 0;
var held_since: u64 = 0;
var pending_release: u32 = 0;
var release_id: u32 = 0;
fn digest(bytes: []const u8) u32 {
    var value: u32 = 2166136261;
    for (bytes) |byte| value = (value ^ byte) *% 16777619;
    return value;
}
noinline fn drawHash(reply: *const protocol.Reply, pixels: []const u8) linksection(".flash.text.render") u32 {
    var value: u32 = 2166136261;
    for (reply.output.glyphs[0..reply.output.count]) |g| {
        for ([_]u32{ g.id, @bitCast(g.x_advance), @bitCast(g.y_advance) }) |word| value = (value ^ word) *% 16777619;
        const end = g.pixel_offset + g.width * g.height;
        if (end > pixels.len) nih_native_task_failed();
        for (pixels[g.pixel_offset..end]) |byte| value = (value ^ byte) *% 16777619;
    }
    return value;
}
var active_source_hash: u32 = 0;
var active_operation: protocol.Operation = .render_matrix;
const Snapshot = struct {
    id: u32 = 0,
    runs: u32 = 0,
    hashes: [1]u32 = .{0},
    outcome: protocol.Outcome = .render_failed,
    pixel_hash: u32 = 0,
    source_hash: u32 = 0,
    composition: composer.Result = .{},
    output: struct { count: u32 = 0, raster_bytes: u32 = 0, glyphs: []const protocol.Glyph = &.{} } = .{},
};
// Qualification archives only successful glyphs; failed packets are validated
// before discarding their empty storage. Nothing here crosses the IPC queue.
const Archive = struct { glyphs: [3][16]protocol.Glyph, texts: [5]Snapshot, source: composer.Context, source_ready: bool };
var archive: ?*Archive = null;
var archive_allocation: ?@import("native_memory").reusable.Allocation = null;
pub const ArchiveReport = struct { logical_bytes: u32 = @sizeOf(Archive), charge: u32 = 0, live_charge: u32 = 0, before: u32 = 0, after: u32 = 0 };
pub var archive_metrics: ArchiveReport = .{};
pub fn prepareArchive() bool {
    const heap = @import("native_memory").reusable;
    if (archive_allocation != null) return false;
    archive_metrics.before = @intCast(heap.availableBytes() orelse return false);
    archive_allocation = heap.allocTask(@sizeOf(Archive), 16) catch return false;
    archive = @ptrCast(@alignCast(archive_allocation.?.bytes.ptr));
    archive.?.source_ready = false;
    // SAFETY: poll fills snapshots in request order; textResults exposes only
    // the initialized prefix, including after worker retirement.
    archive_metrics.charge = archive_metrics.before - @as(u32, @intCast(heap.availableBytes() orelse return false));
    archive_metrics.live_charge = archive_metrics.charge;
    return true;
}
pub fn releaseArchive() bool {
    const heap = @import("native_memory").reusable;
    const allocation = archive_allocation orelse return false;
    heap.freeTask(allocation) catch return false;
    archive_allocation = null;
    archive = null;
    archive_metrics.live_charge = 0;
    archive_metrics.after = @intCast(heap.availableBytes() orelse return false);
    return archive_metrics.before == archive_metrics.after;
}
pub fn textResults() []const Snapshot {
    return if (archive) |storage| storage.texts[0 .. metrics.text_success + metrics.text_failed] else &.{};
}

pub fn bind(client: calls.Handle, worker: calls.Handle) bool {
    if (bound) return false;
    requests = Requests.init(.{}, client, worker, request_data, request_space) orelse return false;
    replies = Replies.init(.{}, worker, client, reply_data, reply_space) orelse return false;
    raster.bind((@as(u32, worker.slot) << 16) | worker.generation, (@as(u32, client.slot) << 16) | client.generation);
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
pub noinline fn next(completed: u32, retained: u32, hashes: [16]u32, runs: u32, job: *protocol.Job, output: *protocol.Output) u32 {
    if (!bound) nih_native_task_failed();
    if (completed != 0) {
        state.complete(completed) catch nih_native_task_failed();
        if ((active_operation == .render_matrix and runs != 16) or
            (active_operation == .render_text and (runs > 1 or (runs == 0 and hashes[0] != 0)))) nih_native_task_failed();
        var reply = protocol.Reply{ .id = completed, .operation = active_operation, .hashes = hashes, .runs = runs, .retained = retained };
        if (active_operation == .render_text) {
            reply.hashes[1] = active_source_hash;
            output.validate() catch nih_native_task_failed();
            reply.output = output.*;
            reply.outcome = switch (output.outcome) {
                0 => .ok,
                1 => .render_failed,
                2 => .output_full,
                3 => .raster_unavailable,
                else => nih_native_task_failed(),
            };
            if ((runs == 1) != (reply.outcome == .ok)) nih_native_task_failed();
            if (runs == 1 and output.raster_bytes != 0) {
                const value = raster.publish(output.raster_bytes) catch nih_native_task_failed();
                reply.raster_token = value.token;
            } else if (!raster.empty()) raster.discard() catch nih_native_task_failed();
        }
        sendReply(reply);
        if (active_operation == .render_text) {
            // Reply slots own their metadata. Reuse/retirement of the C++
            // buffer cannot change any result retained by the dispatcher.
            @memset(std.mem.asBytes(output), 0xa5);
            metrics.copied_outputs += 1;
        }
    }
    // SAFETY: receive assigns the union before its .item payload is used.
    var received: Requests.ReceiveResult = undefined;
    while (true) {
        received = requests.receive();
        const item = switch (received) {
            .item => |value| value,
            else => nih_native_task_failed(),
        };
        if (item.space_notification != 0) nih_native_task_failed();
        if (item.value.operation != .release_raster) break;
        raster.release(item.value.lease) catch nih_native_task_failed();
        sendReply(.{ .id = item.value.id, .operation = .release_raster, .retained = retained, .raster_token = item.value.lease });
    }
    if (!raster.empty()) nih_native_task_failed();
    state.accept(received.item.value) catch nih_native_task_failed();
    metrics.received += 1;
    if (received.item.value.operation != .stop) {
        active_operation = received.item.value.operation;
        active_source_hash = if (active_operation == .render_text) sourceHash(&received.item.value.render) else 0;
        job.* = .{ .operation = @backingInt(active_operation), .render = received.item.value.render };
        if (active_operation == .render_text) {
            if (raster.create()) |bytes| {
                job.raster = bytes.ptr;
                job.capacity = @intCast(bytes.len);
            } else |_| {}
        }
        return received.item.value.id;
    }
    sendReply(.{ .id = received.item.value.id, .operation = .stop, .retained = retained });
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
pub noinline fn poll(ticks: u64, runtime: u64, waiting: bool) void {
    while (true) {
        const reply = switch (replies.tryReceive()) {
            .item => |item| blk: {
                if (item.space_notification != 0) nih_native_task_failed();
                break :blk item.value;
            },
            .empty => break,
            else => nih_native_task_failed(),
        };
        if (reply.operation == .release_raster) {
            if (pending_release == 0 or reply.raster_token != pending_release or reply.id != release_id) nih_native_task_failed();
            if (raster.read(last_lease)) |_| nih_native_task_failed() else |_| {
                raster.metrics.stale_rejected += 1;
            }
            pending_release = 0;
            continue;
        }
        if (reply.id != metrics.replies + 1 or reply.id > metrics.sent or reply.retained != 65792) nih_native_task_failed();
        if (reply.id <= 4) {
            if (reply.operation != .render_matrix or reply.runs != 16) nih_native_task_failed();
            if (reply.id == 1) expected = reply.hashes else {
                for (reply.hashes, expected) |actual, reference| if (actual != reference) nih_native_task_failed();
            }
        } else if (reply.id <= 9) {
            if (reply.operation != .render_text or reply.runs > 1 or
                reply.outcome != (if (reply.id == 6) protocol.Outcome.render_failed else if (reply.id == 7) protocol.Outcome.output_full else protocol.Outcome.ok) or
                reply.runs != (if (reply.id == 6 or reply.id == 7) @as(u32, 0) else 1)) nih_native_task_failed();
            if (!archive.?.source_ready) nih_native_task_failed();
            composer.verifySource(&archive.?.source, reply.id, reply.sourceHash()) catch nih_native_task_failed();
            composer.source_metrics.echoed += 1;
            reply.output.validate() catch nih_native_task_failed();
            if (reply.output.outcome != @backingInt(reply.outcome)) nih_native_task_failed();
            var glyphs: []const protocol.Glyph = &.{};
            if (reply.outcome == .ok) {
                if (metrics.text_success >= 3) nih_native_task_failed();
                const saved = archive.?.glyphs[metrics.text_success][0..reply.output.count];
                @memcpy(saved, reply.output.glyphs[0..reply.output.count]);
                glyphs = saved;
            }
            archive.?.texts[reply.id - 5] = .{ .id = reply.id, .runs = reply.runs, .hashes = .{reply.hashes[0]}, .outcome = reply.outcome, .source_hash = reply.sourceHash(), .output = .{ .count = reply.output.count, .raster_bytes = reply.output.raster_bytes, .glyphs = glyphs } };
            if (reply.outcome == .ok and reply.output.raster_bytes != 0) {
                held = .{ .token = reply.raster_token, .bytes = reply.output.raster_bytes };
                held_id = reply.id;
                held_since = ticks;
                const bytes = raster.read(held) catch nih_native_task_failed();
                if (drawHash(&reply, bytes) != reply.hashes[0]) nih_native_task_failed();
                archive.?.texts[reply.id - 5].pixel_hash = digest(bytes);
                archive.?.texts[reply.id - 5].composition = composer.compose(&archive.?.source, &reply, bytes);
                if (raster.release(held.token)) |_| nih_native_task_failed() else |_| {
                    raster.metrics.foreign_rejected += 1;
                }
                if (last_lease.token != 0) {
                    if (raster.read(last_lease)) |_| nih_native_task_failed() else |_| {
                        raster.metrics.stale_rejected += 1;
                    }
                }
            } else if (reply.raster_token != 0) nih_native_task_failed();
            if (reply.outcome == .ok) metrics.text_success += 1 else metrics.text_failed += 1;
        } else if (reply.id != 10 or reply.operation != .stop or reply.runs != 0) nih_native_task_failed();
        metrics.replies += 1;
        if (reply.operation == .stop and calls.notify(replies.producer, terminal_ack) != 0) nih_native_task_failed();
    }
    if (held.token != 0) {
        const bytes = raster.read(held) catch nih_native_task_failed();
        if (digest(bytes) != archive.?.texts[held_id - 5].pixel_hash) nih_native_task_failed();
        if (ticks - held_since < 2) return;
        raster.metrics.held_ticks += @intCast(ticks - held_since);
        raster.retire(held) catch nih_native_task_failed();
        if (raster.read(held)) |_| nih_native_task_failed() else |_| {
            raster.metrics.stale_rejected += 1;
        }
        pending_release = held.token;
        release_id = held_id;
        last_lease = held;
        held = .{};
        submitted = .{ .id = release_id, .operation = .release_raster, .lease = pending_release };
        switch (requests.trySend(submitted)) {
            .sent => {},
            else => nih_native_task_failed(),
        }
        return;
    }
    if (pending_release != 0 or metrics.sent == 10 or !waiting) return;
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
    submitted = .{ .id = metrics.sent, .operation = if (metrics.sent <= 4) .render_matrix else if (metrics.sent <= 9) .render_text else .stop };
    if (options.graphics and metrics.sent >= 5 and metrics.sent <= 9) {
        if (!composer.contextAllowed()) nih_native_task_failed();
        stageText();
    }
    switch (requests.trySend(submitted)) {
        .sent => {},
        else => nih_native_task_failed(),
    }
}

pub fn report() Report {
    return metrics;
}

pub fn finished() bool {
    return bound and state.stopped and state.active == null and metrics.sent == 10 and metrics.received == 10 and
        metrics.replies == 10 and metrics.waits == 10 and metrics.blocked_ticks >= 20 and metrics.stop_ack == 1 and metrics.terminal_gap == 1 and metrics.copied_inputs == 5 and metrics.copied_outputs == 5 and metrics.text_success == 3 and metrics.text_failed == 2 and
        raster.empty() and raster.metrics.created == 5 and raster.metrics.reclaimed == 3 and raster.metrics.discarded == 2 and pending_release == 0 and
        requests.ring.countApprox() == 0 and replies.ring.countApprox() == 0;
}

// A real mutable caller edit: prepend 新, keep 日本語 and drop the old suffix.
// The font worker and layout must both use these runtime bytes/ranges.
inline fn editSource(render: *protocol.Render, annotation: *@import("text_context").ruby.Annotation) void {
    std.mem.copyBackwards(u8, render.body[3..12], render.body[0..9]);
    @memcpy(render.body[0..3], "新");
    render.body_length = 12;
    @memset(render.body[12..], 0);
    annotation.base.start += 3;
    annotation.base.end += 3;
    composer.source_metrics.edited += 1;
}

// Immutable fixture inputs stay mapped; only the runtime caller copy is edited.
const Input = struct { font: u32, pixels: u32, vertical: u32, hinting: u32, body: []const u8, reading: []const u8, annotations: []const @import("text_context").ruby.Annotation };
fn InputAnnotations(comptime index: usize) type {
    return struct {
        const value linksection(".flash.rodata.display") = blk: {
            const source = options.font_ruby_cases[index];
            var result: [source.len]@import("text_context").ruby.Annotation = @splat(.{ .base = .{ .start = 0, .end = 0 }, .ruby = .{ .start = 0, .end = 0 } });
            for (source, 0..) |entry, n| result[n] = .{ .base = .{ .start = entry.base_start, .end = entry.base_end }, .ruby = .{ .start = entry.ruby_start, .end = entry.ruby_end } };
            break :blk result;
        };
    };
}
const inputs: [options.font_text_cases.len]Input linksection(".flash.rodata.display") = blk: {
    // SAFETY: every input slot is assigned by the compile-time loop.
    var result: [options.font_text_cases.len]Input = undefined;
    for (options.font_text_cases, 0..) |item, i| result[i] = .{ .font = item.font, .pixels = item.pixels, .vertical = item.vertical, .hinting = item.hinting, .body = item.body, .reading = item.ruby, .annotations = &InputAnnotations(i).value };
    break :blk result;
};
// Caller input preparation is task-only, separate from the SRAM transport.
noinline fn stageText() linksection(".flash.text.render") void {
    composer.source_metrics.input_pc = asm volatile ("auipc %[pc], 0"
        : [pc] "=r" (-> u32),
    );
    const item = inputs[metrics.sent - 5];
    submitted.render = protocol.Render.init(item.font, item.pixels, item.vertical, item.hinting, item.body, item.reading) catch nih_native_task_failed();
    var annotations: [8]@import("text_context").ruby.Annotation = @splat(.{ .base = .{ .start = 0, .end = 0 }, .ruby = .{ .start = 0, .end = 0 } });
    @memcpy(annotations[0..item.annotations.len], item.annotations);
    if (metrics.sent == 5) editSource(&submitted.render, &annotations[0]);
    const previous = if (archive.?.source_ready) archive.?.source.seal else 0;
    var invalid = submitted.render;
    invalid.body[0] = 0xff;
    // SAFETY: stage initializes the full candidate only on success.
    var candidate: composer.Context = undefined;
    if (composer.stage(&candidate, metrics.sent, invalid, annotations[0..item.annotations.len])) |_| nih_native_task_failed() else |err| {
        if (err != error.InvalidPayload) nih_native_task_failed();
    }
    if (archive.?.source_ready and archive.?.source.seal != previous) nih_native_task_failed();
    composer.stage(&candidate, metrics.sent, submitted.render, annotations[0..item.annotations.len]) catch nih_native_task_failed();
    archive.?.source = candidate;
    archive.?.source_ready = true;
    @memset(std.mem.sliceAsBytes(&annotations), 0xff);
    composer.source_metrics.poisoned += 1;
}

// Called only by the font task after the SRAM caller/identity gate.
noinline fn sourceHash(render: *const protocol.Render) linksection(".flash.text.render") u32 {
    return protocol.renderHash(render);
}
