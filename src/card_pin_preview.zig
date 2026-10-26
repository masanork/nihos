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
export fn nih_card_read_preview(bytes: [*]u8, length: usize, digits: u8, remaining: u8) bool {
    return screen.paintRead(null, bytes[0..length], 1440, .{ .active = true, .masked_digits = digits, .remaining = remaining, .can_submit = digits == 4 });
}
export fn nih_card_result_preview(bytes: [*]u8, length: usize, field: u8) bool {
    const result = @import("graphics/card_read_result.zig");
    var pager = result.Pager{ .field = field };
    _ = result.result(null, bytes[0..length], .{ .name = "テスト 太郎", .address = "東京都千代田区テスト一丁目二番三号", .birth_date = "19900101", .gender = "1" }, &pager) catch return false;
    return true;
}

export fn nih_card_overview_preview(bytes: [*]u8, length: usize) bool {
    const result = @import("graphics/card_read_result.zig");
    _ = result.overview(null, bytes[0..length], .{ .name = "テスト 太郎", .address = "東京都千代田区テスト一丁目二番三号", .birth_date = "19900101", .gender = "1" }, @import("graphics/photo_fixture.zig").pixels) catch return false;
    return true;
}
