//! Test-only C ABI around the experimental active-open and stream modules.
const connect = @import("tcp_connect.zig");
const tcp = @import("tcp_stream.zig");
const wait = @import("tcp_time_wait.zig");
const hosted = @import("hosted.zig");
const owner_core = @import("hosted_tcp_owner.zig");
const station_core = @import("hosted_station.zig");
const station_tcp = @import("hosted_tcp_station.zig");
var opening: connect.Connect = .{};
var stream: ?tcp.Stream = null;
var time_wait: ?wait.TimeWait = null;
var owner: owner_core.Owner = .{};
var host_station: station_core.Client = .{};
var host_now_ms: u64 = 0;
var link_time_wait: ?wait.TimeWait = null;
const guest_mac = [6]u8{ 0x52, 0x54, 0, 0x12, 0x34, 0x56 };

export fn tcp_probe_begin(port: u16) bool {
    return beginAt(port, 0);
}
fn beginAt(port: u16, now: u64) bool {
    opening.begin(.{ .address = .{ 10, 0, 2, 15 }, .port = 50001 }, .{ .address = .{ 10, 0, 2, 2 }, .port = port }, 0x12345678, now, now +| 15000) catch return false;
    return true;
}
export fn tcp_probe_next(now: u64, out: [*]u8, cap: usize) usize {
    const packet = if (time_wait) |*tw| tw.poll(now) catch return 0 else if (stream) |*s| s.poll(now) catch return 0 else opening.poll(now) catch return 0;
    const bytes = packet orelse return 0;
    if (bytes.len > cap) return 0;
    @memcpy(out[0..bytes.len], bytes);
    return bytes.len;
}
export fn tcp_probe_sent(now: u64) bool {
    if (time_wait) |*tw| {
        tw.sent(now) catch return false;
        return true;
    }
    if (stream) |*s| {
        s.sent(now) catch return false;
        return true;
    }
    opening.sent(now) catch return false;
    if (opening.result()) |result| stream = tcp.Stream.init(result);
    return true;
}
export fn tcp_probe_receive(bytes: [*]const u8, len: usize, now: u64) bool {
    if (time_wait) |*tw| {
        _ = tw.receive(bytes[0..len], now) catch return false;
        return true;
    }
    if (stream) |*s| {
        _ = s.receive(bytes[0..len]) catch return false;
        return true;
    }
    _ = opening.receive(bytes[0..len], now) catch return false;
    return true;
}
export fn tcp_probe_ready() bool {
    return stream != null;
}
export fn tcp_probe_write(bytes: [*]const u8, len: usize, now: u64) usize {
    const s = if (stream) |*v| v else return 0;
    return s.write(bytes[0..len], now, now + 12000) catch 0;
}
export fn tcp_probe_read(out: [*]u8, cap: usize) isize {
    const s = if (stream) |*v| v else return -1;
    return @intCast(s.read(out[0..cap]) catch return -1);
}
export fn tcp_probe_close(now: u64) bool {
    const s = if (stream) |*v| v else return false;
    s.closeWrite(now, now + 12000) catch return false;
    return true;
}
export fn tcp_probe_closed(now: u64) bool {
    const s = if (stream) |*v| v else return false;
    if (!s.closeHandshakeComplete()) return false;
    if (time_wait == null) time_wait = wait.TimeWait.begin(s, now, 2000) catch return false;
    return true;
}

/// Test-only Ethernet adapter. Production must obtain the lease and epoch from
/// the network owner and route ARP requests, TCP frames and link resets there.
export fn tcp_link_begin(port: u16) bool {
    // Synthetic bound station state; the fixture does not perform DHCP.
    host_station.phase = .done;
    host_station.keep_serving = true;
    host_station.connected = true;
    host_station.mac_address = guest_mac;
    host_station.dhcp_client = .{ .mac = guest_mac, .xid = 1, .phase = .bound, .bound_at = 0, .renew_at = 30_000_000, .rebind_at = 50_000_000, .expires_at = 60_000_000, .lease = .{ .ip = 0x0a00020f, .mask = 0xffffff00, .gateway = 0x0a000202, .server = 0x0a000202, .seconds = 60 } };
    _ = owner.open(&host_station, .{ .address = .{ 10, 0, 2, 2 }, .port = port }, 50001, 0x12345678, 0, 15000) catch return false;
    return true;
}
export fn tcp_link_next(now: u64, out: [*]u8, cap: usize) usize {
    if (!refreshStation(now)) return 0;
    const choice = owner.next(&host_station, now *| 1000, false) catch return 0;
    const bytes = switch (choice) {
        .idle => return 0,
        .station => |frame| frame,
        .tcp => |frame| frame,
    };
    const ethernet = bytes[12..];
    if (cap < ethernet.len) return 0;
    @memcpy(out[0..ethernet.len], ethernet);
    return ethernet.len;
}
export fn tcp_link_sent(now: u64) bool {
    if (!refreshStation(now)) return false;
    owner.sent(&host_station, owner.pending_len, now *| 1000) catch return false;
    return true;
}
export fn tcp_link_receive(frame: [*]const u8, len: usize, now: u64) bool {
    if (!refreshStation(now)) return false;
    var envelope: [1512]u8 = @splat(0);
    const bytes = hosted.frame(&envelope, hosted.station_interface, 0, frame[0..len]) catch return false;
    var decoder: hosted.Decoder = .{};
    for (bytes) |byte| {
        if (decoder.push(byte) catch return false) |decoded| {
            _ = owner.receive(&host_station, decoded, now *| 1000) catch return false;
        }
    }
    return true;
}
export fn tcp_link_ready() bool {
    if (!refreshStation(host_now_ms)) return false;
    const handle = owner.handle orelse return false;
    return owner.service.ready(handle) catch false;
}
export fn tcp_link_write(bytes: [*]const u8, len: usize, now: u64) usize {
    if (!refreshStation(now)) return 0;
    const handle = owner.handle orelse return 0;
    return owner.service.write(handle, bytes[0..len], now, now +| 12000) catch 0;
}
export fn tcp_link_read(out: [*]u8, cap: usize) isize {
    if (!refreshStation(host_now_ms)) return -1;
    const handle = owner.handle orelse return -1;
    return @intCast(owner.service.read(handle, out[0..cap]) catch return -1);
}
export fn tcp_link_close(now: u64) bool {
    if (!refreshStation(now)) return false;
    const handle = owner.handle orelse return false;
    owner.service.closeWrite(handle, now, now +| 12000) catch return false;
    return true;
}
export fn tcp_link_closed(now: u64) bool {
    if (!refreshStation(now)) return false;
    const handle = owner.handle orelse return false;
    if (!(owner.service.closeComplete(handle) catch return false)) return false;
    if (link_time_wait == null) {
        const link = if (owner.service.link) |*value| value else return false;
        const s = if (link.stream) |*value| value else return false;
        link_time_wait = wait.TimeWait.begin(s, now, 2000) catch return false;
    }
    return true;
}
fn refreshStation(now_ms: u64) bool {
    host_now_ms = now_ms;
    station_tcp.refresh(&owner.service, &host_station, owner.epoch, now_ms *| 1000) catch return false;
    return true;
}
