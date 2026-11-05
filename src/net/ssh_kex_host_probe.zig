//! Host-only C ABI used by the local OpenSSH interoperability probe.
const std = @import("std");
const handshake = @import("ssh_handshake.zig");
const transport = @import("ssh_transport.zig");
const socket_pump = @import("ssh_socket_pump.zig");
const session = @import("ssh_session.zig");
const kex_driver = @import("ssh_kex_driver.zig");
const identification = @import("ssh_identification.zig");
const connection = @import("ssh_connection.zig");
const client = @import("ssh_client.zig");
const terminal = @import("ssh_terminal.zig");
var wire: transport.Transport = .{};
var pump = socket_pump.Pump{ .wire = &wire, .epoch = 1 };
const ReadFn = *const fn ([*]u8, usize) callconv(.c) isize;
const WriteFn = *const fn ([*]const u8, usize) callconv(.c) isize;
var read_fn: ?ReadFn = null;
var write_fn: ?WriteFn = null;
fn socketRead(_: ?*anyopaque, dst: []u8) socket_pump.SocketError!socket_pump.Result {
    const n = (read_fn orelse return error.SocketFailed)(dst.ptr, dst.len);
    return if (n > 0) .{ .progress = @intCast(n) } else if (n == -1) .would_block else if (n == 0) .eof else error.SocketFailed;
}
fn socketWrite(_: ?*anyopaque, src: []const u8) socket_pump.SocketError!socket_pump.Result {
    const n = (write_fn orelse return error.SocketFailed)(src.ptr, src.len);
    return if (n > 0) .{ .progress = @intCast(n) } else if (n == -1) .would_block else if (n == 0) .eof else error.SocketFailed;
}
export fn probe_socket(read: ReadFn, write: WriteFn) void {
    read_fn = read;
    write_fn = write;
}
export fn probe_poll() bool {
    pump.poll(.{ .context = null, .read = socketRead, .write = socketWrite }, 1) catch return false;
    return true;
}
export fn probe_pending() usize {
    return wire.pending().len;
}
export fn probe_pause(paused: bool) void {
    pump.receive_paused = paused;
}
var ssh_session: ?session.Session = null;
var hs: ?handshake.Handshake = null;
const hybrid_probe = @import("ssh_hybrid_host_probe.zig");
const handoff_module = @import("ssh_kem_handoff.zig");
const hybrid_reply = @import("ssh_hybrid_reply.zig");
const handoff_token = handoff_module.Token{ .epoch = 1, .request = 1 };
var hybrid_exchange: @import("ssh_hybrid_exchange.zig").Exchange = .{};
extern fn nih_host_mlkem_peak() usize;
extern fn nih_host_mlkem_allocation_failure() c_int;
export fn probe_mlkem_peak() usize {
    return if (@import("pqc_config").native) nih_host_mlkem_peak() else 0;
}
export fn probe_mlkem_allocation_failure() bool {
    return if (@import("pqc_config").native) nih_host_mlkem_allocation_failure() == 1 else false;
}
var hybrid: ?hybrid_probe.Probe = null;
var hybrid_keys: ?@import("ssh_kex.zig").Keys = null;
export fn probe_hybrid_init(out: [*]u8, cap: usize, cookie: *const [16]u8, seed: *const [64]u8, secret: *const [32]u8, pin: *const [32]u8, banner: [*]const u8, len: usize) usize {
    hybrid = hybrid_probe.Probe.init(seed.*, secret.*, pin.*, banner[0..len]) catch return 0;
    const h = if (hybrid) |*v| v else return 0;
    hybrid_exchange = .{};
    hybrid_exchange.handoff.start(handoff_token, 1, 100) catch return 0;
    hybrid_exchange.handoff.publicComplete(handoff_token, 2, h.protocol.client[0..1184]) catch return 0;
    var public: [1184]u8 = undefined;
    hybrid_exchange.handoff.takePublic(handoff_token, 3, &public) catch return 0;
    if (!std.mem.eql(u8, &public, h.protocol.client[0..1184])) return 0;
    const result = h.start(cookie.*, out[0..cap]) catch return 0;
    return result.len;
}
export fn probe_hybrid_server_init(input: [*]const u8, len: usize, out: [*]u8, cap: usize) usize {
    const h = if (hybrid) |*v| v else return 0;
    const result = h.serverInit(input[0..len], out[0..cap]) catch return 0;
    return result.len;
}
export fn probe_hybrid_reply(input: [*]const u8, len: usize) bool {
    const h = if (hybrid) |*v| v else return false;
    defer h.deinit();
    var wrong = h.*;
    defer wrong.deinit();
    wrong.protocol.pin[0] ^= 1;
    if (wrong.finish(input[0..len])) |_| return false else |err| if (err != error.HostKeyMismatch) return false;
    if (h.finish(input[0..len -| 1])) |_| return false else |_| {}
    if (len > 2048 or len < 10) return false;
    var altered: [2048]u8 = undefined;
    @memcpy(altered[0..len], input[0..len]);
    const parsed = hybrid_reply.parse(input[0..len]) catch return false;
    const ciphertext_start = @intFromPtr(parsed.ciphertext()) - @intFromPtr(input);
    altered[ciphertext_start] ^= 1;
    var altered_job = h.*;
    defer altered_job.deinit();
    if (altered_job.finish(altered[0..len])) |_| return false else |err| if (err != error.InvalidSignature) return false;
    var copied: [1088]u8 = undefined;
    hybrid_exchange.handoff.takeCiphertext(handoff_token, 5, &copied) catch return false;
    var pq = h.decaps(&copied) catch return false;
    defer std.crypto.secureZero(u8, &pq);
    hybrid_exchange.handoff.secretComplete(handoff_token, 6, &pq) catch return false;
    const Verify = struct {
        probe: *hybrid_probe.Probe,
        keys: ?@import("ssh_kex.zig").Keys = null,
        fn run(context: ?*anyopaque, received: []const u8, shared: *const [32]u8) bool {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.keys = self.probe.finishWithPq(received, shared) catch return false;
            return true;
        }
    };
    var verifier = Verify{ .probe = h };
    defer if (verifier.keys) |*keys| std.crypto.secureZero(u8, std.mem.asBytes(keys));
    const accepted = hybrid_exchange.authenticate(handoff_token, 7, &verifier, &Verify.run) catch return false;
    if (!accepted or !hybrid_exchange.handoff.reclaimable()) return false;
    hybrid_keys = verifier.keys orelse return false;
    return true;
}
export fn probe_hybrid_capture() bool {
    hybrid_exchange.captureReply(&wire, handoff_token, 4) catch return false;
    return true;
}
export fn probe_hybrid_reply_owned() bool {
    if (hybrid_exchange.reply.len == 0) return false;
    defer hybrid_exchange.abort();
    return probe_hybrid_reply(&hybrid_exchange.reply.bytes, hybrid_exchange.reply.len);
}
export fn probe_hybrid_activate(input: [*]const u8, len: usize) bool {
    if (!std.mem.eql(u8, input[0..len], &.{21})) return false;
    const keys = if (hybrid_keys) |*v| v else return false;
    defer {
        std.crypto.secureZero(u8, std.mem.asBytes(keys));
        hybrid_keys = null;
    }
    ssh_session = .{ .session_id = keys.exchange_hash };
    wire.enableEncryption(keys) catch return false;
    return true;
}
const hybrid_driver_mod = @import("ssh_hybrid_driver.zig");
var hybrid_driver: ?hybrid_driver_mod.Driver = null;
var hybrid_connection: ?@import("ssh_hybrid_connection.zig").Connection = null;
var hybrid_worker_ciphertext: ?[1088]u8 = null;
fn hybridWorkerSubmit(_: ?*anyopaque, token: handoff_module.Token, ct: *const [1088]u8) bool {
    if (token.epoch != handoff_token.epoch or token.request != handoff_token.request or hybrid_worker_ciphertext != null) return false;
    hybrid_worker_ciphertext = ct.*;
    return true;
}
export fn probe_hybrid_driver_begin(cookie: *const [16]u8, seed: *const [64]u8, secret: *const [32]u8, pin: *const [32]u8, banner: [*]const u8, len: usize, now: u64, deadline: u64) bool {
    hybrid = hybrid_probe.Probe.init(seed.*, secret.*, pin.*, banner[0..len]) catch return false;
    const h = if (hybrid) |*value| value else return false;
    hybrid_driver = hybrid_driver_mod.Driver.init(h.protocol, cookie.*, handoff_token, now, deadline) catch {
        h.deinit();
        return false;
    };
    return true;
}
export fn probe_hybrid_driver_step(now: u64, padding: *const [32]u8) isize {
    const d = if (hybrid_driver) |*value| value else return -1;
    const done = d.step(&wire, now, padding, null, &hybridWorkerSubmit) catch return -1;
    if (!done) return 0;
    ssh_session = .{ .session_id = d.session_id orelse return -1 };
    return 1;
}
export fn probe_hybrid_connection_begin(cookie: *const [16]u8, seed: *const [64]u8, secret: *const [32]u8, pin: *const [32]u8, now: u64, deadline: u64) bool {
    hybrid = hybrid_probe.Probe.init(seed.*, secret.*, pin.*, "SSH-2.0-pending") catch return false;
    const h = if (hybrid) |*value| value else return false;
    hybrid_connection = @import("ssh_hybrid_connection.zig").Connection.init(1, handoff_token, now, deadline, secret.*, pin.*, cookie.*, h.protocol.client[0..1184].*) catch {
        h.deinit();
        return false;
    };
    return true;
}
export fn probe_hybrid_connection_poll(now: u64, padding: *const [32]u8) isize {
    const c = if (hybrid_connection) |*value| value else return -1;
    const done = c.poll(&wire, &pump, probeIo(), 1, now, padding, null, &hybridWorkerSubmit) catch return -1;
    if (!done) return 0;
    ssh_session = .{ .session_id = c.driver.session_id orelse return -1 };
    return 1;
}
export fn probe_hybrid_worker_pending() bool {
    return hybrid_worker_ciphertext != null;
}
export fn probe_hybrid_worker_complete(now: u64) isize {
    const h = if (hybrid) |*value| value else return -1;
    const ct = if (hybrid_worker_ciphertext) |*value| value else return -1;
    var secret = h.decaps(ct) catch {
        std.crypto.secureZero(u8, ct);
        hybrid_worker_ciphertext = null;
        if (hybrid_connection) |*c| c.abort(&wire, &pump) else if (hybrid_driver) |*d| d.abort(&wire);
        h.deinit();
        return -1;
    };
    defer std.crypto.secureZero(u8, &secret);
    std.crypto.secureZero(u8, ct);
    hybrid_worker_ciphertext = null;
    h.deinit();
    if (hybrid_connection) |*c| {
        c.complete(&wire, &pump, handoff_token, now, &secret) catch |err| return if (err == error.HostProofFailed) -2 else -1;
    } else if (hybrid_driver) |*d| {
        d.complete(&wire, handoff_token, now, &secret) catch |err| return if (err == error.HostProofFailed) -2 else -1;
    } else return -1;
    return 1;
}
var driver: ?kex_driver.Driver = null;
var ident = identification.Exchange{ .epoch = 1 };
var ssh_client: ?client.Client = null;
var tty: terminal.Terminal = .{};
fn probeIo() socket_pump.Io {
    return .{ .context = null, .read = socketRead, .write = socketWrite };
}
export fn probe_terminal_poll(now: u64, random: *const [32]u8) isize {
    const value = if (ssh_client) |*v| v else return -1;
    return if (tty.poll(value, &wire, &pump, probeIo(), 1, now, random) catch return -1) 1 else 0;
}
export fn probe_terminal_read(now: u64, random: *const [32]u8, dst: [*]u8, len: usize) isize {
    const value = if (ssh_client) |*v| v else return -1;
    return @intCast(tty.read(value, &wire, &pump, probeIo(), 1, now, random, dst[0..len]) catch return -1);
}
export fn probe_terminal_write(now: u64, random: *const [32]u8, src: [*]const u8, len: usize) isize {
    const value = if (ssh_client) |*v| v else return -1;
    return @intCast(tty.write(value, &wire, &pump, probeIo(), 1, now, src[0..len], random) catch return -1);
}

