//! PIN-free input experiment. Counts contacts; never stores or submits digits.
const std = @import("std");
const touch = @import("touch.zig");
pub const background: u16 = 0x1082;
pub const Event = struct { point: touch.Point, color: u16, inferred_release: bool = false };
pub const State = struct {
    point: touch.Point = .{ .contacts = 0 },
    idle_samples: u32 = 0,
    quadrants: u4 = 0,
    inferred_releases: u32 = 0,
    explicit_releases: u32 = 0,
    contact_samples: u32 = 0,
    max_contacts: u8 = 0,

    /// Only the Sitronix experiment may infer an idle indication from two
    /// coordinate-unavailable samples. This is not an authenticated PIN edge.
    /// Goodix no-new-report samples never synthesize release.
    pub fn observe(self: *State, sample: touch.Sample, sitronix: bool) ?Event {
        switch (sample) {
            .unchanged => {
                self.idle_samples +|= 1;
                if (!sitronix or self.idle_samples < 2 or self.point.contacts == 0) return null;
                self.point.contacts = 0;
                self.inferred_releases += 1;
                return .{ .point = self.point, .color = background, .inferred_release = true };
            },
            .fresh => |point| {
                self.idle_samples = 0;
                const previous = self.point;
                self.point = point;
                if (point.contacts == 0) {
                    if (previous.contacts == 0) return null;
                    self.explicit_releases += 1;
                    return .{ .point = point, .color = background };
                }
                self.contact_samples += 1;
                self.max_contacts = @max(self.max_contacts, point.contacts);
                const quadrant: u2 = @as(u2, @intFromBool(point.x >= 360)) | (@as(u2, @intFromBool(point.y >= 640)) << 1);
                self.quadrants |= @as(u4, 1) << quadrant;
                const colors = [_]u16{ 0xf800, 0x07e0, 0x001f, 0xffe0 };
                // Avoid filling the UART with subpixel finger jitter.
                if (previous.contacts == point.contacts and previous.x / 8 == point.x / 8 and previous.y / 8 == point.y / 8) return null;
                return .{ .point = point, .color = colors[quadrant] };
            },
        }
    }
};
test "four quadrants, multiple contacts and explicit release retain input evidence" {
    var state = State{};
    const positions = [_]touch.Point{
        .{ .contacts = 1, .x = 100, .y = 100 },
        .{ .contacts = 1, .x = 600, .y = 100 },
        .{ .contacts = 2, .x = 100, .y = 1000 },
        .{ .contacts = 1, .x = 600, .y = 1000 },
    };
    for (positions) |point| try std.testing.expect(state.observe(.{ .fresh = point }, true) != null);
    try std.testing.expectEqual(@as(u4, 15), state.quadrants);
    try std.testing.expectEqual(@as(u8, 2), state.max_contacts);
    try std.testing.expectEqual(background, state.observe(.{ .fresh = .{ .contacts = 0 } }, true).?.color);
    try std.testing.expectEqual(@as(u32, 1), state.explicit_releases);
}
test "only this Sitronix experiment infers idle; Goodix stale data cannot release" {
    var state = State{};
    _ = state.observe(.{ .fresh = .{ .contacts = 1, .x = 100, .y = 100 } }, true);
    try std.testing.expect(state.observe(.unchanged, true) == null);
    try std.testing.expect(state.observe(.unchanged, true).?.inferred_release);
    try std.testing.expectEqual(@as(u32, 1), state.inferred_releases);
    try std.testing.expect(state.observe(.unchanged, true) == null);
    _ = state.observe(.{ .fresh = .{ .contacts = 1, .x = 100, .y = 100 } }, false);
    for (0..10) |_| try std.testing.expect(state.observe(.unchanged, false) == null);
    try std.testing.expectEqual(@as(u8, 1), state.point.contacts);
}
