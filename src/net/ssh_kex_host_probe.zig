//! Host-only C ABI used by the local OpenSSH interoperability probe.
const std = @import("std");
const kex = @import("ssh_kex.zig");
const ssh = @import("ssh.zig");
const stream = @import("ssh_stream.zig");
var tx: ?ssh.Aes128Ctr = null;
var tx_mac: [32]u8 = @splat(0);
var rx: stream.Decoder = .{};

export fn probe_init(out: [*]u8, cap: usize, cookie: *const [16]u8) usize {
    const result = kex.clientInit(out[0..cap], cookie.*) catch return 0;
    return result.len;
}
export fn probe_public(secret: *const [32]u8, out: *[32]u8) void {
    out.* = std.crypto.dh.X25519.recoverPublicKey(secret.*);
}
export fn probe_finish(cb: [*]const u8, cb_len: usize, sb: [*]const u8, sb_len: usize, ci: [*]const u8, ci_len: usize, si: [*]const u8, si_len: usize, secret: *const [32]u8, pin: *const [32]u8, reply: [*]const u8, reply_len: usize, rx_sequence: u32) bool {
    const keys = kex.finish(cb[0..cb_len], sb[0..sb_len], ci[0..ci_len], si[0..si_len], secret.*, pin.*, reply[0..reply_len]) catch return false;
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
