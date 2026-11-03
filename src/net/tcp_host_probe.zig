//! Test-only C ABI around the experimental active-open and stream modules.
const connect = @import("tcp_connect.zig");
const tcp = @import("tcp_stream.zig");
const wait = @import("tcp_time_wait.zig");
const hosted = @import("hosted.zig");
const owner_core = @import("hosted_tcp_owner.zig");
const station_core = @import("hosted_station.zig");
const station_tcp = @import("hosted_tcp_station.zig");
const ssh_tcp = @import("ssh_hosted_tcp_io.zig");
var opening: connect.Connect = .{};
var stream: ?tcp.Stream = null;
var time_wait: ?wait.TimeWait = null;
var owner: owner_core.Owner = .{};
var host_station: station_core.Client = .{};
var socket_adapter: ?ssh_tcp.Adapter = null;
var staged_owner: enum { none, station, tcp } = .none;
var staged_length: usize = 0;
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
    host_now_ms = 0;
    // Synthetic bound station state; the fixture does not perform DHCP.
    host_station.phase = .done;
    host_station.keep_serving = true;
    host_station.connected = true;
    host_station.mac_address = guest_mac;
    host_station.dhcp_client = .{ .mac = guest_mac, .xid = 1, .phase = .bound, .bound_at = 0, .renew_at = 30_000_000, .rebind_at = 50_000_000, .expires_at = 60_000_000, .lease = .{ .ip = 0x0a00020f, .mask = 0xffffff00, .gateway = 0x0a000202, .server = 0x0a000202, .seconds = 60 } };
    return tcp_link_reopen(port, 50001);
}
/// Test-only: keep the station, owner and lease while opening a new tuple.
export fn tcp_link_reopen(port: u16, local_port: u16) bool {
    const now = host_now_ms;
    const handle = owner.open(&host_station, .{ .address = .{ 10, 0, 2, 2 }, .port = port }, local_port, 0x12345678, now *| 1000, now +| 15000) catch return false;
    socket_adapter = .{ .owner = &owner, .client = &host_station, .handle = handle, .epoch = owner.epoch, .now_us = now *| 1000, .write_timeout_ms = 12000 };
    link_time_wait = null;
    return true;
}
export fn tcp_link_next(now: u64, out: [*]u8, cap: usize) usize {
    if (!refreshStation(now)) return 0;
    const station_bytes = host_station.tx(now *| 1000) catch return 0;
    const tcp_bytes = owner.nextTcp(&host_station, now *| 1000, station_bytes.len != 0, false) catch return 0;
    const bytes = if (tcp_bytes) |frame| blk: {
        staged_owner = .tcp;
        break :blk frame;
    } else if (station_bytes.len != 0) blk: {
        staged_owner = .station;
        break :blk station_bytes;
    } else return 0;
    staged_length = bytes.len;
    const ethernet = bytes[12..];
    if (cap < ethernet.len) return 0;
    @memcpy(out[0..ethernet.len], ethernet);
    return ethernet.len;
}
export fn tcp_link_sent(now: u64) bool {
    if (!refreshStation(now)) return false;
    switch (staged_owner) {
        .station => host_station.sent(now *| 1000),
        .tcp => owner.sent(&host_station, staged_length, now *| 1000) catch return false,
        .none => return false,
    }
    staged_owner = .none;
    staged_length = 0;
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
    return owner.ready(&host_station, handle, host_now_ms *| 1000) catch false;
}
export fn tcp_link_write(bytes: [*]const u8, len: usize, now: u64) isize {
    if (!refreshStation(now)) return -2;
    const adapter = if (socket_adapter) |*value| value else return -2;
    adapter.advance(now *| 1000) catch return -2;
    const io = adapter.io();
    return switch (io.write(io.context, bytes[0..len]) catch return -2) {
        .progress => |n| @intCast(n),
        .would_block => -1,
        .eof => 0,
    };
}
export fn tcp_link_read(out: [*]u8, cap: usize) isize {
    if (!refreshStation(host_now_ms)) return -1;
    const adapter = if (socket_adapter) |*value| value else return -2;
    adapter.advance(host_now_ms *| 1000) catch return -2;
    const io = adapter.io();
    return switch (io.read(io.context, out[0..cap]) catch return -2) {
        .progress => |n| @intCast(n),
        .would_block => -1,
        .eof => 0,
    };
}
export fn tcp_link_close(now: u64) bool {
    if (!refreshStation(now)) return false;
    const handle = owner.handle orelse return false;
    owner.closeWrite(&host_station, handle, now *| 1000, now +| 12000) catch return false;
    return true;
}
export fn tcp_link_closed(now: u64) bool {
    if (!refreshStation(now)) return false;
    const handle = owner.handle orelse return false;
    if (!(owner.closeComplete(&host_station, handle, now *| 1000) catch return false)) return false;
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

const ssh_hosted = @import("ssh_hosted_session.zig");
// SAFETY: hosted_ssh_begin initializes this stable test object before use.
var ssh_owner: ssh_hosted.Owner = undefined;
var ssh_started = false;
export fn hosted_ssh_begin(cookie: *const [16]u8, secret: *const [32]u8, pin: *const [32]u8) bool {
    if (ssh_started) return false;
    const handle = owner.handle orelse return false;
    const now = host_now_ms *| 1000;
    const adapter = ssh_tcp.Adapter.init(&owner, &host_station, handle, now, 12000) catch return false;
    ssh_owner.begin(adapter, now, now +| 20_000_000, secret.*, pin.*, cookie.*, 80, 24);
    ssh_started = true;
    return true;
}
export fn hosted_ssh_poll(random: *const [32]u8, user: [*]const u8, len: usize, seed: *const [32]u8) isize {
    if (!ssh_started) return -1;
    return switch (ssh_owner.poll(host_now_ms *| 1000, random, user[0..len], seed.*) catch |err| return if (err == error.HostKeyMismatch) -2 else -1) {
        .connecting => 0,
        .ready => 1,
        .closed => 2,
    };
}
export fn hosted_ssh_read(random: *const [32]u8, dst: [*]u8, len: usize) isize {
    if (!ssh_started) return -1;
    return @intCast(ssh_owner.read(host_now_ms *| 1000, random, dst[0..len]) catch return -1);
}
export fn hosted_ssh_write(random: *const [32]u8, src: [*]const u8, len: usize) isize {
    if (!ssh_started) return -1;
    return @intCast(ssh_owner.write(host_now_ms *| 1000, random, src[0..len]) catch return -1);
}

export fn hosted_ssh_abort() void {
    if (ssh_started) ssh_owner.abort();
}
export fn tcp_link_cancel() bool {
    const handle = owner.handle orelse return false;
    owner.cancel(handle) catch return false;
    return true;
}
