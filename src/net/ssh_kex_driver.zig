//! First SSH key exchange over an already exchanged identification line.
//! The caller owns socket pumping and must supply fresh cryptographic padding
//! for every step that can enqueue a packet. One bounded transition per call.
const std = @import("std");
const handshake = @import("ssh_handshake.zig");
const transport = @import("ssh_transport.zig");
pub const Error = handshake.Error || transport.Error || error{InvalidState};
pub const Driver = struct {
    const State = enum { initial, send_init, server_init, server_reply, newkeys, done, failed };
    state: State = .initial,
    handshake: handshake.Handshake,
    cookie: [16]u8,
    session_id: ?[32]u8 = null,

    pub fn begin(self: *Driver, banner: []const u8) Error!void {
        if (self.state != .initial) return error.InvalidState;
        self.handshake.serverBanner(banner) catch |err| return self.fail(null, err);
        self.state = .send_init;
    }
    /// The caller must poll the transport's socket pump between steps. A
    /// pending TX is never replaced and a received packet remains borrowed
    /// until this method processes it. Returns true only once keys are active.
    pub fn step(self: *Driver, wire: *transport.Transport, padding: *const [32]u8) Error!bool {
        return self.advance(wire, padding) catch |err| return self.fail(wire, err);
    }
    fn advance(self: *Driver, wire: *transport.Transport, padding: *const [32]u8) Error!bool {
        if (self.state == .failed or self.state == .initial) return error.InvalidState;
        if (wire.failed) return error.Failed;
        if (self.state == .done) return true;
        if (wire.pending().len != 0) return false;
        var out: [512]u8 = undefined;
        switch (self.state) {
            .send_init => {
                const packet = try self.handshake.clientInit(&out, self.cookie);
                try wire.prepare(packet, padding);
                std.crypto.secureZero(u8, &self.cookie);
                self.state = .server_init;
            },
            .server_init => {
                const packet = wire.rx.payload() orelse return false;
                try self.handshake.serverInit(packet);
                wire.rx.release();
                const ecdh = try self.handshake.ecdhInit(&out);
                try wire.prepare(ecdh, padding);
                self.state = .server_reply;
            },
            .server_reply => {
                const packet = wire.rx.payload() orelse return false;
                try self.handshake.serverReply(packet);
                wire.rx.release();
                const newkeys = try self.handshake.newKeys(&out);
                try wire.prepare(newkeys, padding);
                self.state = .newkeys;
            },
            .newkeys => {
                const packet = wire.rx.payload() orelse return false;
                try self.handshake.receiveNewKeys(packet);
                wire.rx.release();
                var keys = try self.handshake.takeKeys();
                defer std.crypto.secureZero(u8, std.mem.asBytes(&keys));
                try wire.enableEncryption(&keys);
                self.session_id = keys.exchange_hash;
                self.state = .done;
                return true;
            },
            else => unreachable,
        }
        return false;
    }
    pub fn deinit(self: *Driver, wire: *transport.Transport) void {
        self.handshake.deinit();
        std.crypto.secureZero(u8, &self.cookie);
        if (self.session_id) |*id| std.crypto.secureZero(u8, id);
        self.session_id = null;
        self.state = .failed;
        wire.abort();
    }
    fn fail(self: *Driver, wire: ?*transport.Transport, err: Error) Error {
        self.handshake.deinit();
        std.crypto.secureZero(u8, &self.cookie);
        if (self.session_id) |*id| std.crypto.secureZero(u8, id);
        self.session_id = null;
        self.state = .failed;
        if (wire) |value| value.abort();
        return err;
    }
};

test "driver preserves pending TX and aborts on malformed server KEX" {
    var driver = Driver{ .handshake = .{ .secret = @splat(1), .pin = @splat(2) }, .cookie = @splat(3) };
    var wire: transport.Transport = .{};
    const padding: [32]u8 = @splat(4);
    try driver.begin("SSH-2.0-test");
    try std.testing.expect(!(try driver.step(&wire, &padding)));
    const pending = wire.pending().len;
    try std.testing.expect(pending != 0);
    try std.testing.expect(!(try driver.step(&wire, &padding)));
    try std.testing.expectEqual(pending, wire.pending().len);
    try wire.consume(pending);
    var peer: transport.Transport = .{};
    try peer.prepare(&.{20}, &padding);
    _ = try wire.feed(peer.pending());
    try std.testing.expectError(error.Malformed, driver.step(&wire, &padding));
    try std.testing.expect(wire.failed);
    try std.testing.expect(std.mem.allEqual(u8, &driver.handshake.secret, 0));
    try std.testing.expect(std.mem.allEqual(u8, &driver.cookie, 0));
    try std.testing.expectError(error.InvalidState, driver.step(&wire, &padding));
}

test "driver clears its secret when transport is aborted" {
    var driver = Driver{ .handshake = .{ .secret = @splat(1), .pin = @splat(2) }, .cookie = @splat(3) };
    var wire: transport.Transport = .{};
    try driver.begin("SSH-2.0-test");
    wire.abort();
    try std.testing.expectError(error.Failed, driver.step(&wire, &@as([32]u8, @splat(4))));
    try std.testing.expect(std.mem.allEqual(u8, &driver.handshake.secret, 0));
    try std.testing.expect(std.mem.allEqual(u8, &driver.cookie, 0));
}
