//! Opt-in one-datagram smoke driver; no transport or network access itself.
const std = @import("std");
const wire = @import("udp_ipv4.zig");
const socket = @import("hosted_udp_socket.zig");

pub const payload_len = 458;
pub const Phase = enum(u32) { idle, waiting_link, waiting_echo, passed, failed };
pub const Report = extern struct {
    phase: u32 = 0,
    queued: u32 = 0,
    matched: u32 = 0,
    rejected: u32 = 0,
    error_code: u32 = 0,
    close_error_code: u32 = 0,
    sent: u32 = 0,
    pending: u32 = 0,
    blocked: u32 = 0,
    undrained: u32 = 0,
    decoder_busy: u32 = 0,
    udp_error: u32 = 0,
    rx_dropped: u32 = 0,
    rx_invalid: u32 = 0,
};

/// This diagnostic supplies the peer Ethernet address directly; it has no
/// gateway or ARP resolution. Reject a peer outside the adopted IPv4 subnet.
pub fn directPeer(local: u32, mask: u32, peer: [4]u8) bool {
    if (mask == 0 or mask == 0xffffffff) return false;
    const inverse = ~mask;
    if (inverse & (inverse +% 1) != 0) return false;
    const target = std.mem.readInt(u32, &peer, .big);
    return (local & mask) == (target & mask) and target != local and
        target != (local & mask) and target != ((local & mask) | inverse);
}

/// The callback methods are serialized with the network owner. The timeout is
/// absolute in microseconds; the input peer is not an authentication claim.
pub const Probe = struct {
    phase: Phase = .idle,
    deadline: u64 = 0,
    last_now: u64 = 0,
    peer: wire.Endpoint = .{ .mac = @splat(0), .ip = @splat(0), .port = 0 },
    handle: ?socket.Handle = null,
    report: Report = .{},

    pub fn start(self: *Probe, peer: wire.Endpoint, now: u64, deadline: u64) !void {
        if (self.phase != .idle or deadline <= now) return error.InvalidArgument;
        self.peer = peer;
        self.deadline = deadline;
        self.last_now = now;
        self.phase = .waiting_link;
    }
    pub fn step(self: *Probe, io: anytype, now: u64) void {
        if (self.phase == .idle or self.phase == .passed or self.phase == .failed) return;
        if (now < self.last_now or now >= self.deadline) return self.fail(io, error.Deadline);
        self.last_now = now;
        if (self.phase == .waiting_link) {
            const handle = io.bind(49152) catch |err| switch (err) {
                error.NetworkUnavailable => return,
                else => return self.fail(io, err),
            };
            self.handle = handle;
            var data: [payload_len]u8 = undefined;
            payload(&data);
            io.send(handle, self.peer, &data, self.deadline) catch |err| return self.fail(io, err);
            self.report.queued = 1;
            self.phase = .waiting_echo;
            return;
        }
        var data: [payload_len]u8 = undefined;
        const received = (io.read(self.handle.?, &data) catch |err| return self.fail(io, err)) orelse return;
        if (!std.meta.eql(received.source, self.peer) or received.bytes != payload_len or !matches(&data)) {
            self.report.rejected +|= 1;
            return;
        }
        io.close(self.handle.?) catch |err| return self.fail(io, err);
        self.handle = null;
        self.report.matched = 1;
        self.phase = .passed;
    }
    pub fn snapshot(self: *const Probe) Report {
        var value = self.report;
        value.phase = @backingInt(self.phase);
        return value;
    }
    fn fail(self: *Probe, io: anytype, err: anyerror) void {
        if (self.handle) |handle| io.close(handle) catch |close_err| {
            self.report.close_error_code = @intFromError(close_err);
        };
        self.handle = null;
        self.report.error_code = @intFromError(err);
        self.phase = .failed;
    }
};

pub fn payload(out: *[payload_len]u8) void {
    for (out, 0..) |*byte, index| byte.* = @truncate(index);
    @memcpy(out[0..8], "NIHOSUP1");
}

fn matches(data: *const [payload_len]u8) bool {
    if (!std.mem.eql(u8, data[0..8], "NIHOSUP1")) return false;
    for (data[8..], 8..) |byte, index| if (byte != @as(u8, @truncate(index))) return false;
    return true;
}
