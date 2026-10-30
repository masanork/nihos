//! CPU0 single-contact pointer stream, independent of rendering/card/PIN APIs.
const std = @import("std");
pub const TouchService = @import("touch_service.zig").Service;
pub const Kind = enum(u32) { down = 1, move, up, cancel };
pub const Reason = enum(u32) { none, multiple, invalid, stale, overflow, hardware };
pub const Event = extern struct { kind: Kind, reason: Reason = .none, sequence: u32 = 0, x: u32 = 0, y: u32 = 0, at: u64 = 0 };
pub const Rect = struct {
    x: u16,
    y: u16,
    width: u16,
    height: u16,
    pub fn contains(self: Rect, x: u32, y: u32) bool {
        return x >= self.x and y >= self.y and x - self.x < self.width and y - self.y < self.height;
    }
};
pub const view_button: Rect = .{ .x = 1120, .y = 16, .width = 144, .height = 64 };
pub const Point = struct { x: u32, y: u32 };
pub fn landscape(raw_x: u16, raw_y: u16) ?Point {
    if (raw_x >= 720 or raw_y >= 1280) return null;
    return .{ .x = 1279 - @as(u32, raw_y), .y = raw_x };
}
pub const Stream = struct {
    mode: enum { idle, pressed, blocked } = .idle,
    point: Point = .{ .x = 0, .y = 0 },
    sequence: u32 = 0,
    last_fresh: u64 = 0,
    pub fn cancel(self: *Stream, reason: Reason, now: u64) Event {
        self.mode = .blocked;
        return self.event(.cancel, reason, now);
    }
    fn event(self: *Stream, kind: Kind, reason: Reason, now: u64) Event {
        self.sequence +%= 1;
        return .{ .kind = kind, .reason = reason, .sequence = self.sequence, .x = self.point.x, .y = self.point.y, .at = now };
    }
    pub fn fresh(self: *Stream, contacts: u8, raw_x: u16, raw_y: u16, now: u64) ?Event {
        if (now < self.last_fresh) return self.cancel(.stale, now);
        self.last_fresh = now;
        if (contacts > 1) {
            if (self.mode == .pressed) return self.cancel(.multiple, now);
            self.mode = .blocked;
            return null;
        }
        if (contacts == 0) {
            const previous = self.mode;
            self.mode = .idle;
            return if (previous == .pressed) self.event(.up, .none, now) else null;
        }
        const next = landscape(raw_x, raw_y) orelse return self.cancel(.invalid, now);
        if (self.mode == .blocked) return null;
        const changed = next.x != self.point.x or next.y != self.point.y;
        self.point = next;
        if (self.mode == .idle) {
            self.mode = .pressed;
            return self.event(.down, .none, now);
        }
        return if (changed) self.event(.move, .none, now) else null;
    }
    /// Missing reports can cancel a stale stream, but never synthesize an up.
    pub fn tick(self: *Stream, now: u64) ?Event {
        if (self.mode != .pressed) return null;
        if (now < self.last_fresh or now - self.last_fresh > 2_000_000) return self.cancel(.stale, now);
        return null;
    }
};
pub const Queue = struct {
    items: [8]Event = @splat(.{ .kind = .cancel }),
    head: usize = 0,
    length: usize = 0,
    overflows: u32 = 0,
    /// Overflow replaces queued edges with cancel. Caller must quarantine the
    /// stream until explicit release, so a lost edge cannot become a click.
    pub fn push(self: *Queue, event: Event) bool {
        if (self.length == self.items.len) {
            self.head = 0;
            self.length = 1;
            self.overflows +|= 1;
            self.items[0] = event;
            self.items[0].kind = .cancel;
            self.items[0].reason = .overflow;
            return false;
        }
        self.items[(self.head + self.length) % self.items.len] = event;
        self.length += 1;
        return true;
    }
    pub fn pop(self: *Queue) ?Event {
        if (self.length == 0) return null;
        const event = self.items[self.head];
        self.head = (self.head + 1) % self.items.len;
        self.length -= 1;
        return event;
    }
};
pub const Button = struct {
    armed: bool = false,
    start: Point = .{ .x = 0, .y = 0 },
    began: u64 = 0,
    pub fn observe(self: *Button, event: Event, rect: Rect) bool {
        if (event.kind == .down) {
            self.armed = rect.contains(event.x, event.y);
            self.start = .{ .x = event.x, .y = event.y };
            self.began = event.at;
            return false;
        }
        if (event.kind == .cancel) {
            self.armed = false;
            return false;
        }
        if (!self.armed) return false;
        const dx = @max(self.start.x, event.x) - @min(self.start.x, event.x);
        const dy = @max(self.start.y, event.y) - @min(self.start.y, event.y);
        const inside = rect.contains(event.x, event.y) and dx <= 24 and dy <= 24 and event.at >= self.began and event.at - self.began <= 1_500_000;
        if (!inside) self.armed = false;
        if (event.kind != .up) return false;
        const clicked = self.armed;
        self.armed = false;
        return clicked;
    }
};

