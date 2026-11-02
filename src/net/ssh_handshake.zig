//! First SSH key-exchange sequencing, independent of socket and packet I/O.
//! Caller supplies cryptographically random secret and cookie, a trusted pin,
//! and a complete server identification line without CR/LF.
const std = @import("std");
const ssh = @import("ssh.zig");
const kex = @import("ssh_kex.zig");
pub const Error = kex.Error || error{ InvalidState, InvalidBanner };
pub const client_banner = "SSH-2.0-nihos_1.0";
pub const Handshake = struct {
    const State = enum { initial, banner, init_sent, server_init, ecdh_sent, verified, done, failed };
    state: State = .initial,
    secret: [32]u8,
    pin: [32]u8,
    server_banner: [253]u8 = @splat(0),
    banner_len: usize = 0,
    client_init: [512]u8 = @splat(0),
    client_len: usize = 0,
    server_init: [8192]u8 = @splat(0),
    server_len: usize = 0,
    keys: ?kex.Keys = null,
    sent_newkeys: bool = false,
    received_newkeys: bool = false,

    pub fn serverBanner(self: *Handshake, banner: []const u8) Error!void {
        if (self.state != .initial) return error.InvalidState;
        if (banner.len < 9 or banner.len > self.server_banner.len or !std.mem.startsWith(u8, banner, "SSH-2.0-")) return self.fail(error.InvalidBanner);
        for (banner) |b| if (b < 32 or b > 126) return self.fail(error.InvalidBanner);
        @memcpy(self.server_banner[0..banner.len], banner);
        self.banner_len = banner.len;
        self.state = .banner;
    }
    pub fn clientInit(self: *Handshake, out: []u8, cookie: [16]u8) Error![]const u8 {
        if (self.state != .banner) return error.InvalidState;
        const payload = try kex.clientInit(&self.client_init, cookie);
        if (out.len < payload.len) return error.BufferTooSmall;
        self.client_len = payload.len;
        @memcpy(out[0..payload.len], payload);
        self.state = .init_sent;
        return out[0..payload.len];
    }
    pub fn serverInit(self: *Handshake, payload: []const u8) Error!void {
        if (self.state != .init_sent) return error.InvalidState;
        if (payload.len > self.server_init.len) return self.fail(error.BufferTooSmall);
        kex.validateServerInit(payload) catch |err| return self.fail(err);
        @memcpy(self.server_init[0..payload.len], payload);
        self.server_len = payload.len;
        self.state = .server_init;
    }
    pub fn ecdhInit(self: *Handshake, out: []u8) Error![]const u8 {
        if (self.state != .server_init) return error.InvalidState;
        if (out.len < 37) return error.BufferTooSmall;
        out[0] = ssh.SSH_MSG_KEX_ECDH_INIT;
        std.mem.writeInt(u32, out[1..5], 32, .big);
        out[5..37].* = std.crypto.dh.X25519.recoverPublicKey(self.secret);
        self.state = .ecdh_sent;
        return out[0..37];
    }
    pub fn serverReply(self: *Handshake, payload: []const u8) Error!void {
        if (self.state != .ecdh_sent) return error.InvalidState;
        const keys = kex.finish(client_banner, self.server_banner[0..self.banner_len], self.client_init[0..self.client_len], self.server_init[0..self.server_len], self.secret, self.pin, payload) catch |err| return self.fail(err);
        std.crypto.secureZero(u8, &self.secret);
        self.keys = keys;
        self.state = .verified;
    }
    /// Caller must send this packet under old keys before switching TX keys.
    pub fn newKeys(self: *Handshake, out: []u8) Error![]const u8 {
        if (self.state != .verified or self.sent_newkeys) return error.InvalidState;
        if (out.len == 0) return error.BufferTooSmall;
        out[0] = ssh.SSH_MSG_NEWKEYS;
        self.sent_newkeys = true;
        return out[0..1];
    }
    /// Caller must decode this packet under old keys before switching RX keys.
    pub fn receiveNewKeys(self: *Handshake, payload: []const u8) Error!void {
        if (self.state != .verified or self.received_newkeys) return error.InvalidState;
        if (!std.mem.eql(u8, payload, &.{ssh.SSH_MSG_NEWKEYS})) return self.fail(error.Malformed);
        self.received_newkeys = true;
    }
    /// Transfers the verified keys only after both NEWKEYS transitions.
    pub fn takeKeys(self: *Handshake) Error!kex.Keys {
        if (self.state != .verified or !self.sent_newkeys or !self.received_newkeys) return error.InvalidState;
        const keys = self.keys orelse return error.InvalidState;
        if (self.keys) |*value| std.crypto.secureZero(u8, std.mem.asBytes(value));
        self.keys = null;
        self.state = .done;
        return keys;
    }
    pub fn deinit(self: *Handshake) void {
        std.crypto.secureZero(u8, &self.secret);
        if (self.keys) |*value| std.crypto.secureZero(u8, std.mem.asBytes(value));
        self.keys = null;
        self.state = .failed;
    }
    fn fail(self: *Handshake, err: Error) Error {
        self.deinit();
        return err;
    }
};

test "handshake prevents out-of-order and invalid server progress" {
    var h = Handshake{ .secret = @splat(1), .pin = @splat(2) };
    var out: [512]u8 = undefined;
    try std.testing.expectError(error.InvalidState, h.takeKeys());
    try std.testing.expectError(error.InvalidState, h.ecdhInit(&out));
    try h.serverBanner("SSH-2.0-test");
    _ = try h.clientInit(&out, @splat(3));
    try std.testing.expectError(error.Malformed, h.serverInit(&.{20}));
    try std.testing.expectError(error.InvalidState, h.ecdhInit(&out));
    try std.testing.expect(std.mem.allEqual(u8, &h.secret, 0));
}
