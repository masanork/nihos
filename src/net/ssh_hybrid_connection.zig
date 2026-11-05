//! Experimental identification and hybrid KEX over an established stream.
//! Stable, single-owner storage; the caller supplies entropy and owns worker
//! creation, exclusive handoff, cancellation, and worker backing lifetime.
const std = @import("std");
const ident = @import("ssh_identification.zig");
const driver_mod = @import("ssh_hybrid_driver.zig");
const kem = @import("ssh_kem_handoff.zig");
const socket = @import("ssh_socket_pump.zig");
const transport = @import("ssh_transport.zig");
pub const Connection = struct {
    const Phase = enum { identification, kex, ready, failed };
    identification: ident.Exchange,
    driver: driver_mod.Driver = undefined,
    driver_ready: bool = false,
    pre_worker_owned: bool = true,
    secret: [32]u8,
    pin: [32]u8,
    cookie: [16]u8,
    public: [1184]u8,
    token: kem.Token,
    deadline: u64,
    last: u64,
    phase: Phase = .identification,

    /// The caller has already started the worker and received its public key.
    /// A failed init or connection requires explicit worker cancellation.
    pub fn init(epoch: u64, token: kem.Token, now: u64, deadline: u64, secret: [32]u8, pin: [32]u8, cookie: [16]u8, public: [1184]u8) !Connection {
        var self: Connection = undefined;
        try self.initInPlace(epoch, token, now, deadline, secret, pin, cookie, &public);
        return self;
    }
    /// Caller must provide fresh storage and reclaim any previous worker first.
    pub fn initInPlace(self: *Connection, epoch: u64, token: kem.Token, now: u64, deadline: u64, secret: [32]u8, pin: [32]u8, cookie: [16]u8, public: *const [1184]u8) !void {
        if (epoch == 0 or token.epoch == 0 or token.request == 0 or deadline <= now) return error.InvalidToken;
        self.identification = .{ .epoch = epoch };
        self.driver_ready = false;
        self.pre_worker_owned = true;
        self.secret = secret;
        self.pin = pin;
        self.cookie = cookie;
        self.public = public.*;
        self.token = token;
        self.deadline = deadline;
        self.last = now;
        self.phase = .identification;
    }
    /// The submit callback only stages work; it must not let the worker touch
    /// this connection until poll has returned and ownership is transferred.
    /// Never poll while a worker has exclusive access to driver or transport.
    pub fn poll(self: *Connection, wire: *transport.Transport, pump: *socket.Pump, io: socket.Io, epoch: u64, now: u64, padding: *const [32]u8, context: ?*anyopaque, submit: driver_mod.Submit) !bool {
        return self.advance(wire, pump, io, epoch, now, padding, context, submit) catch |err| {
            self.abort(wire, pump);
            return err;
        };
    }
    fn advance(self: *Connection, wire: *transport.Transport, pump: *socket.Pump, io: socket.Io, epoch: u64, now: u64, padding: *const [32]u8, context: ?*anyopaque, submit: driver_mod.Submit) !bool {
        if (self.phase == .failed) return error.Failed;
        if (pump.wire != wire) return error.MismatchedPump;
        if (epoch != self.identification.epoch or epoch != pump.epoch) return error.StaleConnection;
        if (now < self.last) return error.ClockRegression;
        self.last = now;
        if (self.phase == .ready) return true;
        if (now >= self.deadline) return error.Timeout;
        switch (self.phase) {
            .identification => {
                if (try self.identification.poll(io, epoch)) {
                    try self.driver.protocol.initInPlace(self.secret, self.pin, self.identification.banner() orelse return error.InvalidBanner, &self.public);
                    self.driver.initInPlace(self.cookie, self.token, now, self.deadline) catch |err| {
                        self.driver.protocol.deinit();
                        return err;
                    };
                    self.driver_ready = true;
                    self.pre_worker_owned = false;
                    std.crypto.secureZero(u8, &self.secret);
                    std.crypto.secureZero(u8, &self.cookie);
                    self.phase = .kex;
                }
            },
            .kex => {
                try pump.poll(io, epoch);
                if (try self.driver.step(wire, now, padding, context, submit)) {
                    self.phase = .ready;
                    return true;
                }
            },
            else => unreachable,
        }
        return false;
    }
    /// Only while the owner has transferred exclusive access to the worker.
    pub fn complete(self: *Connection, wire: *transport.Transport, pump: *socket.Pump, token: kem.Token, now: u64, secret: *const [32]u8) !void {
        if (self.phase != .kex or !self.driver_ready) return error.InvalidState;
        self.driver.complete(wire, token, now, secret) catch |err| {
            if (err != error.Stale) self.abort(wire, pump);
            return err;
        };
    }
    pub fn abort(self: *Connection, wire: *transport.Transport, pump: *socket.Pump) void {
        if (self.driver_ready) self.driver.abort(wire) else wire.abort();
        if (pump.wire == wire) pump.abort();
        std.crypto.secureZero(u8, &self.secret);
        std.crypto.secureZero(u8, &self.cookie);
        self.phase = .failed;
    }
    /// Invoke only once the worker has stopped and erased its own key.
    pub fn cancelAcknowledged(self: *Connection, token: kem.Token) !void {
        if (token.epoch != self.token.epoch or token.request != self.token.request) return error.Stale;
        if (self.driver_ready) return self.driver.exchange.handoff.cancelAcknowledged(token);
        if (self.phase != .failed or !self.pre_worker_owned) return error.InvalidState;
        self.pre_worker_owned = false;
    }
    pub fn reclaimable(self: *const Connection) bool {
        return if (self.driver_ready) self.driver.exchange.handoff.reclaimable() else self.phase == .failed and !self.pre_worker_owned;
    }
};

