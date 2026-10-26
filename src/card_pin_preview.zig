//! Host preview bridge; does not open a reader or collect a PIN.
const screen = @import("graphics/card_pin.zig");
export fn nih_card_pin_preview(bytes: [*]u8, length: usize, digits: u8, active: bool) bool {
    return screen.paint(bytes[0..length], 1440, .{
        .active = active,
        .masked_digits = digits,
        .remaining = 3,
        .can_submit = active and digits == 4,
    });
}
export fn nih_keypad_demo_preview(bytes: [*]u8, length: usize, digits: u8, active: bool) bool {
    return screen.paintDemo(null, bytes[0..length], 1440, .{ .active = active, .masked_digits = digits, .remaining = null, .can_submit = active and digits == 4 });
}
export fn nih_keypad_demo_plan(bytes: [*]const u8, length: usize) usize {
    const plan = @import("graphics/keypad_plan.zig");
    var spans: [2048]plan.Segment = undefined;
    return (plan.build(bytes[0..length], &spans) catch return 0).len;
}
export fn nih_keypad_copy_plan(bytes: [*]const u8, length: usize, out: [*]@import("graphics/keypad_plan.zig").Segment, capacity: usize) usize {
    return (@import("graphics/keypad_plan.zig").build(bytes[0..length], out[0..capacity]) catch return 0).len;
}
