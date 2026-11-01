//! Bounded RX deferral for the experimental Hosted/TCP owner. Station RX is
//! processed first; a saturated queue invalidates TCP but not the station.
const std = @import("std");
const hosted = @import("hosted.zig");
const station = @import("hosted_station.zig");
const tcp = @import("hosted_tcp_service.zig");
const binding = @import("hosted_tcp_station.zig");
pub const Error = binding.Error || error{ RxOverflow, FrameTooLarge };
const capacity = 4;
const max_frame = 1500;

pub const Queue = struct {
    frames: [capacity][max_frame]u8 = @splat(@splat(0)),
    lengths: [capacity]u16 = @splat(0),
    head: usize = 0,
    count: usize = 0,
    queued_handle: ?tcp.Handle = null,

    /// Always give the station the frame first. The network owner must call
    /// this exactly once per decoded Hosted frame, not concurrently with TX.
    pub fn receive(self: *Queue, service: *tcp.Service, client: *station.Client, handle: ?tcp.Handle, owner_epoch: u64, now_us: u64, frame: hosted.Frame) Error!bool {
        client.receive(frame, now_us) catch |err| {
            self.clear();
            try service.sync(null);
            return err;
        };
        binding.refresh(service, client, owner_epoch, now_us) catch |err| {
            self.clear();
            return err;
        };
        const h = handle orelse {
            self.clear();
            return false;
        };
        _ = service.ready(h) catch |err| {
            self.clear();
            return err;
        };
        if (frame.interface != hosted.station_interface or !candidate(client, frame.payload)) return false;
        if (frame.payload.len > max_frame) return self.overflow(service, error.FrameTooLarge);
        if (service.frame_len != 0 or self.count != 0) {
            if (self.queued_handle) |queued| if (!std.meta.eql(queued, h)) {
                self.clear();
                return error.StaleHandle;
            };
            if (self.count == capacity) return self.overflow(service, error.RxOverflow);
            const index = (self.head + self.count) % capacity;
            @memcpy(self.frames[index][0..frame.payload.len], frame.payload);
            self.lengths[index] = @intCast(frame.payload.len);
            self.queued_handle = h;
            self.count += 1;
            return true;
        }
        return service.receive(h, frame, now_us / 1000) catch |err| {
            self.clear();
            return err;
        };
    }
    /// Drain at most one frame per call, preserving order and bounded work.
    /// A staged TX remains authoritative until its completion is confirmed.
    pub fn drain(self: *Queue, service: *tcp.Service, client: *const station.Client, handle: tcp.Handle, owner_epoch: u64, now_us: u64) Error!bool {
        binding.refresh(service, client, owner_epoch, now_us) catch |err| {
            self.clear();
            return err;
        };
        _ = service.ready(handle) catch |err| {
            self.clear();
            return err;
        };
        if (self.queued_handle) |queued| if (!std.meta.eql(queued, handle)) {
            self.clear();
            return error.StaleHandle;
        };
        if (self.count == 0 or service.frame_len != 0) return false;
        const length = self.lengths[self.head];
        const frame = hosted.Frame{ .interface = hosted.station_interface, .payload = self.frames[self.head][0..length] };
        _ = service.receive(handle, frame, now_us / 1000) catch |err| {
            self.clear();
            return err;
        };
        std.crypto.secureZero(u8, &self.frames[self.head]);
        self.lengths[self.head] = 0;
        self.head = (self.head + 1) % capacity;
        self.count -= 1;
        if (self.count == 0) self.queued_handle = null;
        return true;
    }
    pub fn clear(self: *Queue) void {
        for (&self.frames) |*frame| std.crypto.secureZero(u8, frame);
        self.lengths = @splat(0);
        self.head = 0;
        self.count = 0;
        self.queued_handle = null;
    }
    fn overflow(self: *Queue, service: *tcp.Service, err: Error) Error {
        self.clear();
        service.invalidate();
        return err;
    }
};

fn candidate(client: *const station.Client, frame: []const u8) bool {
    if (frame.len < 14 or !std.mem.eql(u8, frame[0..6], &client.mac_address)) return false;
    const kind = std.mem.readInt(u16, frame[12..14], .big);
    if (kind == 0x0806) return frame.len >= 42 and std.mem.readInt(u16, frame[20..22], .big) == 2;
    if (kind != 0x0800 or frame.len < 34 or frame[14] >> 4 != 4 or frame[23] != 6) return false;
    const lease = if (client.dhcp_client) |v4| v4.lease orelse return false else return false;
    return std.mem.readInt(u32, frame[30..34], .big) == lease.ip;
}

fn fixture(client: *station.Client) void {
    client.phase = .done;
    client.keep_serving = true;
    client.connected = true;
    client.mac_address = .{ 0x52, 0x54, 0, 0x12, 0x34, 0x56 };
    client.dhcp_client = .{ .mac = client.mac_address, .xid = 1, .phase = .bound, .bound_at = 0, .renew_at = 20_000_000, .rebind_at = 30_000_000, .expires_at = 40_000_000, .lease = .{ .ip = 0x0a00020f, .mask = 0xffffff00, .gateway = 0x0a000202, .server = 0x0a000202, .seconds = 40 } };
}
fn reply(request: []const u8, mac: [6]u8) [42]u8 {
    var frame: [42]u8 = request[0..42].*;
    frame[0..6].* = request[6..12].*;
    frame[6..12].* = mac;
    std.mem.writeInt(u16, frame[20..22], 2, .big);
    frame[22..28].* = mac;
    frame[28..32].* = request[38..42].*;
    frame[32..38].* = request[6..12].*;
    frame[38..42].* = request[28..32].*;
    return frame;
}

