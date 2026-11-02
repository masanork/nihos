//! Experimental CPU0-owned composition of the Hosted TCP adapter, SSH client
//! and terminal. The caller supplies stable, exclusive storage, credentials and
//! cryptographic randomness, polls the network owner separately, and closes TCP.
//! Never move or copy this object after begin: pump and adapter borrow fields.
const std = @import("std");
const hosted = @import("ssh_hosted_tcp_io.zig");
const socket = @import("ssh_socket_pump.zig");
const transport = @import("ssh_transport.zig");
const client = @import("ssh_client.zig");
const terminal = @import("ssh_terminal.zig");

pub const Error = client.Error || socket.SocketError;
pub const Status = enum { connecting, ready, closed };
pub const Owner = struct {
    adapter: hosted.Adapter,
    wire: transport.Transport,
    pump: socket.Pump,
    client: client.Client,
    tty: terminal.Terminal,
    ready: bool = false,
    ended: bool = false,

    /// `self` must already be in its final stable location and cannot be copied.
    /// The adapter must represent a current, established Hosted TCP stream.
    pub fn begin(self: *Owner, adapter: hosted.Adapter, now_us: u64, deadline_us: u64, secret: [32]u8, pin: [32]u8, cookie: [16]u8, cols: u32, rows: u32) void {
        self.adapter = adapter;
        self.wire = .{};
        self.pump = .{ .wire = &self.wire, .epoch = adapter.epoch };
        self.client = client.Client.init(adapter.epoch, now_us, deadline_us, secret, pin, cookie, cols, rows);
        self.tty = .{};
        self.ready = false;
        self.ended = false;
    }
    /// The external network owner must run between calls. Padding must be fresh
    /// cryptographic randomness; username and seed are never stored here.
    pub fn poll(self: *Owner, now_us: u64, padding: *const [32]u8, username: []const u8, seed: [32]u8) Error!Status {
        return self.advance(now_us, padding, username, seed) catch |err| {
            self.abort();
            return err;
        };
    }
    fn advance(self: *Owner, now_us: u64, padding: *const [32]u8, username: []const u8, seed: [32]u8) Error!Status {
        if (self.ended) return error.Failed;
        try self.adapter.advance(now_us);
        if (!self.ready) {
            self.ready = try self.client.poll(&self.wire, &self.pump, self.adapter.io(), self.adapter.epoch, now_us, padding, username, seed);
            return if (self.ready) .ready else .connecting;
        }
        if (try self.tty.poll(&self.client, &self.wire, &self.pump, self.adapter.io(), self.adapter.epoch, now_us, padding)) {
            self.abort();
            return .closed;
        }
        return .ready;
    }
    pub fn read(self: *Owner, now_us: u64, padding: *const [32]u8, dst: []u8) Error!usize {
        return self.readInner(now_us, padding, dst) catch |err| {
            self.abort();
            return err;
        };
    }
    fn readInner(self: *Owner, now_us: u64, padding: *const [32]u8, dst: []u8) Error!usize {
        if (self.ended or !self.ready) return error.InvalidState;
        try self.adapter.advance(now_us);
        return self.tty.read(&self.client, &self.wire, &self.pump, self.adapter.io(), self.adapter.epoch, now_us, padding, dst);
    }
    pub fn write(self: *Owner, now_us: u64, padding: *const [32]u8, bytes: []const u8) Error!usize {
        return self.writeInner(now_us, padding, bytes) catch |err| {
            self.abort();
            return err;
        };
    }
    fn writeInner(self: *Owner, now_us: u64, padding: *const [32]u8, bytes: []const u8) Error!usize {
        if (self.ended or !self.ready) return error.InvalidState;
        try self.adapter.advance(now_us);
        return self.tty.write(&self.client, &self.wire, &self.pump, self.adapter.io(), self.adapter.epoch, now_us, bytes, padding);
    }
    /// Wipes SSH transport and handshake state but does not close the TCP owner.
    pub fn abort(self: *Owner) void {
        self.client.deinit(&self.wire, &self.pump);
        self.tty = .{ .failed = true };
        self.ended = true;
    }
};

test "Hosted session fails closed when its network owner resets" {
    const owner_mod = @import("hosted_tcp_owner.zig");
    const station = @import("hosted_station.zig");
    var network: owner_mod.Owner = .{};
    var wifi: station.Client = .{};
    wifi.phase = .done;
    wifi.keep_serving = true;
    wifi.connected = true;
    wifi.mac_address = .{ 0x52, 0x54, 0, 0x12, 0x34, 0x56 };
    wifi.dhcp_client = .{ .mac = wifi.mac_address, .xid = 1, .phase = .bound, .bound_at = 0, .renew_at = 20_000_000, .rebind_at = 30_000_000, .expires_at = 40_000_000, .lease = .{ .ip = 0x0a00020f, .mask = 0xffffff00, .gateway = 0x0a000202, .server = 0x0a000202, .seconds = 40 } };
    const handle = try network.open(&wifi, .{ .address = .{ 10, 0, 2, 2 }, .port = 22 }, 50001, 123, 0, 5000);
    const link = &network.service.link.?;
    link.state = .active;
    link.stream = @import("tcp_stream.zig").Stream.init(.{ .local = .{ .address = .{ 10, 0, 2, 15 }, .port = 50001 }, .remote = .{ .address = .{ 10, 0, 2, 2 }, .port = 22 }, .send_next = 1, .receive_next = 1, .remote_window = 4096, .remote_mss = 1460 });
    const adapter = try hosted.Adapter.init(&network, &wifi, handle, 0, 5000);
    var session: Owner = undefined;
    session.begin(adapter, 0, 5_000_000, @splat(1), @splat(2), @splat(3), 80, 24);
    const random: [32]u8 = @splat(4);
    try std.testing.expectEqual(Status.connecting, try session.poll(1000, &random, "user", @splat(5)));
    try network.reset();
    try std.testing.expectError(error.SocketFailed, session.poll(2000, &random, "user", @splat(5)));
    try std.testing.expect(session.ended and session.wire.failed and session.pump.dead);
    try std.testing.expect(std.mem.allEqual(u8, &session.client.conn.driver.handshake.secret, 0));
    try std.testing.expectError(error.Failed, session.poll(3000, &random, "user", @splat(5)));
}
