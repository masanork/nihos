//! Fixed public vector on a borrowed worker stack. Not a network session.
const std = @import("std");
const hybrid = @import("ssh_hybrid_transcript.zig");
const proof = @import("ssh_host_key.zig");
const reply = @import("ssh_hybrid_reply.zig");
const vector = @import("ssh_hybrid_vector.zig");
const X = std.crypto.dh.X25519;
const Job = extern struct { secret_key: [2400]u8, epoch: u32, phase: c_int, arena_peak: usize };
extern fn nih_kem_init(*Job) callconv(.c) void;
extern fn nih_kem_begin(*Job, u32, [*]u8, usize, *const [64]u8, *[1184]u8) callconv(.c) c_int;
extern fn nih_kem_decaps(*Job, u32, [*]u8, usize, *const [1088]u8, *[32]u8) callconv(.c) c_int;
extern fn nih_kem_cancel(*Job, u32) callconv(.c) c_int;
const encoded = @embedFile("ssh_hybrid_public_vector.bin");
const v: *const vector.Vector = @ptrCast(encoded.ptr);
comptime {
    if (encoded.len != @sizeOf(vector.Vector)) @compileError("fixture vector size");
}
pub const Result = extern struct { ok: u32 = 0, wrong_pin: u32 = 0, bad_sig: u32 = 0, bad_transcript: u32 = 0, secret_cleared: u32 = 0 };
fn prepare(bytes: []u8) bool {
    if (bytes.len < 64 * 1024) return false;
    const job: *Job = @ptrCast(@alignCast(bytes[32768..].ptr));
    const public: *[1184]u8 = @ptrCast(bytes[35200..].ptr);
    nih_kem_init(job);
    return nih_kem_begin(job, 1, bytes.ptr, 32768, &v.seed, public) == 0;
}
const packet_offset = 38000;
const packet_len = 1 + 4 + 51 + 4 + 1120 + 4 + 83;
fn supply(bytes: []u8) usize {
    if (bytes.len < 64 * 1024 or !std.mem.eql(u8, bytes[35200..36384], &v.pk)) return 0;
    const out = bytes[packet_offset..][0..packet_len];
    out[0] = 31;
    var pos: usize = 1;
    for ([_][]const u8{ &v.host, &v.server, &v.signature }) |part| {
        std.mem.writeInt(u32, out[pos..][0..4], @intCast(part.len), .big);
        pos += 4;
        @memcpy(out[pos..][0..part.len], part);
        pos += part.len;
    }
    return pos;
}
fn finish(bytes: []u8, bad_trusted_pin: bool) Result {
    var result: Result = .{};
    if (bytes.len < 64 * 1024) return result;
    const job: *Job = @ptrCast(@alignCast(bytes[32768..].ptr));
    const public: *[1184]u8 = @ptrCast(bytes[35200..].ptr);
    var pq: [32]u8 = @splat(0);
    var classical: [32]u8 = @splat(0);
    var combined: [32]u8 = @splat(0);
    defer {
        std.crypto.secureZero(u8, &pq);
        std.crypto.secureZero(u8, &classical);
        std.crypto.secureZero(u8, &combined);
    }
    const parsed = reply.parse(bytes[packet_offset..][0..packet_len]) catch return result;
    const server = parsed.server;
    if (!std.mem.eql(u8, server, bytes[36416..37536])) return result;
    if (nih_kem_decaps(job, 1, bytes.ptr, 32768, server[0..1088], &pq) != 0) return result;
    result.secret_cleared = @intFromBool(std.mem.allEqual(u8, &job.secret_key, 0));
    @memcpy(bytes[37536..37568], &pq); // public test vector, consumed and erased by parent
    classical = X.scalarmult(v.xsecret, server[1088..][0..32].*) catch return result;
    combined = hybrid.combine(pq, classical) catch return result;
    if (!std.mem.eql(u8, &combined, &v.combined)) return result;
    var client: [1216]u8 = undefined;
    client[0..1184].* = public.*;
    client[1184..].* = X.recoverPublicKey(v.xsecret);
    const hash = hybrid.exchangeHash(vector.client_banner, vector.server_banner, vector.client_kex, vector.server_kex, parsed.host, &client, server, combined) catch return result;
    if (!std.mem.eql(u8, &hash, &v.hash)) return result;
    var wrong_pin = v.pin;
    wrong_pin[0] ^= 1;
    if (proof.verify(parsed.host, parsed.signature, hash, wrong_pin)) |_| {} else |err| {
        result.wrong_pin = @intFromBool(err == error.HostKeyMismatch);
    }
    var bad_signature: [83]u8 = parsed.signature[0..83].*;
    bad_signature[82] ^= 1;
    if (proof.verify(parsed.host, &bad_signature, hash, v.pin)) |_| {} else |err| {
        result.bad_sig = @intFromBool(err == error.InvalidSignature);
    }
    var bad_server = server.*;
    bad_server[0] ^= 1;
    const bad_hash = hybrid.exchangeHash(vector.client_banner, vector.server_banner, vector.client_kex, vector.server_kex, parsed.host, &client, &bad_server, combined) catch return result;
    if (proof.verify(parsed.host, parsed.signature, bad_hash, v.pin)) |_| {} else |err| {
        result.bad_transcript = @intFromBool(err == error.InvalidSignature);
    }
    proof.verify(parsed.host, parsed.signature, hash, if (bad_trusted_pin) wrong_pin else v.pin) catch return result;
    result.ok = @intFromBool(result.wrong_pin == 1 and result.bad_sig == 1 and result.bad_transcript == 1 and result.secret_cleared == 1);
    return result;
}
export fn nih_ssh_hybrid_prepare(bytes: [*]u8, len: usize) callconv(.c) bool {
    return prepare(bytes[0..len]);
}
export fn nih_ssh_hybrid_supply(bytes: [*]u8, len: usize) callconv(.c) usize {
    return supply(bytes[0..len]);
}
export fn nih_ssh_hybrid_cancel(bytes: [*]u8, len: usize) callconv(.c) bool {
    if (len < 64 * 1024) return false;
    const job: *Job = @ptrCast(@alignCast(bytes + 32768));
    return nih_kem_cancel(job, 1) == 0 and std.mem.allEqual(u8, &job.secret_key, 0);
}
export fn nih_ssh_hybrid_finish(bytes: [*]u8, len: usize, bad_trusted_pin: u32, out: *Result) callconv(.c) void {
    out.* = finish(bytes[0..len], bad_trusted_pin != 0);
}

