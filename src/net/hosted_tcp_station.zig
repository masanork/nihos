//! Adapts a live Hosted station's DHCP lease to the experimental TCP service.
//! The network owner must call refresh after station RX/maintenance and before
//! every TCP operation, and increment owner_epoch on each network reset.
const std = @import("std");
const station = @import("hosted_station.zig");
const tcp = @import("hosted_tcp_service.zig");
pub const Error = tcp.Error || station.Error || error{ClockInvalid};
pub const Next = union(enum) { idle, station: []const u8, tcp: []const u8 };

fn address(value: u32) [4]u8 {
    var out: [4]u8 = undefined;
    std.mem.writeInt(u32, &out, value, .big);
    return out;
}

/// `now_us` is the station's monotonic microsecond clock. The TCP service uses
/// milliseconds: callers must convert their operation deadlines consistently.
/// No DHCP renewal is performed here; station maintenance remains authoritative.
pub fn refresh(service: *tcp.Service, client: *const station.Client, owner_epoch: u64, now_us: u64) Error!void {
    if (owner_epoch == 0) {
        try service.sync(null);
        return error.InvalidArgument;
    }
    if (client.phase != .done or !client.keep_serving or !client.connected) return service.sync(null);
    const v4 = client.dhcp_client orelse return service.sync(null);
    const lease = v4.lease orelse return service.sync(null);
    if (now_us < v4.bound_at) {
        try service.sync(null);
        return error.ClockInvalid;
    }
    if (now_us >= v4.expires_at) return service.sync(null);
    return service.sync(.{ .ip = address(lease.ip), .mask = address(lease.mask), .gateway = address(lease.gateway), .mac = client.mac_address, .epoch = owner_epoch });
}

/// Run station maintenance before considering TCP. Existing staged TCP owns
/// its Hosted sequence and is completed first; otherwise station traffic and
/// the caller's other priority work (e.g. time/BLE) take precedence. The owner
/// sends the returned complete frame and calls client.sent() or service.sent().
pub fn next(service: *tcp.Service, client: *station.Client, handle: ?tcp.Handle, owner_epoch: u64, now_us: u64, other_pending: bool) Error!Next {
    const station_tx = client.tx(now_us) catch |err| {
        try service.sync(null);
        return err;
    };
    try refresh(service, client, owner_epoch, now_us);
    if (service.frame_len != 0) {
        const h = handle orelse return error.StaleHandle;
        const packet = (try service.tx(h, client.sequence, now_us / 1000)) orelse return error.InvalidState;
        return .{ .tcp = packet.bytes };
    }
    if (station_tx.len != 0) return .{ .station = station_tx };
    if (other_pending) return .idle;
    const h = handle orelse return .idle;
    const packet = (try service.tx(h, client.sequence, now_us / 1000)) orelse return .idle;
    if (packet.newly_staged) client.sequence +%= 1;
    return .{ .tcp = packet.bytes };
}

test "live station lease preserves renewal but revokes on expiry and reset" {
    var service: tcp.Service = .{};
    var client: station.Client = .{};
    client.phase = .done;
    client.keep_serving = true;
    client.connected = true;
    client.mac_address = .{ 0x52, 0x54, 0, 0x12, 0x34, 0x56 };
    client.dhcp_client = .{ .mac = client.mac_address, .xid = 1, .phase = .bound, .bound_at = 10_000, .expires_at = 10_000_000, .lease = .{ .ip = 0x0a00020f, .mask = 0xffffff00, .gateway = 0x0a000202, .server = 0x0a000202, .seconds = 10 } };
    try refresh(&service, &client, 7, 10_000);
    const h = try service.open(.{ .address = .{ 10, 0, 2, 2 }, .port = 22 }, 50001, 123, 10, 5000);
    client.dhcp_client.?.lease.?.seconds = 20;
    client.dhcp_client.?.expires_at = 20_000_000;
    try refresh(&service, &client, 7, 20_000);
    try std.testing.expect(!(try service.ready(h)));
    try refresh(&service, &client, 8, 30_000);
    try std.testing.expectError(error.StaleHandle, service.ready(h));
    const replacement = try service.open(.{ .address = .{ 10, 0, 2, 2 }, .port = 22 }, 50002, 124, 30, 5000);
    try refresh(&service, &client, 8, 20_000_000);
    try std.testing.expectError(error.StaleHandle, service.ready(replacement));
    try std.testing.expectError(error.NoLease, service.open(.{ .address = .{ 10, 0, 2, 2 }, .port = 22 }, 50003, 125, 40, 5000));
}

