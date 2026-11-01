//! Host-only C ABI used by the local OpenSSH interoperability probe.
const std = @import("std");
const handshake = @import("ssh_handshake.zig");
const ssh = @import("ssh.zig");
const stream = @import("ssh_stream.zig");
const session = @import("ssh_session.zig");
var tx: ?ssh.Aes128Ctr = null;
var tx_mac: [32]u8 = @splat(0);
var rx: stream.Decoder = .{};
var ssh_session: ?session.Session = null;
var hs: ?handshake.Handshake = null;

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
export fn probe_activate(input: [*]const u8, len: usize, rx_sequence: u32) bool {
    const h = if (hs) |*v| v else return false;
    h.receiveNewKeys(input[0..len]) catch return false;
    var keys = h.takeKeys() catch return false;
    defer std.crypto.secureZero(u8, std.mem.asBytes(&keys));
    ssh_session = .{ .session_id = keys.exchange_hash };
    tx = ssh.Aes128Ctr.init(keys.key_client, keys.iv_client);
    tx_mac = keys.mac_client;
    rx = .{};
    rx.sequence = rx_sequence;
    rx.enableEncryption(ssh.Aes128Ctr.init(keys.key_server, keys.iv_server), keys.mac_server) catch return false;
    return true;
}
export fn probe_pack(payload: [*]const u8, len: usize, seq: u32, random: *const [32]u8, out: [*]u8, cap: usize) usize {
    const cipher = if (tx) |*v| v else return 0;
    return ssh.packPacket(payload[0..len], seq, true, cipher, &tx_mac, random, out[0..cap]) catch 0;
}
export fn probe_feed(input: [*]const u8, len: usize) isize {
    return @intCast(rx.feed(input[0..len]) catch return -1);
}
export fn probe_payload(out: [*]u8, cap: usize) usize {
    const payload = rx.payload() orelse return 0;
    if (payload.len > cap) return 0;
    @memcpy(out[0..payload.len], payload);
    return payload.len;
}
export fn probe_release() void {
    rx.release();
}
export fn probe_auth_public(seed: *const [32]u8, out: *[32]u8) bool {
    var pair = std.crypto.sign.Ed25519.KeyPair.generateDeterministic(seed.*) catch return false;
    defer std.crypto.secureZero(u8, std.mem.asBytes(&pair));
    out.* = pair.public_key.toBytes();
    return true;
}
export fn probe_auth(user: [*]const u8, len: usize, seed: *const [32]u8, out: [*]u8, cap: usize) usize {
    const s = if (ssh_session) |*v| v else return 0;
    const payload = s.authenticate(out[0..cap], user[0..len], seed.*) catch return 0;
    return payload.len;
}
export fn probe_service(out: [*]u8, cap: usize) usize {
    const s = if (ssh_session) |*v| v else return 0;
    const payload = s.service(out[0..cap]) catch return 0;
    return payload.len;
}
export fn probe_channel_action(action: u8, data: [*]const u8, len: usize, out: [*]u8, cap: usize) usize {
    const s = if (ssh_session) |*v| v else return 0;
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
    const s = if (ssh_session) |*v| v else return -1;
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