fn activeSession() ?*session.Session {
    if (ssh_client) |*v| if (v.session) |*s| return s;
    if (ssh_session) |*s| return s;
    return null;
}
export fn probe_client_begin(cookie: *const [16]u8, secret: *const [32]u8, pin: *const [32]u8, now: u64, deadline: u64) void {
    ssh_client = client.Client.init(1, now, deadline, secret.*, pin.*, cookie.*, 80, 24);
}
export fn probe_client_poll(now: u64, random: *const [32]u8, user: [*]const u8, len: usize, seed: *const [32]u8) isize {
    const value = if (ssh_client) |*v| v else return -1;
    const done = value.poll(&wire, &pump, .{ .context = null, .read = socketRead, .write = socketWrite }, 1, now, random, user[0..len], seed.*) catch |err| return if (err == error.HostKeyMismatch) -2 else if (err == error.AuthenticationFailed) -3 else -1;
    return if (done) 1 else 0;
}

var conn: ?connection.Connection = null;
export fn probe_connection_begin(cookie: *const [16]u8, secret: *const [32]u8, pin: *const [32]u8, now: u64, deadline: u64) void {
    conn = connection.Connection.init(1, now, deadline, secret.*, pin.*, cookie.*);
}
export fn probe_connection_poll(now: u64, random: *const [32]u8) isize {
    const value = if (conn) |*v| v else return -1;
    const done = value.poll(&wire, &pump, .{ .context = null, .read = socketRead, .write = socketWrite }, 1, now, random) catch |err| return if (err == error.HostKeyMismatch) -2 else -1;
    if (!done) return 0;
    if (ssh_session == null) ssh_session = .{ .session_id = value.driver.session_id orelse return -1 };
    return 1;
}

