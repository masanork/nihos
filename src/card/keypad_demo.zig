//! Counts key activations only. There is no PIN array or card transport.
const std = @import("std");
const input = @import("pin_entry.zig");
pub const View = input.View;
pub const Effect = enum(u32) { increment = 1, erase, cancel, confirm };
pub const Model = struct {
    count: u8 = 0,
    increments: u32 = 0,
    erases: u32 = 0,
    cancels: u32 = 0,
    confirms: u32 = 0,
    full: u32 = 0,
    contact: input.Contact = .{},
    pub fn sample(self: *Model, contacts: u8, x: u16, y: u16) ?Effect {
        const key = self.contact.sample(true, contacts, x, y, input.demoHit) orelse return null;
        switch (key) {
            .erase => {
                if (self.count == 0) return null;
                self.count -= 1;
                self.erases += 1;
                return .erase;
            },
            .cancel => {
                self.count = 0;
                self.cancels += 1;
                return .cancel;
            },
            .submit => {
                if (self.count != 4) return null;
                self.count = 0;
                self.confirms += 1;
                return .confirm;
            },
            else => {
                if (self.count == 4) return null;
                self.count += 1;
                self.increments += 1;
                if (self.count == 4) self.full += 1;
                return .increment;
            },
        }
    }
    pub fn view(self: *const Model) input.View {
        return .{ .active = true, .masked_digits = self.count, .remaining = null, .can_submit = self.count == 4 };
    }
};
fn tap(model: *Model, key: input.Key) ?Effect {
    const rect = input.demoBounds(key);
    _ = model.sample(1, rect.x + 10, rect.y + 10);
    return model.sample(0, 0, 0);
}
test "demonstration counts four keys, erases, cancels and confirms without a PIN" {
    var model = Model{};
    for (0..4) |_| try std.testing.expectEqual(Effect.increment, tap(&model, .one).?);
    try std.testing.expect(tap(&model, .two) == null);
    try std.testing.expect(model.view().can_submit);
    try std.testing.expectEqual(Effect.erase, tap(&model, .erase).?);
    try std.testing.expectEqual(@as(u8, 3), model.count);
    _ = tap(&model, .nine);
    try std.testing.expectEqual(Effect.confirm, tap(&model, .submit).?);
    try std.testing.expectEqual(@as(u8, 0), model.count);
    _ = tap(&model, .zero);
    try std.testing.expectEqual(Effect.cancel, tap(&model, .cancel).?);
    try std.testing.expectEqual(@as(u8, 0), model.count);
}
test "held, dragged and multi-contact samples cannot add extra digits" {
    var model = Model{};
    for (0..10) |_| _ = model.sample(1, 100, 550);
    try std.testing.expectEqual(@as(u8, 0), model.count);
    _ = model.sample(1, 400, 550);
    try std.testing.expect(model.sample(0, 0, 0) == null);
    _ = model.sample(2, 100, 550);
    _ = model.sample(1, 100, 550);
    try std.testing.expect(model.sample(0, 0, 0) == null);
    try std.testing.expectEqual(@as(u8, 0), model.count);
}
