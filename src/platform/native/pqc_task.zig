//! Headless emulator-only fixed-vector scheduler fixture. Not SSH or production.
const std = @import("std");
const tasks = @import("native_tasks");
const options = @import("native_options");
const kem = @import("hosted_station").pqc_handoff;
const reply = @import("hosted_station").pqc_reply;
const stream = @import("hosted_station").pqc_stream;
const ssh = @import("hosted_station").pqc_ssh;
const token: kem.Token = .{ .epoch = 1, .request = 1 };
var handoff: kem.Handoff = .{};
var handoff_ok: u32 = 0;
const lease_bytes = 320 * 1024;
const decoder_offset = 128 * 1024;
const frame_offset = 170 * 1024;
comptime {
    if (decoder_offset + @sizeOf(stream.InitialDecoder) > frame_offset) @compileError("decoder overlaps frame");
    if (frame_offset + 2048 > lease_bytes) @compileError("frame exceeds backing");
}
const stack_offset = 64 * 1024;
const stack_bytes = 64 * 1024;
const Result = extern struct { ok: u32 = 0, peak: u32 = 0, wrong_epoch: u32 = 0, repeat: u32 = 0, canceled: u32 = 0 };
extern fn nih_pqc_task_fixture([*]u8, *Result) callconv(.c) i32;
var backing: ?tasks.memory.reusable.Pin = null;
var result: Result = .{};
const SshResult = extern struct { ok: u32 = 0, wrong_pin: u32 = 0, bad_sig: u32 = 0, bad_transcript: u32 = 0, secret_cleared: u32 = 0 };
extern fn nih_ssh_hybrid_prepare([*]u8, usize) callconv(.c) bool;
extern fn nih_ssh_hybrid_supply([*]u8, usize) callconv(.c) usize;
extern fn nih_ssh_hybrid_cancel([*]u8, usize) callconv(.c) bool;
extern fn nih_ssh_hybrid_finish([*]u8, usize, u32, *SshResult) callconv(.c) void;
extern fn nih_ssh_driver_fixture_prepare([*]u8, usize, u64, u32) callconv(.c) bool;
extern fn nih_ssh_driver_fixture_submit([*]u8, usize, u64, usize) callconv(.c) bool;
extern fn nih_ssh_driver_fixture_complete([*]u8, usize, u64, u32) callconv(.c) bool;
extern fn nih_ssh_driver_fixture_reclaim([*]u8, usize, u32, u32) callconv(.c) bool;
var driver_verified: u32 = 0;

