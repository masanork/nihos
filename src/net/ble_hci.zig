//! Bounded LE controller/GAP discovery over ESP-Hosted HCI. This is a P4
//! bring-up host, not the planned C6-resident GATT/SMP host offload.
//! Passive legacy scanning for ten seconds; no pairing or connection writes.
const std = @import("std");
pub const Phase = enum(u32) { off, unavailable, initializing, scanning, idle, failed };
pub const Report = extern struct {
    phase: u32 = 0,
    commands: u32 = 0,
    events: u32 = 0,
    advertisements: u32 = 0,
    malformed: u32 = 0,
    status: u32 = 0,
    timeouts: u32 = 0,
};
pub const Client = struct {
    phase: Phase = .off,
    report: Report = .{},
    command: u3 = 0,
    credits: u8 = 1,
    waiting: bool = false,
    deadline: u64 = 0,
    stop_at: u64 = 0,
    output: [16]u8 = @splat(0),
    pub fn begin(self: *Client, capabilities: u8) void {
        self.* = .{ .phase = if (capabilities & 4 != 0) .initializing else .unavailable };
    }
    fn opcode(self: *const Client) u16 {
        return switch (self.command) {
            0 => 0x0c03,
            1 => 0x0c01,
            2 => 0x2001,
            3 => 0x2003,
            4 => 0x200b,
            5, 6 => 0x200c,
            else => unreachable,
        };
    }
    pub fn tick(self: *Client, now: u64) void {
        if (self.waiting and now >= self.deadline) {
            self.phase = .failed;
            self.waiting = false;
            self.report.timeouts +|= 1;
        }
        if (self.phase == .scanning and now >= self.stop_at) {
            self.command = 6;
            self.phase = .initializing;
        }
    }
    /// Returned command bytes omit H4 type; owner wraps them with packet_type=1.
    pub fn tx(self: *Client, now: u64) []const u8 {
        self.tick(now);
        if (self.phase != .initializing or self.waiting or self.credits == 0) return &.{};
        const parameters: []const u8 = switch (self.command) {
            0, 3 => &.{},
            1 => &.{ 0, 0, 0, 0, 0, 0, 0, 0x20 }, // LE Meta event (bit 61)
            2 => &.{ 2, 0, 0, 0, 0, 0, 0, 0 }, // LE Advertising Report
            4 => &.{ 0, 0xa0, 0, 0x10, 0, 0, 0 }, // passive, public, accept all
            5 => &.{ 1, 1 }, // scan, filter duplicates
            6 => &.{ 0, 1 },
            else => unreachable,
        };
        std.mem.writeInt(u16, self.output[0..2], self.opcode(), .little);
        self.output[2] = @intCast(parameters.len);
        @memcpy(self.output[3..][0..parameters.len], parameters);
        return self.output[0 .. 3 + parameters.len];
    }
    pub fn sent(self: *Client, now: u64) void {
        self.waiting = true;
        self.credits -|= 1;
        self.deadline = now + 3_000_000;
        self.report.commands +|= 1;
    }
    pub fn receive(self: *Client, packet_type: u8, bytes: []const u8, now: u64) void {
        if (self.phase == .off or self.phase == .unavailable or self.phase == .failed) return;
        if (packet_type != 4) return; // ACL is not implemented by this profile.
        self.event(bytes, now) catch {
            self.report.malformed +|= 1;
        };
    }
    /// Hosted C6->P4 SDIO keeps H4 inside payload (1.4.1 and 2.13.1),
    /// unlike the P4->C6 path which uses header byte 11. Also accepts a
    /// controller transport that explicitly supplies the header packet type.
    pub fn receiveHosted(self: *Client, packet_type: u8, bytes: []const u8, now: u64) void {
        if (packet_type == 0) {
            if (bytes.len == 0) {
                self.report.malformed +|= 1;
                return;
            }
            self.receive(bytes[0], bytes[1..], now);
        } else self.receive(packet_type, bytes, now);
    }
    fn event(self: *Client, bytes: []const u8, now: u64) !void {
        if (bytes.len < 2 or bytes[1] != bytes.len - 2) return error.Malformed;
        self.report.events +|= 1;
        switch (bytes[0]) {
            0x0e => {
                if (bytes.len < 6) return error.Malformed;
                self.credits = bytes[2];
                const op = std.mem.readInt(u16, bytes[3..5], .little);
                if (!self.waiting or op != self.opcode()) return;
                if (self.command == 3 and bytes.len != 14) return error.Malformed;
                self.waiting = false;
                self.report.status = bytes[5];
                if (bytes[5] != 0) {
                    self.phase = .failed;
                    return;
                }
                if (self.command == 6) self.phase = .idle else if (self.command == 5) {
                    self.phase = .scanning;
                    self.stop_at = now + 10_000_000;
                } else self.command += 1;
            },
            0x0f => {
                if (bytes.len != 6) return error.Malformed;
                self.credits = bytes[3];
                if (!self.waiting or std.mem.readInt(u16, bytes[4..6], .little) != self.opcode()) return;
                if (bytes[2] != 0) {
                    self.waiting = false;
                    self.phase = .failed;
                    self.report.status = bytes[2];
                }
            },
            0x3e => {
                if (bytes.len < 3) return error.Malformed;
                if (bytes[2] != 2) return;
                if (bytes.len < 4 or bytes[3] == 0 or bytes[3] > 25) return error.Malformed;
                var pos: usize = 4;
                const count = bytes[3];
                for (0..count) |_| {
                    if (bytes.len - pos < 10) return error.Malformed;
                    if (bytes[pos] > 4 or bytes[pos + 1] > 1) return error.Malformed;
                    const len = bytes[pos + 8];
                    if (len > 31 or bytes.len - pos < 10 + @as(usize, len)) return error.Malformed;
                    pos += 10 + @as(usize, len);
                }
                if (pos != bytes.len) return error.Malformed;
                if (self.phase == .scanning) self.report.advertisements +|= count;
            },
            else => {},
        }
    }
    pub fn snapshot(self: *const Client) Report {
        var result = self.report;
        result.phase = @backingInt(self.phase);
        return result;
    }
};

