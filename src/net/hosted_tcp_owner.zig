//! Experimental single-threaded integration boundary for Hosted station TCP.
//! The actual network owner remains responsible for SDIO, its lease and clock.
const std = @import("std");
const hosted = @import("hosted.zig");
const station = @import("hosted_station.zig");
const tcp = @import("hosted_tcp_service.zig");
const binding = @import("hosted_tcp_station.zig");
const rx = @import("hosted_tcp_rx.zig");
pub const Error = rx.Error || error{ InvalidCompletion, EpochExhausted, TransportResetRequired };
pub const Owner = struct {
    service: tcp.Service = .{},
    queue: rx.Queue = .{},
    handle: ?tcp.Handle = null,
    epoch: u64 = 1,
    pending: enum { none, station, tcp } = .none,
    pending_len: usize = 0,
    reset_required: bool = false,
    exhausted: bool = false,

    /// Initialize caller-owned storage in place without a large stack object.
    pub fn init(self: *Owner) void {
        @memset(std.mem.asBytes(self), 0);
        self.epoch = 1;
    }

    /// The caller resets station/transport separately before using a new epoch.
    pub fn reset(self: *Owner) Error!void {
        self.queue.clear();
        self.pending = .none;
        self.pending_len = 0;
        self.handle = null;
        try self.service.sync(null);
        if (self.epoch == std.math.maxInt(u64)) {
            self.exhausted = true;
            return error.EpochExhausted;
        }
        self.epoch += 1;
        self.reset_required = false;
    }
    pub fn open(self: *Owner, client: *const station.Client, remote: @import("tcp_connect.zig").Endpoint, port: u16, seq: u32, now_us: u64, deadline_ms: u64) Error!tcp.Handle {
        try self.check();
        try binding.refresh(&self.service, client, self.epoch, now_us);
        const handle = try self.service.open(remote, port, seq, now_us / 1000, deadline_ms);
        self.handle = handle;
        return handle;
    }
    pub fn receive(self: *Owner, client: *station.Client, frame: hosted.Frame, now_us: u64) Error!bool {
        try self.check();
        return self.queue.receive(&self.service, client, self.handle, self.epoch, now_us, frame) catch |err| {
            self.retireTcp();
            return err;
        };
    }
    /// Use after the network owner has delivered this frame to the station.
    pub fn receiveProcessed(self: *Owner, client: *const station.Client, frame: hosted.Frame, now_us: u64) Error!bool {
        try self.check();
        return self.queue.receiveProcessed(&self.service, client, self.handle, self.epoch, now_us, frame) catch |err| {
            self.retireTcp();
            return err;
        };
    }
    /// Call once per owner poll. Other producers must be represented by
    /// other_pending and must not transmit while a frame here is pending.
    pub fn next(self: *Owner, client: *station.Client, now_us: u64, other_pending: bool) Error!binding.Next {
        try self.check();
        if (self.handle) |handle| _ = self.queue.drain(&self.service, client, handle, self.epoch, now_us) catch |err| {
            self.retireTcp();
            return err;
        };
        const result = binding.next(&self.service, client, self.handle, self.epoch, now_us, other_pending) catch |err| {
            self.retireTcp();
            return err;
        };
        switch (result) {
            .idle => if (self.pending != .none) return error.InvalidCompletion,
            .station => |bytes| {
                if (self.pending == .tcp or (self.pending == .station and self.pending_len != bytes.len)) return error.InvalidCompletion;
                self.pending = .station;
                self.pending_len = bytes.len;
            },
            .tcp => |bytes| {
                if (self.pending == .station or (self.pending == .tcp and self.pending_len != bytes.len)) return error.InvalidCompletion;
                self.pending = .tcp;
                self.pending_len = bytes.len;
            },
        }
        return result;
    }
    /// Zero means backpressure. A partial completion retires TCP; the caller
    /// must reset the underlying transport because packet delivery is unknown.
    pub fn sent(self: *Owner, client: *station.Client, count: usize, now_us: u64) Error!void {
        try self.check();
        if (self.pending == .none) return error.InvalidCompletion;
        if (count == 0) return;
        if (count != self.pending_len) {
            self.service.invalidate();
            self.queue.clear();
            self.handle = null;
            self.pending = .none;
            self.pending_len = 0;
            self.reset_required = true;
            return error.InvalidCompletion;
        }
        switch (self.pending) {
            .station => client.sent(now_us),
            .tcp => {
                const handle = self.handle orelse {
                    self.reset_required = true;
                    return error.StaleHandle;
                };
                self.service.sent(handle, count, now_us / 1000) catch |err| {
                    self.reset_required = true;
                    return err;
                };
            },
            .none => unreachable,
        }
        self.pending = .none;
        self.pending_len = 0;
    }
    fn check(self: *const Owner) Error!void {
        if (self.exhausted) return error.EpochExhausted;
        if (self.reset_required) return error.TransportResetRequired;
    }
    fn retireTcp(self: *Owner) void {
        self.service.invalidate();
        self.queue.clear();
        self.handle = null;
        if (self.pending == .tcp) {
            self.pending = .none;
            self.pending_len = 0;
        }
    }
};

