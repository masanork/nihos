//! Bounded identification and first key exchange on one established socket.
//! The caller owns the socket and supplies fresh cryptographic padding on each
//! poll. The pump and transport must remain at stable addresses for the life
//! of the connection. Authentication and channel management follow separately.
const std = @import("std");
const identification = @import("ssh_identification.zig");
const kex = @import("ssh_kex_driver.zig");
const socket = @import("ssh_socket_pump.zig");
const transport = @import("ssh_transport.zig");

pub const Error = identification.Error || kex.Error || socket.Error || error{ Timeout, ClockRegression, MismatchedPump };
pub const Connection = struct {
    const Phase = enum { identification, kex, ready, failed };
    ident: identification.Exchange,
    driver: kex.Driver,
    deadline_us: u64,
    last_us: u64,
    phase: Phase = .identification,

    pub fn init(epoch: u64, now_us: u64, deadline_us: u64, secret: [32]u8, pin: [32]u8, cookie: [16]u8) Connection {
        return .{ .ident = .{ .epoch = epoch }, .driver = .{ .handshake = .{ .secret = secret, .pin = pin }, .cookie = cookie }, .deadline_us = deadline_us, .last_us = now_us };
    }
    /// One bounded identification or packet-pump and KEX step per call.
    pub fn poll(self: *Connection, wire: *transport.Transport, pump: *socket.Pump, io: socket.Io, epoch: u64, now_us: u64, padding: *const [32]u8) Error!bool {
        return self.advance(wire, pump, io, epoch, now_us, padding) catch |err| {
            self.deinit(wire, pump);
            return err;
        };
    }
    fn advance(self: *Connection, wire: *transport.Transport, pump: *socket.Pump, io: socket.Io, epoch: u64, now_us: u64, padding: *const [32]u8) Error!bool {
        if (self.phase == .failed) return error.Failed;
        if (pump.wire != wire) return error.MismatchedPump;
        if (epoch != self.ident.epoch or epoch != pump.epoch) return error.StaleConnection;
        if (now_us < self.last_us) return error.ClockRegression;
        self.last_us = now_us;
        if (self.phase == .ready) return true;
        if (now_us >= self.deadline_us) return error.Timeout;
        switch (self.phase) {
            .identification => {
                if (try self.ident.poll(io, epoch)) {
                    try self.driver.begin(self.ident.banner() orelse return error.InvalidBanner);
                    self.phase = .kex;
                }
            },
            .kex => {
                try pump.poll(io, epoch);
                if (try self.driver.step(wire, padding)) {
                    self.phase = .ready;
                    return true;
                }
            },
            else => unreachable,
        }
        return false;
    }
    pub fn deinit(self: *Connection, wire: *transport.Transport, pump: *socket.Pump) void {
        self.driver.deinit(wire);
        // A mismatched pump must not abort another connection's transport.
        if (pump.wire == wire) pump.abort();
        self.phase = .failed;
    }
};

test "connection fails closed on deadline, stale epoch and mismatched pump" {
    const Mock = struct {
        fn read(_: ?*anyopaque, _: []u8) socket.SocketError!socket.Result {
            return .would_block;
        }
        fn write(_: ?*anyopaque, _: []const u8) socket.SocketError!socket.Result {
            return .would_block;
        }
    };
    const io = socket.Io{ .context = null, .read = Mock.read, .write = Mock.write };
    const padding: [32]u8 = @splat(7);
    var wire: transport.Transport = .{};
    var pump = socket.Pump{ .wire = &wire, .epoch = 4 };
    var c = Connection.init(4, 10, 20, @splat(1), @splat(2), @splat(3));
    try std.testing.expect(!(try c.poll(&wire, &pump, io, 4, 19, &padding)));
    try std.testing.expectError(error.Timeout, c.poll(&wire, &pump, io, 4, 20, &padding));
    try std.testing.expect(wire.failed and pump.dead);
    try std.testing.expect(std.mem.allEqual(u8, &c.driver.handshake.secret, 0));
    try std.testing.expect(std.mem.allEqual(u8, &c.driver.cookie, 0));
    try std.testing.expectError(error.Failed, c.poll(&wire, &pump, io, 4, 20, &padding));
    var wire2: transport.Transport = .{};
    var pump2 = socket.Pump{ .wire = &wire2, .epoch = 4 };
    var stale = Connection.init(4, 10, 20, @splat(1), @splat(2), @splat(3));
    try std.testing.expectError(error.StaleConnection, stale.poll(&wire2, &pump2, io, 5, 11, &padding));
    var wire3: transport.Transport = .{};
    var other: transport.Transport = .{};
    var other_pump = socket.Pump{ .wire = &other, .epoch = 4 };
    var mismatch = Connection.init(4, 10, 20, @splat(1), @splat(2), @splat(3));
    try std.testing.expectError(error.MismatchedPump, mismatch.poll(&wire3, &other_pump, io, 4, 11, &padding));
    try std.testing.expect(wire3.failed and !other.failed and !other_pump.dead);
    var wire4: transport.Transport = .{};
    var pump4 = socket.Pump{ .wire = &wire4, .epoch = 4 };
    var clock = Connection.init(4, 10, 20, @splat(1), @splat(2), @splat(3));
    try std.testing.expectError(error.ClockRegression, clock.poll(&wire4, &pump4, io, 4, 9, &padding));
}
