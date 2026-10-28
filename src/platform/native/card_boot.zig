//! Display service boot-to-reader handoff. All work is foreground only.
const card = @import("card");
const options = @import("native_options");
const timer = @import("timer_group");
const renderer = @import("display_service").keypad;
const display = @import("display_service").runtime;
extern fn nih_display_scene_mismatches(u32) callconv(.c) u32;
pub const Report = struct { stage: u32, frames: u32, checked: u32, mismatches: u32 };
pub noinline fn report(stage: u32) linksection(".flash.text.card") Report {
    return .{ .stage = stage, .frames = display.snapshot().frames, .checked = @intFromBool(options.card_scene_exercise), .mismatches = if (options.card_scene_exercise) nih_display_scene_mismatches(0x48030000) else 0 };
}
fn frame() []u8 {
    return @as([*]u8, @ptrFromInt(0x48030000))[0 .. 720 * 1280 * 2];
}
pub noinline fn paint() linksection(".flash.text.card") !void {
    renderer.static_frame = true;
    renderer.overview_frame = false;
    renderer.notice_frame = false;
    renderer.scene_paper = card.BootScreen.background;
    if (!card.BootScreen.paint(".flash.rodata.card_boot", frame(), 1440)) return error.BootImage;
}
pub noinline fn finish(clock: timer.Timer, panel: u32) linksection(".flash.text.card") !void {
    // DMA retains its own SRAM copy of the splash throughout preparation.
    renderer.static_frame = false;
    renderer.overview_frame = false;
    renderer.notice_frame = false;
    renderer.scene_paper = card.PinScreen.paper_color;
    if (options.card_auto) try @import("card_auto.zig").prepare(clock, panel) else try @import("card_read.zig").prepare(clock, panel);
    clock.start();
    clock.disarm();
    defer clock.stop();
    const result = display.replace(clock, panel);
    if (result.status != 1) return error.BootHandoff;
}