test "disconnect, invalid clock and disabled station never retain a TCP lease" {
    var service: tcp.Service = .{};
    var client: station.Client = .{};
    client.phase = .done;
    client.keep_serving = true;
    client.connected = true;
    client.mac_address = .{ 0x52, 0x54, 0, 0x12, 0x34, 0x56 };
    client.dhcp_client = .{ .mac = client.mac_address, .xid = 1, .phase = .bound, .bound_at = 1000, .expires_at = 5000, .lease = .{ .ip = 0x0a00020f, .mask = 0xffffff00, .gateway = 0x0a000202, .server = 0x0a000202, .seconds = 10 } };
    try std.testing.expectError(error.ClockInvalid, refresh(&service, &client, 1, 999));
    try refresh(&service, &client, 1, 1000);
    client.connected = false;
    try refresh(&service, &client, 1, 1100);
    try std.testing.expect(service.lease == null);
    client.connected = true;
    client.keep_serving = false;
    try refresh(&service, &client, 1, 1200);
    try std.testing.expect(service.lease == null);
    try std.testing.expectError(error.InvalidArgument, refresh(&service, &client, 0, 1200));
}

test "station maintenance has priority and staged TCP keeps its sequence" {
    var service: tcp.Service = .{};
    var client: station.Client = .{};
    client.phase = .done;
    client.keep_serving = true;
    client.connected = true;
    client.mac_address = .{ 0x52, 0x54, 0, 0x12, 0x34, 0x56 };
    client.dhcp_client = .{ .mac = client.mac_address, .xid = 1, .phase = .bound, .bound_at = 0, .renew_at = 20_000_000, .rebind_at = 30_000_000, .expires_at = 40_000_000, .lease = .{ .ip = 0x0a00020f, .mask = 0xffffff00, .gateway = 0x0a000202, .server = 0x0a000202, .seconds = 40 } };
    try refresh(&service, &client, 1, 0);
    const h = try service.open(.{ .address = .{ 10, 0, 2, 2 }, .port = 22 }, 50001, 123, 0, 5000);
    try std.testing.expectEqual(Next.idle, try next(&service, &client, h, 1, 0, true));
    client.dhcp_client.?.arp_pending = true;
    const first = try next(&service, &client, h, 1, 1000, false);
    try std.testing.expect(first == .station);
    client.sent(1000);
    const tcp_frame = try next(&service, &client, h, 1, 2000, false);
    try std.testing.expect(tcp_frame == .tcp);
    const length = tcp_frame.tcp.len;
    const seq = std.mem.readInt(u16, tcp_frame.tcp[8..10], .little);
    client.dhcp_client.?.arp_pending = true;
    const staged = try next(&service, &client, h, 1, 3000, true);
    try std.testing.expect(staged == .tcp);
    try std.testing.expectEqual(seq, std.mem.readInt(u16, staged.tcp[8..10], .little));
    try service.sent(h, length, 3);
    const queued_station = try next(&service, &client, h, 1, 4000, false);
    try std.testing.expect(queued_station == .station);
    try std.testing.expectError(error.LeaseExpired, next(&service, &client, h, 1, 40_000_000, false));
    try std.testing.expectError(error.StaleHandle, service.ready(h));
}
