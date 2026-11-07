//! Experimental single-owner adapter from Hosted TCP to the SSH socket pump.
//! The network owner must serialize this with station polling and reset.
const std = @import("std");
const owner_mod = @import("hosted_tcp_owner.zig");
const station = @import("hosted_station.zig");
const tcp = @import("hosted_tcp_service.zig");
const pump = @import("ssh_socket_pump.zig");

pub const Adapter = struct {
    owner: *owner_mod.Owner,
    client: *station.Client,
    handle: tcp.Handle,
    epoch: u64,
    now_us: u64,
    write_timeout_ms: u64,
    failed: bool = false,

    /// Borrow only an established, current connection. No pointer is handed
    /// to the caller until timeout and lease validation have succeeded.
    pub fn init(owner: *owner_mod.Owner, client: *station.Client, handle: tcp.Handle, now_us: u64, write_timeout_ms: u64) (owner_mod.Error || error{ InvalidArgument, WouldBlock })!Adapter {
        if (write_timeout_ms == 0 or now_us / 1000 > std.math.maxInt(u64) - write_timeout_ms) return error.InvalidArgument;
        if (!try owner.ready(client, handle, now_us)) return error.WouldBlock;
        return .{ .owner = owner, .client = client, .handle = handle, .epoch = owner.epoch, .now_us = now_us, .write_timeout_ms = write_timeout_ms };
    }

    /// Called by the serialized owner before each pump poll; clock rollback and
    /// zero write deadlines fail closed rather than reusing a connection.
    pub fn advance(self: *Adapter, now_us: u64) pump.SocketError!void {
        if (self.failed or self.write_timeout_ms == 0 or now_us < self.now_us or self.epoch != self.owner.epoch or self.owner.reset_required or self.owner.exhausted) return self.fail();
        self.now_us = now_us;
        _ = self.owner.ready(self.client, self.handle, now_us) catch return self.fail();
    }
    pub fn io(self: *Adapter) pump.Io {
        return .{ .context = self, .read = read, .write = write };
    }
    fn valid(self: *Adapter) pump.SocketError!void {
        try self.advance(self.now_us);
    }
    fn read(context: ?*anyopaque, out: []u8) pump.SocketError!pump.Result {
        const self: *Adapter = @ptrCast(@alignCast(context orelse return error.SocketFailed));
        try self.valid();
        const n = self.owner.read(self.client, self.handle, self.now_us, out) catch |err| switch (err) {
            error.WouldBlock => return .would_block,
            else => return self.fail(),
        };
        return if (n == 0) .eof else .{ .progress = n };
    }
    fn write(context: ?*anyopaque, bytes: []const u8) pump.SocketError!pump.Result {
        const self: *Adapter = @ptrCast(@alignCast(context orelse return error.SocketFailed));
        try self.valid();
        const now_ms = self.now_us / 1000;
        const deadline = std.math.add(u64, now_ms, self.write_timeout_ms) catch return self.fail();
        const n = self.owner.write(self.client, self.handle, self.now_us, deadline, bytes) catch |err| switch (err) {
            error.WouldBlock => return .would_block,
            else => return self.fail(),
        };
        if (n == 0) return self.fail();
        return .{ .progress = n };
    }
    fn fail(self: *Adapter) pump.SocketError {
        self.failed = true;
        return error.SocketFailed;
    }
};

test "adapter maps partial writes, backpressure, buffered EOF and reset" {
    var owner: owner_mod.Owner = .{};
    var client: station.Client = .{};
    client.phase = .done;
    client.keep_serving = true;
    client.connected = true;
    client.mac_address = .{ 0x52, 0x54, 0, 0x12, 0x34, 0x56 };
    client.dhcp_client = .{ .mac = client.mac_address, .xid = 1, .phase = .bound, .bound_at = 0, .renew_at = 20_000_000, .rebind_at = 30_000_000, .expires_at = 40_000_000, .lease = .{ .ip = 0x0a00020f, .mask = 0xffffff00, .gateway = 0x0a000202, .server = 0x0a000202, .seconds = 40 } };
    const handle = try owner.open(&client, .{ .address = .{ 10, 0, 2, 2 }, .port = 22 }, 50001, 123, 0, 5000);
    try std.testing.expectError(error.InvalidArgument, Adapter.init(&owner, &client, handle, 0, 0));
    try std.testing.expectError(error.WouldBlock, Adapter.init(&owner, &client, handle, 0, 5000));
    const link = owner.service.link.?;
    link.state = .active;
    link.stream = @import("tcp_stream.zig").Stream.init(.{ .local = .{ .address = .{ 10, 0, 2, 15 }, .port = 50001 }, .remote = .{ .address = .{ 10, 0, 2, 2 }, .port = 22 }, .send_next = 1, .receive_next = 1, .remote_window = 4096, .remote_mss = 1460 });
    var adapter = try Adapter.init(&owner, &client, handle, 0, 5000);
    const io = adapter.io();
    try adapter.advance(1000);
    const payload: [600]u8 = @splat(0x5a);
    try std.testing.expectEqual(pump.Result{ .progress = tcp.max_write }, try io.write(io.context, &payload));
    try std.testing.expectEqual(pump.Result.would_block, try io.write(io.context, &payload));
    var buffer: [8]u8 = undefined;
    try std.testing.expectEqual(pump.Result.would_block, try io.read(io.context, &buffer));
    link.stream.?.rx[0..3].* = "abc".*;
    link.stream.?.rx_len = 3;
    link.stream.?.peer_fin = true;
    try std.testing.expectEqual(pump.Result{ .progress = 3 }, try io.read(io.context, &buffer));
    try std.testing.expectEqualStrings("abc", buffer[0..3]);
    try std.testing.expectEqual(pump.Result.eof, try io.read(io.context, &buffer));
    try owner.reset();
    try std.testing.expectError(error.StaleHandle, Adapter.init(&owner, &client, handle, 2000, 5000));
    var wire: @import("ssh_transport.zig").Transport = .{};
    try wire.prepare("pending", &@as([32]u8, @splat(1)));
    var socket_pump = pump.Pump{ .wire = &wire, .epoch = adapter.epoch };
    try std.testing.expectError(error.SocketFailed, socket_pump.poll(io, adapter.epoch));
    try std.testing.expect(socket_pump.dead);
    try std.testing.expectEqual(@as(usize, 0), wire.pending().len);
    try std.testing.expectError(error.SocketFailed, io.read(io.context, &buffer));
}