test "BLE capability gating, command credits, matching responses, timeout" {
    var c: Client = .{};
    c.begin(1);
    try std.testing.expectEqual(Phase.unavailable, c.phase);
    try std.testing.expectEqual(@as(usize, 0), c.tx(0).len);
    c.begin(0x0d);
    try std.testing.expectEqualSlices(u8, &.{ 3, 12, 0 }, c.tx(0));
    c.sent(0);
    c.receive(4, &.{ 14, 4, 1, 1, 16, 0 }, 1); // unrelated response
    try std.testing.expect(c.waiting);
    c.receive(4, &.{ 14, 4, 0, 3, 12, 0 }, 2);
    try std.testing.expectEqual(@as(usize, 0), c.tx(3).len); // no credits
    c.receive(4, &.{ 14, 4, 1, 1, 16, 0 }, 4);
    try std.testing.expectEqual(@as(usize, 11), c.tx(5).len);
    c.sent(5);
    c.tick(3_000_005);
    try std.testing.expectEqual(Phase.failed, c.phase);
    c.begin(4);
    try std.testing.expectEqual(@as(u32, 0), c.snapshot().timeouts);
}

test "BLE validates whole multi-advertisement event before counting" {
    var c = Client{ .phase = .scanning };
    c.receive(4, &.{ 0x3e, 12, 2, 1, 0, 0, 1, 2, 3, 4, 5, 6, 0, 200 }, 0);
    try std.testing.expectEqual(@as(u32, 1), c.snapshot().advertisements);
    c.receive(4, &.{ 0x3e, 12, 2, 2, 0, 0, 1, 2, 3, 4, 5, 6, 0, 200 }, 1);
    try std.testing.expectEqual(@as(u32, 1), c.snapshot().advertisements);
    try std.testing.expectEqual(@as(u32, 1), c.snapshot().malformed);
}

test "BLE initialization, bounded scan and disable command require successful completions" {
    var c: Client = .{};
    c.begin(4);
    for (0..6) |i| {
        const packet = c.tx(i);
        try std.testing.expect(packet.len >= 3);
        var event = [_]u8{ 14, 4, 1, packet[0], packet[1], 0, 0, 0, 0, 0, 0, 0, 0, 0 };
        const length: usize = if (i == 3) 14 else 6;
        event[1] = @intCast(length - 2);
        c.sent(i);
        c.receive(4, event[0..length], i + 1);
    }
    try std.testing.expectEqual(Phase.scanning, c.phase);
    try std.testing.expectEqual(@as(usize, 0), c.tx(10_000_005).len);
    try std.testing.expectEqualSlices(u8, &.{ 12, 32, 2, 0, 1 }, c.tx(10_000_006));
    c.sent(10_000_006);
    c.receive(4, &.{ 14, 4, 1, 12, 32, 0 }, 10_000_007);
    try std.testing.expectEqual(Phase.idle, c.phase);
    try std.testing.expectEqual(@as(u32, 7), c.snapshot().commands);
    c.begin(4);
    _ = c.tx(0);
    c.sent(0);
    c.receive(4, &.{ 14, 4, 1, 3, 12, 1 }, 1);
    try std.testing.expectEqual(Phase.failed, c.phase);
    try std.testing.expectEqual(@as(u32, 1), c.snapshot().status);
}

test "Hosted controller events retain H4 in SDIO payload in the receive direction" {
    var c: Client = .{};
    c.begin(4);
    _ = c.tx(0);
    c.sent(0);
    c.receiveHosted(0, &.{ 4, 14, 4, 1, 3, 12, 0 }, 1);
    try std.testing.expect(!c.waiting);
    try std.testing.expectEqual(@as(u3, 1), c.command);
    try std.testing.expectEqual(@as(u32, 1), c.snapshot().events);
}
