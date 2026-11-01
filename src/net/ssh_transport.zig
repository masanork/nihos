//! Bounded single-owner SSH packet transport. The adapter retains unsent bytes
//! and acknowledges only actual writes. Any ambiguous write requires abort.
const std = @import("std");
const ssh = @import("ssh.zig");
const stream = @import("ssh_stream.zig");
pub const Error = stream.Error || error{ Busy, InvalidWrite, RekeyRequired };
pub const Transport = struct {
    rx: stream.Decoder = .{},
    tx: [ssh.SSH_MAX_PKT + 4 + 32]u8 = undefined,
    tx_len: usize = 0,
    tx_offset: usize = 0,
    tx_sequence: u32 = 0,
    cipher: ?ssh.Aes128Ctr = null,
    mac: ?[32]u8 = null,
    failed: bool = false,

    /// Exactly one packet may be outstanding. Random padding must be supplied
    /// by the platform's cryptographic random source, even before NEWKEYS.
    pub fn prepare(self: *Transport, payload: []const u8, random: []const u8) Error!void {
        if (self.failed) return error.Failed;
        if (self.tx_len != 0) return error.Busy;
        // Do not allow a sequence number to wrap without a rekey implementation.
        if (self.tx_sequence == std.math.maxInt(u32)) return error.RekeyRequired;
        const cipher = if (self.cipher) |*v| v else null;
        const mac = if (self.mac) |*v| v else null;
        const n = try ssh.packPacket(payload, self.tx_sequence, cipher != null, cipher, mac, random, &self.tx);
        self.tx_len = n;
        self.tx_offset = 0;
        self.tx_sequence += 1;
    }
    pub fn pending(self: *const Transport) []const u8 {
        return self.tx[self.tx_offset..self.tx_len];
    }
    pub fn consume(self: *Transport, count: usize) Error!void {
        if (self.failed) return error.Failed;
        if (count > self.tx_len - self.tx_offset) {
            self.abort();
            return error.InvalidWrite;
        }
        self.tx_offset += count;
        if (self.tx_offset == self.tx_len) {
            std.crypto.secureZero(u8, self.tx[0..self.tx_len]);
            self.tx_offset = 0;
            self.tx_len = 0;
        }
    }
    /// Invoke only after local NEWKEYS was fully written and remote NEWKEYS
    /// was received and released. No in-flight data may cross this boundary.
    pub fn enableEncryption(self: *Transport, keys: *const @import("ssh_kex.zig").Keys) Error!void {
        if (self.failed) return error.Failed;
        if (self.tx_len != 0 or self.cipher != null) return error.Busy;
        try self.rx.enableEncryption(ssh.Aes128Ctr.init(keys.key_server, keys.iv_server), keys.mac_server);
        self.cipher = ssh.Aes128Ctr.init(keys.key_client, keys.iv_client);
        self.mac = keys.mac_client;
    }
    pub fn feed(self: *Transport, bytes: []const u8) Error!usize {
        if (self.failed) return error.Failed;
        // Reject sequence exhaustion rather than let the stream counter wrap.
        if (self.rx.sequence == std.math.maxInt(u32)) {
            self.abort();
            return error.RekeyRequired;
        }
        return self.rx.feed(bytes) catch |err| {
            self.abort();
            return err;
        };
    }
    pub fn abort(self: *Transport) void {
        self.failed = true;
        std.crypto.secureZero(u8, &self.tx);
        std.crypto.secureZero(u8, &self.rx.buffer);
        if (self.cipher) |*value| std.crypto.secureZero(u8, std.mem.asBytes(value));
        if (self.mac) |*value| std.crypto.secureZero(u8, value);
        if (self.rx.cipher) |*value| std.crypto.secureZero(u8, std.mem.asBytes(value));
        if (self.rx.mac_key) |*value| std.crypto.secureZero(u8, value);
        self.tx_len = 0;
        self.tx_offset = 0;
    }
};

test "partial writes retain bytes and prevent overlapping packets" {
    var t: Transport = .{};
    try t.prepare("hello", &@as([32]u8, @splat(1)));
    const n = t.pending().len;
    try t.consume(3);
    try std.testing.expectEqual(n - 3, t.pending().len);
    try std.testing.expectError(error.Busy, t.prepare("second", &@as([32]u8, @splat(1))));
    try t.consume(n - 3);
    try std.testing.expectEqual(@as(usize, 0), t.pending().len);
    try t.prepare("second", &@as([32]u8, @splat(1)));
    try std.testing.expectEqual(@as(u32, 2), t.tx_sequence);
    try std.testing.expectError(error.InvalidWrite, t.consume(t.pending().len + 1));
    try std.testing.expectError(error.Failed, t.prepare("third", &@as([32]u8, @splat(1))));
}