test "identification failure requires worker cancellation without harming another pump" {
    const Mock = struct {
        fn read(_: ?*anyopaque, _: []u8) socket.SocketError!socket.Result {
            return .would_block;
        }
        fn write(_: ?*anyopaque, _: []const u8) socket.SocketError!socket.Result {
            return .would_block;
        }
        fn submit(_: ?*anyopaque, _: kem.Token, _: *const [1088]u8) bool {
            return false;
        }
    };
    const token: kem.Token = .{ .epoch = 2, .request = 3 };
    var conn = try Connection.init(4, token, 0, 10, @splat(1), @splat(2), @splat(3), @splat(4));
    var wire: transport.Transport = .{};
    var other: transport.Transport = .{};
    var pump: socket.Pump = .{ .wire = &other, .epoch = 4 };
    try std.testing.expectError(error.MismatchedPump, conn.poll(&wire, &pump, .{ .context = null, .read = &Mock.read, .write = &Mock.write }, 4, 1, &@as([32]u8, @splat(5)), null, &Mock.submit));
    try std.testing.expect(wire.failed and !pump.dead and !conn.reclaimable());
    try std.testing.expect(std.mem.allEqual(u8, &conn.secret, 0));
    try std.testing.expectError(error.Stale, conn.cancelAcknowledged(.{ .epoch = 2, .request = 4 }));
    try conn.cancelAcknowledged(token);
    try std.testing.expect(conn.reclaimable());
    var timeout = try Connection.init(4, token, 0, 10, @splat(1), @splat(2), @splat(3), @splat(4));
    var wire2: transport.Transport = .{};
    var pump2: socket.Pump = .{ .wire = &wire2, .epoch = 4 };
    const io: socket.Io = .{ .context = null, .read = &Mock.read, .write = &Mock.write };
    try std.testing.expectError(error.Timeout, timeout.poll(&wire2, &pump2, io, 4, 10, &@as([32]u8, @splat(5)), null, &Mock.submit));
    try std.testing.expect(wire2.failed and pump2.dead and !timeout.reclaimable());
    try timeout.cancelAcknowledged(token);
    try std.testing.expect(timeout.reclaimable());
}
