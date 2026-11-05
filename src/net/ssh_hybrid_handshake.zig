//! Hybrid SSH packet negotiation and host proof; caller supplies KEM results.
//! The transport, worker lifecycle, entropy, and trusted pin are caller-owned.
const std = @import("std");
const ssh = @import("ssh.zig");
const kex = @import("ssh_kex.zig");
const proof = @import("ssh_host_key.zig");
const hybrid = @import("ssh_hybrid_transcript.zig");
const reply = @import("ssh_hybrid_reply.zig");
const X = std.crypto.dh.X25519;
const names = [_][]const u8{ "mlkem768x25519-sha256", "ssh-ed25519", "aes128-ctr", "aes128-ctr", "hmac-sha2-256", "hmac-sha2-256", "none", "none", "", "" };
const Error = error{ Malformed, Unsupported, TooSmall };
const Reader = struct {
    data: []const u8,
    pos: usize = 0,
    fn take(self: *Reader, n: usize) Error![]const u8 {
        if (n > self.data.len - self.pos) return error.Malformed;
        const value = self.data[self.pos..][0..n];
        self.pos += n;
        return value;
    }
    fn string(self: *Reader) Error![]const u8 {
        const n = std.mem.readInt(u32, (try self.take(4))[0..4], .big);
        return self.take(n);
    }
};
fn put(out: []u8, pos: *usize, value: []const u8) Error!void {
    if (pos.* > out.len or out.len - pos.* < 4 or value.len > out.len - pos.* - 4) return error.TooSmall;
    std.mem.writeInt(u32, out[pos.*..][0..4], @intCast(value.len), .big);
    pos.* += 4;
    @memcpy(out[pos.*..][0..value.len], value);
    pos.* += value.len;
}
pub const Handshake = struct {
    secret: [32]u8,
    pin: [32]u8,
    banner: [253]u8 = @splat(0),
    banner_len: usize = 0,
    client_init: [512]u8 = @splat(0),
    client_len: usize = 0,
    server_init: [8192]u8 = @splat(0),
    server_len: usize = 0,
    client: [hybrid.client_len]u8 = undefined,
    pub fn init(secret: [32]u8, pin: [32]u8, banner: []const u8, public: *const [1184]u8) !Handshake {
        var self: Handshake = undefined;
        try self.initInPlace(secret, pin, banner, public);
        return self;
    }
    /// Caller provides exclusive fresh or securely deinitialized storage.
    pub fn initInPlace(self: *Handshake, secret: [32]u8, pin: [32]u8, banner: []const u8, public: *const [1184]u8) !void {
        if (banner.len < 9 or banner.len > 253 or !std.mem.startsWith(u8, banner, "SSH-2.0-")) return error.Malformed;
        for (banner) |byte| if (byte < 32 or byte > 126) return error.Malformed;
        self.secret = secret;
        self.pin = pin;
        @memset(&self.banner, 0);
        @memset(&self.client_init, 0);
        @memset(&self.server_init, 0);
        self.client_len = 0;
        self.server_len = 0;
        @memcpy(self.banner[0..banner.len], banner);
        self.banner_len = banner.len;
        self.client[0..1184].* = public.*;
        self.client[1184..].* = X.recoverPublicKey(secret);
    }
    pub fn start(self: *Handshake, cookie: [16]u8, out: []u8) ![]const u8 {
        self.client_init[0] = 20;
        self.client_init[1..17].* = cookie;
        var pos: usize = 17;
        for (names) |name| try put(&self.client_init, &pos, name);
        @memset(self.client_init[pos..][0..5], 0);
        pos += 5;
        if (out.len < pos) return error.TooSmall;
        self.client_len = pos;
        @memcpy(out[0..pos], self.client_init[0..pos]);
        return out[0..pos];
    }
    pub fn serverInit(self: *Handshake, input: []const u8, out: []u8) ![]const u8 {
        if (input.len > self.server_init.len) return error.TooSmall;
        var reader = Reader{ .data = input };
        if ((try reader.take(1))[0] != 20) return error.Malformed;
        _ = try reader.take(16);
        for (names, 0..) |name, i| {
            const list = try reader.string();
            if (i < 8) {
                var it = std.mem.splitScalar(u8, list, ',');
                var found = false;
                while (it.next()) |item| if (std.mem.eql(u8, item, name)) {
                    found = true;
                };
                if (!found) return error.Unsupported;
            }
        }
        const tail = try reader.take(5);
        if (!std.mem.allEqual(u8, tail, 0) or reader.pos != input.len) return error.Unsupported;
        @memcpy(self.server_init[0..input.len], input);
        self.server_len = input.len;
        if (out.len < 5 + self.client.len) return error.TooSmall;
        out[0] = 30;
        var pos: usize = 1;
        try put(out, &pos, &self.client);
        return out[0..pos];
    }
    pub fn finishWithPq(self: *Handshake, input: []const u8, pq: *const [32]u8) !kex.Keys {
        const parsed = try reply.parse(input);
        const host = parsed.host;
        const server = parsed.server;
        const sig = parsed.signature;
        var classical = try X.scalarmult(self.secret, server[1088..][0..32].*);
        defer std.crypto.secureZero(u8, &classical);
        var key = try hybrid.combine(pq.*, classical);
        defer std.crypto.secureZero(u8, &key);
        const h = try hybrid.exchangeHash("SSH-2.0-nihos_1.0", self.banner[0..self.banner_len], self.client_init[0..self.client_len], self.server_init[0..self.server_len], host, &self.client, server, key);
        try proof.verify(host, sig, h, self.pin);
        var encoded: [36]u8 = undefined;
        defer std.crypto.secureZero(u8, &encoded);
        std.mem.writeInt(u32, encoded[0..4], 32, .big);
        encoded[4..].* = key;
        var values: [6][32]u8 = undefined;
        defer std.crypto.secureZero(u8, std.mem.asBytes(&values));
        for (&values, 0..) |*v, i| ssh.deriveKey(&encoded, h, h, @as(u8, 'A') + @as(u8, @intCast(i)), v);
        return .{ .exchange_hash = h, .iv_client = values[0][0..16].*, .iv_server = values[1][0..16].*, .key_client = values[2][0..16].*, .key_server = values[3][0..16].*, .mac_client = values[4], .mac_server = values[5] };
    }
    pub fn deinit(self: *Handshake) void {
        std.crypto.secureZero(u8, std.mem.asBytes(self));
    }
};