export fn probe_ident_poll() isize {
    return if (ident.poll(.{ .context = null, .read = socketRead, .write = socketWrite }, 1) catch return -1) 1 else 0;
}
export fn probe_ident_banner(out: [*]u8, cap: usize) usize {
    const banner = ident.banner() orelse return 0;
    if (banner.len > cap) return 0;
    @memcpy(out[0..banner.len], banner);
    return banner.len;
}

export fn probe_driver_begin(cookie: *const [16]u8, secret: *const [32]u8, pin: *const [32]u8, banner: [*]const u8, banner_len: usize) bool {
    driver = .{ .handshake = .{ .secret = secret.*, .pin = pin.* }, .cookie = cookie.* };
    const value = if (driver) |*v| v else return false;
    value.begin(banner[0..banner_len]) catch return false;
    return true;
}
export fn probe_driver_step(random: *const [32]u8) isize {
    const value = if (driver) |*v| v else return -1;
    const done = value.step(&wire, random) catch |err| return if (err == error.HostKeyMismatch) -2 else -1;
    if (!done) return 0;
    if (ssh_session == null) ssh_session = .{ .session_id = value.session_id orelse return -1 };
    return 1;
}

export fn probe_init(out: [*]u8, cap: usize, cookie: *const [16]u8, secret: *const [32]u8, pin: *const [32]u8, banner: [*]const u8, banner_len: usize) usize {
    hs = .{ .secret = secret.*, .pin = pin.* };
    const h = if (hs) |*v| v else return 0;
    h.serverBanner(banner[0..banner_len]) catch return 0;
    const result = h.clientInit(out[0..cap], cookie.*) catch return 0;
    return result.len;
}
export fn probe_server_init(input: [*]const u8, len: usize, out: [*]u8, cap: usize) usize {
    const h = if (hs) |*v| v else return 0;
    h.serverInit(input[0..len]) catch return 0;
    const payload = h.ecdhInit(out[0..cap]) catch return 0;
    return payload.len;
}
export fn probe_reply(input: [*]const u8, len: usize) bool {
    const h = if (hs) |*v| v else return false;
    var wrong = h.*;
    wrong.pin[0] ^= 1;
    if (wrong.serverReply(input[0..len])) |_| return false else |err| if (err != error.HostKeyMismatch) return false;
    h.serverReply(input[0..len]) catch return false;
    return true;
}
export fn probe_newkeys(out: [*]u8, cap: usize) usize {
    const h = if (hs) |*v| v else return 0;
    const payload = h.newKeys(out[0..cap]) catch return 0;
    return payload.len;
}
export fn probe_activate(input: [*]const u8, len: usize) bool {
    const h = if (hs) |*v| v else return false;
    h.receiveNewKeys(input[0..len]) catch return false;
    var keys = h.takeKeys() catch return false;
    defer std.crypto.secureZero(u8, std.mem.asBytes(&keys));
    ssh_session = .{ .session_id = keys.exchange_hash };
    wire.enableEncryption(&keys) catch return false;
    return true;
}
export fn probe_pack(payload: [*]const u8, len: usize, random: *const [32]u8) bool {
    wire.prepare(payload[0..len], random) catch return false;
    return true;
}
export fn probe_payload(out: [*]u8, cap: usize) usize {
    const payload = wire.rx.payload() orelse return 0;
    if (payload.len > cap) return 0;
    @memcpy(out[0..payload.len], payload);
    return payload.len;
}
export fn probe_release() void {
    wire.rx.release();
}
export fn probe_auth_public(seed: *const [32]u8, out: *[32]u8) bool {
    var pair = std.crypto.sign.Ed25519.KeyPair.generateDeterministic(seed.*) catch return false;
    defer std.crypto.secureZero(u8, std.mem.asBytes(&pair));
    out.* = pair.public_key.toBytes();
    return true;
}
export fn probe_auth(user: [*]const u8, len: usize, seed: *const [32]u8, out: [*]u8, cap: usize) usize {
    const s = activeSession() orelse return 0;
    const payload = s.authenticate(out[0..cap], user[0..len], seed.*) catch return 0;
    return payload.len;
}
export fn probe_service(out: [*]u8, cap: usize) usize {
    const s = activeSession() orelse return 0;
    const payload = s.service(out[0..cap]) catch return 0;
    return payload.len;
}
export fn probe_channel_action(action: u8, data: [*]const u8, len: usize, out: [*]u8, cap: usize) usize {
    const s = activeSession() orelse return 0;
    const result = switch (action) {
        0 => s.open(out[0..cap]),
        1 => s.pty(out[0..cap], 80, 24),
        2 => s.start(out[0..cap], data[0..len]),
        3 => s.data(out[0..cap], data[0..len]),
        4 => s.eof(out[0..cap]),
        5 => s.close(out[0..cap]),
        else => return 0,
    } catch return 0;
    return result.len;
}
export fn probe_channel_receive(input: [*]const u8, len: usize, output: [*]u8, capacity: usize) isize {
    const s = activeSession() orelse return -1;
    const top = s.receive(input[0..len]) catch return -1;
    const event = switch (top) {
        .service_ready => return 7,
        .authenticated => return 8,
        .banner => return 9,
        .channel => |value| value,
    };
    const bytes = switch (event) {
        .opened => return 1,
        .pty_ready => return 2,
        .started => return 3,
        .window, .ignored, .exit_status => return 4,
        .eof => return 5,
        .closed => return 6,
        .data, .extended => |v| v,
    };
    if (bytes.len > capacity) return -1;
    @memcpy(output[0..bytes.len], bytes);
    return @intCast(bytes.len + 100);
}