test "in-place initialization matches owner defaults" {
    var owner: Owner = undefined;
    owner.init();
    try std.testing.expect(std.meta.eql(Owner{}, owner));
}

test "owner preserves pending send and revokes handles on reset" {
    var owner: Owner = .{};
    var client: station.Client = .{};
    client.phase = .done;
    client.keep_serving = true;
    client.connected = true;
    client.mac_address = .{ 0x52, 0x54, 0, 0x12, 0x34, 0x56 };
    client.dhcp_client = .{ .mac = client.mac_address, .xid = 1, .phase = .bound, .bound_at = 0, .renew_at = 20_000_000, .rebind_at = 30_000_000, .expires_at = 40_000_000, .lease = .{ .ip = 0x0a00020f, .mask = 0xffffff00, .gateway = 0x0a000202, .server = 0x0a000202, .seconds = 40 } };
    const h = try owner.open(&client, .{ .address = .{ 10, 0, 2, 2 }, .port = 22 }, 50001, 123, 0, 5000);
    const first = try owner.next(&client, 0, false);
    try std.testing.expect(first == .tcp);
    const len = first.tcp.len;
    const seq = std.mem.readInt(u16, first.tcp[8..10], .little);
    try owner.sent(&client, 0, 1000);
    const again = try owner.next(&client, 1000, true);
    try std.testing.expect(again == .tcp);
    try std.testing.expectEqual(seq, std.mem.readInt(u16, again.tcp[8..10], .little));
    try owner.sent(&client, len, 2000);
    try owner.reset();
    try std.testing.expectError(error.StaleHandle, owner.service.ready(h));
    try std.testing.expectError(error.InvalidCompletion, owner.sent(&client, len, 3000));
}

test "partial completion retires connection" {
    var owner: Owner = .{};
    owner.pending = .tcp;
    owner.pending_len = 50;
    var client: station.Client = .{};
    try std.testing.expectError(error.InvalidCompletion, owner.sent(&client, 1, 0));
    try std.testing.expect(owner.handle == null);
    try std.testing.expect(owner.pending == .none);
    try std.testing.expectError(error.TransportResetRequired, owner.next(&client, 0, false));
    try owner.reset();
    try std.testing.expect(!owner.reset_required);
}

test "epoch exhaustion never permits reuse" {
    var owner: Owner = .{ .epoch = std.math.maxInt(u64) };
    var client: station.Client = .{};
    try std.testing.expectError(error.EpochExhausted, owner.reset());
    try std.testing.expectError(error.EpochExhausted, owner.next(&client, 0, false));
    try std.testing.expectError(error.EpochExhausted, owner.reset());
}

test "queue overflow retires TCP and station can continue" {
    var owner: Owner = .{};
    var client: station.Client = .{};
    client.phase = .done;
    client.keep_serving = true;
    client.connected = true;
    client.mac_address = .{ 0x52, 0x54, 0, 0x12, 0x34, 0x56 };
    client.dhcp_client = .{ .mac = client.mac_address, .xid = 1, .phase = .bound, .bound_at = 0, .renew_at = 20_000_000, .rebind_at = 30_000_000, .expires_at = 40_000_000, .lease = .{ .ip = 0x0a00020f, .mask = 0xffffff00, .gateway = 0x0a000202, .server = 0x0a000202, .seconds = 40 } };
    const h = try owner.open(&client, .{ .address = .{ 10, 0, 2, 2 }, .port = 22 }, 50001, 123, 0, 5000);
    const staged = (try owner.next(&client, 0, false)).tcp;
    var reply: [42]u8 = staged[12..54].*;
    const mac = [6]u8{ 0x52, 0x55, 10, 0, 2, 2 };
    reply[0..6].* = client.mac_address;
    reply[6..12].* = mac;
    std.mem.writeInt(u16, reply[20..22], 2, .big);
    reply[22..28].* = mac;
    reply[28..32].* = .{ 10, 0, 2, 2 };
    reply[32..38].* = client.mac_address;
    reply[38..42].* = .{ 10, 0, 2, 15 };
    const frame = hosted.Frame{ .interface = 1, .payload = &reply };
    for (0..4) |_| {
        try client.receive(frame, 1000);
        try std.testing.expect(try owner.receiveProcessed(&client, frame, 1000));
    }
    try client.receive(frame, 1000);
    try std.testing.expectError(error.RxOverflow, owner.receiveProcessed(&client, frame, 1000));
    try std.testing.expectError(error.StaleHandle, owner.service.ready(h));
    try std.testing.expect(owner.handle == null);
    try std.testing.expect(client.connected);
    client.dhcp_client.?.arp_pending = true;
    const maintenance = try owner.next(&client, 2000, true);
    try std.testing.expect(maintenance == .station);
    try owner.sent(&client, maintenance.station.len, 2000);
}