var ssh_result: SshResult = .{};
var phase: u32 = 0;
var waits: u32 = 0;
var delivered: u32 = 0;
var child_handle: ?tasks.calls.Handle = null;
var shortened = false;
var deadline_observed: u32 = 0;
var packet_checked: u32 = 0;
var before: usize = 0;
var during: usize = 0;
var started = false;
var ticks_before: [2]u32 = .{ 0, 0 };
fn entry(argument: u32) callconv(.c) i32 {
    const current = tasks.calls.current() orelse return -91;
    if (argument != (@as(u32, current.generation) << 16 | current.slot)) return -92;
    const bytes = (backing orelse return -93).allocation.bytes;
    const rc = nih_pqc_task_fixture(bytes.ptr, &result);
    if (rc != 0) return rc;
    if (!nih_ssh_hybrid_prepare(bytes.ptr, bytes.len)) return -95;
    if (!nih_ssh_driver_fixture_prepare(bytes.ptr, bytes.len, tasks.calls.nowTicks(), @intFromBool(options.pqc_ssh_negative == 2))) return -98;
    @atomicStore(u32, &phase, 1, .release);
    while (true) {
        const current_phase = @atomicLoad(u32, &phase, .acquire);
        if (current_phase == 2) break;
        if (current_phase == 4) {
            ssh_result.secret_cleared = @intFromBool(nih_ssh_hybrid_cancel(bytes.ptr, bytes.len));
            @atomicStore(u32, &phase, 5, .release);
            return -97;
        }
        _ = @atomicRmw(u32, &waits, .Add, 1, .monotonic);
        switch (tasks.calls.waitEvents(1)) {
            .received => {},
            .failed => return -96,
        }
    }
    nih_ssh_hybrid_finish(bytes.ptr, bytes.len, @intFromBool(options.pqc_ssh_negative == 2), &ssh_result);
    @atomicStore(u32, &driver_verified, @intFromBool(nih_ssh_driver_fixture_complete(bytes.ptr, bytes.len, tasks.calls.nowTicks(), @intFromBool(options.pqc_ssh_negative == 0))), .release);
    @atomicStore(u32, &phase, 3, .release);
    return if (ssh_result.ok == 1) 0 else -95;
}
pub fn start(log: anytype) void {
    before = (tasks.memory.reusable.localUsage() orelse {
        log.record("NIHOS_PQC_TASK_SKIP", null, .{"reason"}, &@as(extern struct { reason: u32 }, .{ .reason = 1 }));
        return;
    }).free;
    const pin = tasks.memory.reusable.allocPinnedTask(lease_bytes, 64) catch {
        log.record("NIHOS_PQC_TASK_SKIP", null, .{"reason"}, &@as(extern struct { reason: u32 }, .{ .reason = 2 }));
        return;
    };
    backing = pin;
    const bytes = pin.allocation.bytes;
    @memset(bytes, 0);
    @memset(bytes[stack_offset..][0..stack_bytes], 0xa5);
    if (tasks.memory.freeExternal(pin.allocation)) |_| @panic("pqc unpinned") else |err| if (err != error.Pinned) @panic("pqc pin error");
    const child = tasks.registerWasm(pin, stack_offset, &entry) orelse {
        @memset(bytes, 0);
        tasks.memory.reusable.releasePinnedTask(pin) catch @panic("pqc release error");
        backing = null;
        log.record("NIHOS_PQC_TASK_SKIP", null, .{"reason"}, &@as(extern struct { reason: u32 }, .{ .reason = 3 }));
        return;
    };
    child_handle = .{ .slot = child.slot, .generation = child.generation };
    during = (tasks.memory.reusable.localUsage() orelse @panic("pqc usage")).free;
    ticks_before = .{ tasks.report(0).ticks, tasks.report(1).ticks };
    const now = tasks.calls.nowTicks();
    handoff.start(token, now, now +| 1000000) catch @panic("pqc handoff start");
    started = true;
}
pub fn service(log: anytype) bool {
    if (!started) return false;
    const pin = backing orelse @panic("pqc pin absent");
    if (@atomicLoad(u32, &phase, .acquire) == 1 and delivered == 0) {
        const bytes = pin.allocation.bytes;
        if (handoff.phase == .generating) {
            handoff.publicComplete(token, tasks.calls.nowTicks(), @ptrCast(bytes[35200..].ptr)) catch @panic("pqc public");
            var public: [1184]u8 = undefined;
            handoff.takePublic(token, tasks.calls.nowTicks(), &public) catch @panic("pqc public copy");
            if (!std.mem.eql(u8, &public, bytes[35200..36384])) @panic("pqc public mismatch");
        }
        if (options.pqc_ssh_negative == 3) {
            const now = tasks.calls.nowTicks();
            if (!shortened) {
                handoff.shortenDeadline(token, now, now +| 2) catch @panic("pqc deadline");
                shortened = true;
            }
            handoff.tick(token, now) catch |err| switch (err) {
                error.TimedOut => {
                    deadline_observed = 1;
                    @atomicStore(u32, &phase, 4, .release);
                    if (tasks.calls.notify(child_handle orelse @panic("pqc handle"), 1) != 0) @panic("pqc timeout notify");
                    delivered = 1;
                },
                else => @panic("pqc clock"),
            };
        } else {
            const n = nih_ssh_hybrid_supply(bytes.ptr, bytes.len);
            if (n == 0 or n > 2048) @panic("pqc response fixture");
            const packet = bytes[38000..][0..n];
            if (options.pqc_ssh_negative == 1) packet[1 + 4 + 51 + 4] ^= 1;
            if (options.pqc_ssh_negative == 4) packet[n - 1] ^= 1;
            const frame = bytes[frame_offset..][0..2048];
            const framed = ssh.packPacket(packet, 0, false, null, null, &@as([32]u8, @splat(0x55)), frame) catch @panic("pqc frame");
            @memset(packet, 0); // Ensure the consumer uses the decoded copy.
            const decoder: *stream.InitialDecoder = @ptrCast(@alignCast(bytes[decoder_offset..].ptr));
            decoder.* = .{};
            if (decoder.feed(&.{ 0xff, 0xff, 0xff, 0xff, 0, 0, 0, 0 })) |_| @panic("pqc bad frame accepted") else |_| {}
            decoder.* = .{};
            var offset: usize = 0;
            while (offset < framed) {
                const end = @min(offset + 13, framed);
                const consumed = decoder.feed(frame[offset..end]) catch @panic("pqc frame decode");
                if (consumed == 0) @panic("pqc frame progress");
                offset += consumed;
            }
            const decoded = decoder.payload() orelse @panic("pqc frame absent");
            if (decoded.len != n) @panic("pqc frame length");
            if (reply.parse(decoded[0 .. n - 1])) |_| @panic("pqc truncated accepted") else |_| {}
            _ = reply.parse(decoded) catch @panic("pqc packet");
            @memcpy(packet, decoded);
            decoder.release();
            const parsed = reply.parse(packet) catch @panic("pqc packet copy");
            packet_checked = 1;
            @memcpy(bytes[36416..37536], parsed.server);
            handoff.submitReply(token, tasks.calls.nowTicks(), parsed.ciphertext()) catch @panic("pqc reply");
            var ciphertext: [1088]u8 = undefined;
            handoff.takeCiphertext(token, tasks.calls.nowTicks(), &ciphertext) catch @panic("pqc ciphertext");
            if (!std.mem.eql(u8, &ciphertext, bytes[36416..37504])) @panic("pqc ciphertext mismatch");
            if (!nih_ssh_driver_fixture_submit(bytes.ptr, bytes.len, tasks.calls.nowTicks(), n)) @panic("pqc driver submit");
            @atomicStore(u32, &phase, 2, .release);
            if (tasks.calls.notify(child_handle orelse @panic("pqc handle"), 1) != 0) @panic("pqc notify");
            delivered = 1;
        }
    }
    const completed = tasks.finishWasm() orelse return true;
    const bytes = pin.allocation.bytes;
    const completed_phase = @atomicLoad(u32, &phase, .acquire);
    if (completed_phase != (if (options.pqc_ssh_negative == 3) @as(u32, 5) else 3)) @panic("pqc driver phase");
    const verified = @atomicLoad(u32, &driver_verified, .acquire);
    const driver_reclaimed = nih_ssh_driver_fixture_reclaim(bytes.ptr, bytes.len, @intFromBool(options.pqc_ssh_negative == 3), @intFromBool(options.pqc_ssh_negative == 0));
    if (!driver_reclaimed or (options.pqc_ssh_negative != 3 and verified != 1)) @panic("pqc driver result");
    log.record("NIHOS_PQC_DRIVER", null, .{ "verified", "reclaimed" }, &@as(extern struct { verified: u32, reclaimed: u32 }, .{ .verified = verified, .reclaimed = @intFromBool(driver_reclaimed) }));
    if (options.pqc_ssh_negative == 3) {
        handoff.cancelAcknowledged(token) catch @panic("pqc cancel acknowledgement");
        handoff_ok = @intFromBool(handoff.reclaimable() and ssh_result.secret_cleared == 1);
    } else {
        handoff.secretComplete(token, tasks.calls.nowTicks(), @ptrCast(bytes[37536..].ptr)) catch @panic("pqc secret");
        std.crypto.secureZero(u8, bytes[37536..37568]);
        const Verify = struct {
            fn call(_: ?*anyopaque, _: *const [32]u8) bool {
                return ssh_result.ok == 1;
            }
        };
        const accepted = handoff.authenticate(token, tasks.calls.nowTicks(), null, &Verify.call) catch @panic("pqc verify");
        handoff_ok = @intFromBool(handoff.reclaimable() and accepted == (options.pqc_ssh_negative == 0));
    }
    log.record("NIHOS_PQC_HANDOFF", null, .{ "ok", "deadline", "packet" }, &@as(extern struct { ok: u32, deadline: u32, packet: u32 }, .{ .ok = handoff_ok, .deadline = deadline_observed, .packet = packet_checked }));
    var guards: u32 = 1;
    for (bytes[stack_offset..][0..128]) |byte| if (byte != 0xa5) {
        guards = 0;
    };
    var used: usize = 128;
    while (used < stack_bytes and bytes[stack_offset + used] == 0xa5) : (used += 1) {}
    const stack_used = stack_bytes - used;
    const old_high: u32 = @intCast(@intFromPtr(bytes.ptr) + stack_offset + stack_bytes);
    const stale_rejected = !tasks.acceptsWasmFrame(0, 0x1880, old_high - 128, old_high);
    const stale_notify = tasks.calls.notify(child_handle orelse @panic("pqc handle"), 1) == tasks.calls.Status.not_found;
    std.crypto.secureZero(u8, bytes);
    const erased = std.mem.allEqual(u8, bytes, 0);
    tasks.memory.reusable.releasePinnedTask(pin) catch @panic("pqc release");
    backing = null;
    const after = (tasks.memory.reusable.localUsage() orelse @panic("pqc final usage")).free;
    const record: extern struct { status: u32, ok: u32, peak: u32, wrong_epoch: u32, repeat: u32, canceled: u32, captures: u32, timers: u32, stack_used: u32, guards: u32, erased: u32, released: u32, stale: u32, stale_notify: u32, charged: u32, ticks0: u32, ticks1: u32, ssh_ok: u32, ssh_bad_pin: u32, ssh_bad_sig: u32, ssh_bad_transcript: u32, ssh_secret_cleared: u32, phase: u32, waits: u32, delivered: u32, negative: u32 } = .{
        .status = @bitCast(completed.exit_code),
        .ok = result.ok,
        .peak = result.peak,
        .wrong_epoch = result.wrong_epoch,
        .repeat = result.repeat,
        .canceled = result.canceled,
        .captures = completed.captures,
        .timers = completed.timers,
        .stack_used = @intCast(stack_used),
        .guards = guards,
        .erased = @intFromBool(erased),
        .released = @intFromBool(after == before),
        .stale = @intFromBool(stale_rejected),
        .stale_notify = @intFromBool(stale_notify),
        .charged = @intCast(before - during),
        .ticks0 = tasks.report(0).ticks -% ticks_before[0],
        .ticks1 = tasks.report(1).ticks -% ticks_before[1],
        .ssh_ok = ssh_result.ok,
        .ssh_bad_pin = ssh_result.wrong_pin,
        .ssh_bad_sig = ssh_result.bad_sig,
        .ssh_bad_transcript = ssh_result.bad_transcript,
        .ssh_secret_cleared = ssh_result.secret_cleared,
        .phase = @atomicLoad(u32, &phase, .acquire),
        .waits = @atomicLoad(u32, &waits, .acquire),
        .delivered = delivered,
        .negative = options.pqc_ssh_negative,
    };
    log.record("NIHOS_PQC_TASK", null, .{ "status", "ok", "peak", "wrong_epoch", "repeat", "canceled", "captures", "timers", "stack_used", "guards", "erased", "released", "stale", "stale_notify", "charged", "ticks0", "ticks1", "ssh_ok", "ssh_bad_pin", "ssh_bad_sig", "ssh_bad_transcript", "ssh_secret_cleared", "phase", "waits", "delivered", "negative" }, &record);
    started = false;
    return false;
}