test "RX waits for staged TX then drains the matching ARP reply" {
    var client: station.Client = .{};
    fixture(&client);
    var service: tcp.Service = .{};
    try binding.refresh(&service, &client, 1, 0);
    const h = try service.open(.{ .address = .{ 10, 0, 2, 2 }, .port = 22 }, 50001, 123, 0, 5000);
    const outbound = (try binding.next(&service, &client, h, 1, 0, false)).tcp;
    const length = outbound.len;
    const arp_reply = reply(outbound[12..], .{ 0x52, 0x55, 10, 0, 2, 2 });
    var q: Queue = .{};
    try std.testing.expect(try q.receive(&service, &client, h, 1, 1000, .{ .interface = 1, .payload = &arp_reply }));
    try std.testing.expectEqual(@as(usize, 1), q.count);
    try std.testing.expect(!try q.drain(&service, &client, h, 1, 1000));
    try service.sent(h, length, 1);
    try std.testing.expect(try q.drain(&service, &client, h, 1, 2000));
    try std.testing.expectEqual(@as(usize, 0), q.count);
    const syn = (try binding.next(&service, &client, h, 1, 3000, false)).tcp;
    try std.testing.expectEqual(@as(u16, 0x0800), std.mem.readInt(u16, syn[24..26], .big));
}

test "RX overflow revokes TCP but keeps the station connected" {
    var client: station.Client = .{};
    fixture(&client);
    var service: tcp.Service = .{};
    try binding.refresh(&service, &client, 1, 0);
    const h = try service.open(.{ .address = .{ 10, 0, 2, 2 }, .port = 22 }, 50001, 123, 0, 5000);
    const outbound = (try binding.next(&service, &client, h, 1, 0, false)).tcp;
    const arp_reply = reply(outbound[12..], .{ 0x52, 0x55, 10, 0, 2, 2 });
    var q: Queue = .{};
    for (0..capacity) |_| try std.testing.expect(try q.receive(&service, &client, h, 1, 1000, .{ .interface = 1, .payload = &arp_reply }));
    try std.testing.expectError(error.RxOverflow, q.receive(&service, &client, h, 1, 1000, .{ .interface = 1, .payload = &arp_reply }));
    try std.testing.expectEqual(@as(usize, 0), q.count);
    try std.testing.expect(client.connected);
    try std.testing.expectEqual(station.Phase.done, client.phase);
    try std.testing.expectError(error.StaleHandle, service.ready(h));
}

test "station ARP maintenance is processed while TCP TX is staged" {
    var client: station.Client = .{};
    fixture(&client);
    var service: tcp.Service = .{};
    try binding.refresh(&service, &client, 1, 0);
    const h = try service.open(.{ .address = .{ 10, 0, 2, 2 }, .port = 22 }, 50001, 123, 0, 5000);
    _ = try binding.next(&service, &client, h, 1, 0, false);
    const peer_mac = [6]u8{ 0x52, 0x55, 10, 0, 2, 2 };
    var request: [42]u8 = @splat(0);
    @memset(request[0..6], 0xff);
    request[6..12].* = peer_mac;
    std.mem.writeInt(u16, request[12..14], 0x0806, .big);
    std.mem.writeInt(u16, request[14..16], 1, .big);
    std.mem.writeInt(u16, request[16..18], 0x0800, .big);
    request[18] = 6;
    request[19] = 4;
    std.mem.writeInt(u16, request[20..22], 1, .big);
    request[22..28].* = peer_mac;
    request[28..32].* = .{ 10, 0, 2, 2 };
    request[38..42].* = .{ 10, 0, 2, 15 };
    var q: Queue = .{};
    try std.testing.expect(!try q.receive(&service, &client, h, 1, 1000, .{ .interface = 1, .payload = &request }));
    try std.testing.expect(client.dhcp_client.?.arp_pending);
    try std.testing.expectEqual(@as(usize, 0), q.count);
}

test "queued frames never cross a connection generation" {
    var client: station.Client = .{};
    fixture(&client);
    var service: tcp.Service = .{};
    try binding.refresh(&service, &client, 1, 0);
    const old = try service.open(.{ .address = .{ 10, 0, 2, 2 }, .port = 22 }, 50001, 123, 0, 5000);
    const outbound = (try binding.next(&service, &client, old, 1, 0, false)).tcp;
    const arp_reply = reply(outbound[12..], .{ 0x52, 0x55, 10, 0, 2, 2 });
    var q: Queue = .{};
    try std.testing.expect(try q.receive(&service, &client, old, 1, 1000, .{ .interface = 1, .payload = &arp_reply }));
    try binding.refresh(&service, &client, 2, 2000);
    const replacement = try service.open(.{ .address = .{ 10, 0, 2, 2 }, .port = 22 }, 50002, 124, 2, 5000);
    try std.testing.expectError(error.StaleHandle, q.drain(&service, &client, replacement, 2, 3000));
    try std.testing.expectEqual(@as(usize, 0), q.count);
    try std.testing.expect(!(try service.ready(replacement)));
}
