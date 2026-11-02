const std = @import("std");
const t = std.testing;
const split = @import("hosted_network_split.zig");
const hosted = @import("hosted.zig");
const binding = @import("hosted_udp_lease.zig");
const wire = @import("udp_ipv4.zig");
const sender = @import("hosted_udp_sender.zig");
const route = @import("hosted_udp_route.zig");
const mac = [6]u8{ 2, 0, 0, 0, 0, 1 };
const neighbor = [6]u8{ 2, 0, 0, 0, 0, 2 };
fn ready() split.State {
    return .{ .generation = 7, .address = .{ .ip = 0xc0000201, .mask = 0xffffff00, .gateway = 0xc00002fe, .dns = 0xc00002fe } };
}
fn bind(s: *const split.State) !binding.Lease {
    return binding.Lease.open(s, mac, 49152, .{ .first = 49152, .last = 61439 });
}
fn reply(request: []const u8, next_hop: [4]u8) [42]u8 {
    var out: [42]u8 = request[12..54].*;
    out[0..6].* = mac;
    out[6..12].* = neighbor;
    std.mem.writeInt(u16, out[20..22], 2, .big);
    out[22..28].* = neighbor;
    out[28..32].* = next_hop;
    out[32..38].* = mac;
    out[38..42].* = .{ 192, 0, 2, 1 };
    return out;
}

test "on-link resolution holds a stable request and feeds the generic sender" {
    var s = ready();
    const l = try bind(&s);
    var r: route.Route = .{};
    try r.begin(&s, l, .{ 192, 0, 2, 25 }, 443, 10, 5000);
    const request = (try r.poll(&s, 10, 1)).?;
    try t.expectEqualSlices(u8, &.{ 192, 0, 2, 25 }, request[50..54]);
    var copied: [54]u8 = request[0..54].*;
    try t.expectEqualSlices(u8, &copied, (try r.poll(&s, 11, 99)).?);
    var response = reply(&copied, .{ 192, 0, 2, 25 });
    const frame = hosted.Frame{ .interface = hosted.station_interface, .payload = &response };
    try t.expectError(error.Busy, r.receive(&s, 12, frame));
    try r.sent(&s, 12);
    response[28] = 193;
    try t.expect(!try r.receive(&s, 13, frame));
    response[28] = 192;
    try t.expect(try r.receive(&s, 14, frame));
    const endpoint = (try r.result(&s, 15)).?;
    try t.expectEqualDeep(wire.Endpoint{ .mac = neighbor, .ip = .{ 192, 0, 2, 25 }, .port = 443 }, endpoint);
    var tx = try sender.Sender.init(&s, l);
    try tx.enqueue(endpoint, "payload", 2, 15, 100);
    const decoded = try wire.decode(tx.packet[12..tx.length]);
    try t.expectEqualDeep(endpoint, decoded.destination);
    try t.expectEqualStrings("payload", decoded.payload);
}

test "off-link resolution uses gateway MAC but retains destination IP" {
    var s = ready();
    var r: route.Route = .{};
    try r.begin(&s, try bind(&s), .{ 203, 0, 113, 8 }, 443, 1, 5000);
    const request = (try r.poll(&s, 1, 7)).?;
    try t.expectEqualSlices(u8, &.{ 192, 0, 2, 254 }, request[50..54]);
    var response = reply(request, .{ 192, 0, 2, 254 });
    try r.sent(&s, 2);
    try t.expect(try r.receive(&s, 3, .{ .interface = hosted.station_interface, .payload = &response }));
    const endpoint = (try r.result(&s, 4)).?;
    try t.expectEqualSlices(u8, &.{ 203, 0, 113, 8 }, &endpoint.ip);
    try t.expectEqualSlices(u8, &neighbor, &endpoint.mac);
}

test "deadline, lease snapshot changes and ambiguous writes revoke the route" {
    var s = ready();
    var r: route.Route = .{};
    try r.begin(&s, try bind(&s), .{ 192, 0, 2, 25 }, 443, 1, 100);
    _ = try r.poll(&s, 2, 1);
    s.address.?.dns = 0x08080808;
    try t.expectError(error.Stale, r.sent(&s, 3));
    try t.expectError(error.InvalidState, r.poll(&s, 4, 1));
    s = ready();
    r = .{};
    try r.begin(&s, try bind(&s), .{ 192, 0, 2, 25 }, 443, 1, 100);
    _ = try r.poll(&s, 2, 1);
    r.invalidate();
    try t.expectError(error.InvalidState, r.sent(&s, 3));
    r = .{};
    try r.begin(&s, try bind(&s), .{ 192, 0, 2, 25 }, 443, 1, 100);
    try t.expectError(error.Deadline, r.poll(&s, 100, 1));
    try t.expectError(error.InvalidState, r.poll(&s, 101, 1));
}

test "unrelated and unsolicited ARP replies do not resolve" {
    var s = ready();
    var r: route.Route = .{};
    try r.begin(&s, try bind(&s), .{ 192, 0, 2, 25 }, 443, 1, 5000);
    var fake: [42]u8 = @splat(0);
    try t.expect(!try r.receive(&s, 2, .{ .interface = hosted.station_interface, .payload = &fake }));
    const request = (try r.poll(&s, 3, 1)).?;
    fake = reply(request, .{ 192, 0, 2, 25 });
    try r.sent(&s, 4);
    try t.expect(!try r.receive(&s, 5, .{ .interface = 2, .payload = &fake }));
    fake[6] = 3;
    try t.expect(!try r.receive(&s, 6, .{ .interface = hosted.station_interface, .payload = &fake }));
    try t.expect((try r.result(&s, 7)) == null);
}

test "a sent request retries with backoff and resolved endpoints expire" {
    var s = ready();
    var r: route.Route = .{};
    try r.begin(&s, try bind(&s), .{ 192, 0, 2, 25 }, 443, 10, 3000);
    const request = (try r.poll(&s, 10, 1)).?;
    var response = reply(request, .{ 192, 0, 2, 25 });
    try r.sent(&s, 10);
    try t.expect((try r.poll(&s, 1009, 2)) == null);
    _ = (try r.poll(&s, 1010, 2)).?;
    try r.sent(&s, 1010);
    try t.expect(try r.receive(&s, 1011, .{ .interface = hosted.station_interface, .payload = &response }));
    try t.expect((try r.result(&s, 2999)) != null);
    try t.expectError(error.Deadline, r.result(&s, 3000));
    try t.expectError(error.InvalidState, r.result(&s, 3001));
}
