//! Small borrowed-surface application example for the emulator fixture.
//! The host owns input, frame memory, presentation and the app's lifetime.
const canvas = @import("canvas");
const pointer = @import("pointer_input");
const std = @import("std");

pub const App = struct {
    button: pointer.Button = .{},
    active: bool = false,
    clicks: u32 = 0,
    const hit: pointer.Rect = .{ .x = 1120, .y = 48, .width = 96, .height = 624 };

    /// Input coordinates are logical landscape coordinates from pointer.Stream.
    /// Returns true only when the visible state changes.
    pub fn onEvent(self: *App, event: pointer.Event) bool {
        if (!self.button.observe(event, hit)) return false;
        self.active = !self.active;
        self.clicks += 1;
        return true;
    }

    /// Paints only this example's indicator into a host-owned portrait frame.
    pub fn render(self: *const App, frame: []u8) bool {
        const c = canvas.Canvas.init(frame, 720, 1280, 1440) orelse return false;
        c.fillRect(.{ .x = 48, .y = 64, .width = 624, .height = 96 }, if (self.active) 0x07e0 else 0xffff);
        return true;
    }
};

test "application changes its borrowed pixels only on valid release" {
    const frame = try std.testing.allocator.alloc(u8, 720 * 1280 * 2);
    defer std.testing.allocator.free(frame);
    @memset(frame, 0);
    var app = App{};
    try std.testing.expect(!app.render(frame[0..20]));
    try std.testing.expect(app.render(frame));
    const pixel = 64 * 1440 + 48 * 2;
    try std.testing.expectEqual(@as(u16, 0xffff), std.mem.readInt(u16, frame[pixel..][0..2], .little));
    const down: pointer.Event = .{ .kind = .down, .x = 1150, .y = 200, .at = 100 };
    const up: pointer.Event = .{ .kind = .up, .x = 1150, .y = 200, .at = 200 };
    try std.testing.expect(!app.onEvent(down));
    try std.testing.expect(app.onEvent(up));
    try std.testing.expect(app.render(frame));
    try std.testing.expectEqual(@as(u16, 0x07e0), std.mem.readInt(u16, frame[pixel..][0..2], .little));
    try std.testing.expectEqual(@as(u32, 1), app.clicks);
    try std.testing.expect(!app.onEvent(.{ .kind = .down, .x = 1150, .y = 200, .at = 300 }));
    try std.testing.expect(!app.onEvent(.{ .kind = .cancel, .at = 400 }));
    try std.testing.expect(!app.onEvent(.{ .kind = .up, .x = 1150, .y = 200, .at = 500 }));
    try std.testing.expectEqual(@as(u32, 1), app.clicks);
}