test "landscape coordinates match rotated console and reject invalid geometry" {
    try std.testing.expectEqualDeep(Point{ .x = 1279, .y = 0 }, landscape(0, 0).?);
    try std.testing.expectEqualDeep(Point{ .x = 0, .y = 719 }, landscape(719, 1279).?);
    try std.testing.expect(landscape(720, 0) == null and landscape(0, 1280) == null);
    try std.testing.expect(view_button.contains(1200, 48));
}
test "only explicit release completes a single stream; stale and multiple contacts cancel" {
    var stream: Stream = .{};
    try std.testing.expectEqual(Kind.down, stream.fresh(1, 48, 87, 10).?.kind);
    try std.testing.expect(stream.tick(500_000) == null);
    try std.testing.expect(stream.fresh(1, 48, 87, 500_001) == null);
    try std.testing.expectEqual(Kind.up, stream.fresh(0, 0, 0, 500_002).?.kind);
    _ = stream.fresh(1, 48, 87, 600_000);
    try std.testing.expectEqual(Kind.cancel, stream.fresh(2, 48, 87, 600_001).?.kind);
    try std.testing.expect(stream.fresh(1, 48, 87, 600_002) == null);
    try std.testing.expect(stream.fresh(0, 0, 0, 600_003) == null);
    _ = stream.fresh(1, 48, 87, 700_000);
    try std.testing.expectEqual(Kind.cancel, stream.tick(3_000_000).?.kind);
    try std.testing.expect(stream.fresh(1, 48, 87, 3_000_001) == null);
}
test "button rejects hold, drag-out-return, cancel and release without press" {
    var button: Button = .{};
    const down = Event{ .kind = .down, .x = 1200, .y = 48, .at = 10 };
    try std.testing.expect(!button.observe(.{ .kind = .up, .x = 1200, .y = 48, .at = 11 }, view_button));
    _ = button.observe(down, view_button);
    try std.testing.expect(button.observe(.{ .kind = .up, .x = 1200, .y = 48, .at = 100 }, view_button));
    _ = button.observe(down, view_button);
    _ = button.observe(.{ .kind = .move, .x = 900, .y = 48, .at = 20 }, view_button);
    try std.testing.expect(!button.observe(.{ .kind = .up, .x = 1200, .y = 48, .at = 100 }, view_button));
    _ = button.observe(down, view_button);
    try std.testing.expect(!button.observe(.{ .kind = .up, .x = 1200, .y = 48, .at = 2_000_000 }, view_button));
    _ = button.observe(down, view_button);
    _ = button.observe(.{ .kind = .cancel }, view_button);
    try std.testing.expect(!button.observe(.{ .kind = .up, .x = 1200, .y = 48, .at = 100 }, view_button));
}
test "queue overflow forces cancel and producer quarantine until explicit release" {
    var queue: Queue = .{};
    var stream: Stream = .{};
    for (0..8) |index| try std.testing.expect(queue.push(.{ .kind = .move, .sequence = @intCast(index) }));
    const down = stream.fresh(1, 48, 87, 10).?;
    try std.testing.expect(!queue.push(down));
    _ = stream.cancel(.overflow, 10);
    try std.testing.expectEqual(Kind.cancel, queue.pop().?.kind);
    try std.testing.expect(queue.pop() == null);
    try std.testing.expect(stream.fresh(1, 48, 87, 11) == null);
    _ = stream.fresh(0, 0, 0, 12);
    try std.testing.expectEqual(Kind.down, stream.fresh(1, 48, 87, 13).?.kind);
}
