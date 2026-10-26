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