// Test-only driver objects live in the same pinned PSRAM as the worker. The
// owner transfers exclusive access to the child until it has been reaped.
const driver_mod = @import("ssh_hybrid_driver.zig");
const transport = @import("ssh_transport.zig");
const token = @import("ssh_kem_handoff.zig").Token{ .epoch = 7, .request = 1 };
const driver_offset = 180224;
const wire_offset = 196608;
comptime {
    if (driver_offset + @sizeOf(driver_mod.Driver) > wire_offset) @compileError("driver overlaps transport");
    if (wire_offset + @sizeOf(transport.Transport) > 320 * 1024) @compileError("transport exceeds test pin");
}
fn driverAt(bytes: [*]u8) *driver_mod.Driver {
    return @ptrCast(@alignCast(bytes + driver_offset));
}
fn wireAt(bytes: [*]u8) *transport.Transport {
    return @ptrCast(@alignCast(bytes + wire_offset));
}
export fn nih_ssh_driver_fixture_prepare(bytes: [*]u8, len: usize, now: u64, bad_pin: u32) callconv(.c) bool {
    if (len < 320 * 1024) return false;
    var pin = v.pin;
    if (bad_pin != 0) pin[0] ^= 1;
    const d = driverAt(bytes);
    d.protocol.initInPlace(v.xsecret, pin, vector.server_banner, &v.pk) catch return false;
    @memcpy(d.protocol.client_init[0..vector.client_kex.len], vector.client_kex);
    d.protocol.client_len = vector.client_kex.len;
    @memcpy(d.protocol.server_init[0..vector.server_kex.len], vector.server_kex);
    d.protocol.server_len = vector.server_kex.len;
    d.initInPlace(@splat(1), token, now, now +| 1000000) catch return false;
    d.state = .server_reply;
    wireAt(bytes).* = .{};
    return true;
}
export fn nih_ssh_driver_fixture_submit(bytes: [*]u8, len: usize, now: u64, received_len: usize) callconv(.c) bool {
    if (len < 320 * 1024 or received_len != packet_len) return false;
    const d = driverAt(bytes);
    const wire = wireAt(bytes);
    const packet = bytes[38000..][0..received_len];
    _ = reply.parse(packet) catch return false;
    // The parent already validated the complete frame with InitialDecoder.
    // Supply that decoded payload at the transport boundary for this fixture.
    @memcpy(wire.rx.buffer[0..received_len], packet);
    wire.rx.used = received_len;
    wire.rx.payload_start = 0;
    wire.rx.payload_len = received_len;
    wire.rx.pending = true;
    const Worker = struct {
        fn submit(context: ?*anyopaque, given: @import("ssh_kem_handoff.zig").Token, ct: *const [1088]u8) bool {
            if (given.epoch != token.epoch or given.request != token.request) return false;
            const dst: *[1088]u8 = @ptrCast(@alignCast(context orelse return false));
            dst.* = ct.*;
            return true;
        }
    };
    const out: *[1088]u8 = @ptrCast(bytes + 42000);
    if (!(d.dispatchReply(wire, now, out, &Worker.submit) catch return false)) return false;
    if (d.state != .waiting_worker or wire.rx.payload() != null) return false;
    if (!std.mem.eql(u8, out, bytes[36416..37504])) return false;
    return true;
}
export fn nih_ssh_driver_fixture_complete(bytes: [*]u8, len: usize, now: u64, expect_ok: u32) callconv(.c) bool {
    if (len < 320 * 1024) return false;
    const d = driverAt(bytes);
    const secret: *const [32]u8 = @ptrCast(bytes + 37536);
    d.complete(wireAt(bytes), token, now, secret) catch |err| return expect_ok == 0 and err == error.HostProofFailed;
    return expect_ok == 1 and d.state == .send_newkeys and d.keys != null;
}
export fn nih_ssh_driver_fixture_reclaim(bytes: [*]u8, len: usize, timed_out: u32, expect_ok: u32) callconv(.c) bool {
    if (len < 320 * 1024) return false;
    const d = driverAt(bytes);
    const wire = wireAt(bytes);
    if (timed_out != 0) {
        d.abort(wire);
        d.exchange.handoff.cancelAcknowledged(token) catch return false;
        return d.exchange.handoff.reclaimable();
    }
    if (expect_ok != 0) {
        const keys = if (d.keys) |*k| k else return false;
        if (!std.mem.eql(u8, &keys.exchange_hash, &v.hash)) return false;
    } else if (d.state != .failed or d.keys != null or !wire.failed) return false;
    d.abort(wire);
    return d.exchange.handoff.reclaimable();
}
