//! Shared portrait result controls. No card transport or credential data.
const pin = @import("pin_entry.zig");
pub const Action = enum(u32) { basic = 5, next, close };
pub fn hit(x: u16, y: u16) ?pin.Key {
    if (y < 1080 or y >= 1280 or x >= 720) return null;
    return if (x < 240) .erase else if (x < 480) .submit else .cancel;
}
fn anyTap(_: u16, _: u16) ?pin.Key {
    return .submit;
}
pub const Model = struct {
    // A result screen cannot consume a contact begun on the preceding screen.
    contact: pin.Contact = .{ .held = true },
    mynumber: bool = false,
    pub inline fn sample(self: *Model, contacts: u8, x: u16, y: u16) ?Action {
        const key = if (self.mynumber) self.contact.sample(true, contacts, x, y, anyTap) else self.contact.sample(true, contacts, x, y, hit);
        const selected = key orelse return null;
        return if (self.mynumber or selected == .cancel) .close else if (selected == .erase) .basic else .next;
    }
};

test "result control boundaries and held contact gate are shared with the application" {
    const t = @import("std").testing;
    try t.expect(hit(100, 1079) == null and hit(720, 1140) == null);
    try t.expectEqual(pin.Key.erase, hit(239, 1080).?);
    try t.expectEqual(pin.Key.submit, hit(240, 1279).?);
    try t.expectEqual(pin.Key.cancel, hit(480, 1140).?);
    var model: Model = .{};
    try t.expect(model.sample(1, 350, 1140) == null);
    try t.expect(model.sample(0, 0, 0) == null);
    _ = model.sample(1, 350, 1140);
    try t.expectEqual(Action.next, model.sample(0, 0, 0).?);
    _ = model.sample(1, 100, 1140);
    _ = model.sample(2, 100, 1140);
    try t.expect(model.sample(0, 0, 0) == null);
}
