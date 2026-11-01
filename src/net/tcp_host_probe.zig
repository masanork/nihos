//! Test-only C ABI around the experimental active-open and stream modules.
const connect = @import("tcp_connect.zig");
const tcp = @import("tcp_stream.zig");
const wait = @import("tcp_time_wait.zig");
const link_core = @import("tcp_link.zig");
var opening: connect.Connect = .{};
var stream: ?tcp.Stream = null;
var time_wait: ?wait.TimeWait = null;
var link: link_core.Link = .{};
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
    link.begin(.{ .ip = .{ 10, 0, 2, 15 }, .mask = .{ 255, 255, 255, 0 }, .gateway = .{ 10, 0, 2, 2 }, .mac = guest_mac, .epoch = 1 }, .{ .address = .{ 10, 0, 2, 2 }, .port = port }, 50001, 0x12345678, 0, 15000) catch return false;
    return true;
}
export fn tcp_link_next(now: u64, out: [*]u8, cap: usize) usize {
    const frame = (link.poll(1, now) catch return 0) orelse return 0;
    if (cap < frame.len) return 0;
    @memcpy(out[0..frame.len], frame);
    return frame.len;
}
export fn tcp_link_sent(now: u64) bool {
    link.sent(1, now) catch return false;
    return true;
}
export fn tcp_link_receive(frame: [*]const u8, len: usize, now: u64) bool {
    _ = link.receive(1, now, frame[0..len]) catch return false;
    return true;
}
export fn tcp_link_ready() bool {
    return link.ready();
}
export fn tcp_link_write(bytes: [*]const u8, len: usize, now: u64) usize {
    return link.write(1, bytes[0..len], now, now +| 12000) catch 0;
}
export fn tcp_link_read(out: [*]u8, cap: usize) isize {
    return @intCast(link.read(1, out[0..cap]) catch return -1);
}
export fn tcp_link_close(now: u64) bool {
    link.closeWrite(1, now, now +| 12000) catch return false;
    return true;
}
export fn tcp_link_closed(now: u64) bool {
    if (!link.closeHandshakeComplete()) return false;
    if (link_time_wait == null) {
        const s = if (link.stream) |*value| value else return false;
        link_time_wait = wait.TimeWait.begin(s, now, 2000) catch return false;
    }
    return true;
}