test "shared handshake verifies worker secret against fixed transcript and pin" {
    const vector = @import("ssh_hybrid_vector.zig");
    const data = @embedFile("ssh_hybrid_public_vector.bin");
    const v: *const vector.Vector = @ptrCast(data.ptr);
    const keypair = try std.crypto.kem.ml_kem.MLKem768.KeyPair.generateDeterministic(v.seed);
    var pq = try keypair.secret_key.decaps(v.server[0..1088]);
    defer std.crypto.secureZero(u8, &pq);
    var h = try Handshake.init(v.xsecret, v.pin, vector.server_banner, &v.pk);
    defer h.deinit();
    @memcpy(h.client_init[0..vector.client_kex.len], vector.client_kex);
    h.client_len = vector.client_kex.len;
    @memcpy(h.server_init[0..vector.server_kex.len], vector.server_kex);
    h.server_len = vector.server_kex.len;
    var message: [1 + 4 + 51 + 4 + 1120 + 4 + 83]u8 = undefined;
    message[0] = 31;
    var pos: usize = 1;
    for ([_][]const u8{ &v.host, &v.server, &v.signature }) |part| try put(&message, &pos, part);
    var keys = try h.finishWithPq(&message, &pq);
    defer std.crypto.secureZero(u8, std.mem.asBytes(&keys));
    try std.testing.expectEqualSlices(u8, &v.hash, &keys.exchange_hash);
    h.pin[0] ^= 1;
    try std.testing.expectError(error.HostKeyMismatch, h.finishWithPq(&message, &pq));
    h.pin[0] ^= 1;
    message[message.len - 1] ^= 1;
    try std.testing.expectError(error.InvalidSignature, h.finishWithPq(&message, &pq));
}
