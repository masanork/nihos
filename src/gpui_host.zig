//! Experimental GPUI host exports. Shared rendering owns every content pixel.
const xy = @import("xy/c_abi_host.zig");
const view_config = @import("view_config");
const render = @import("xy/render_session.zig");
const plot = @import("graphics/animated_plot.zig");
const canvas = @import("canvas");
const transfer = @import("pixel_transfer");
const max_bytes = 1280 * 720 * 2;
var model = plot.animation.Model{};
// SAFETY: prepared gates rendering; init writes the complete session first.
var labels: render.Session = undefined;
var prepared = false;
var cached_width: u32 = 0;
var cached_height: u32 = 0;
var background: [max_bytes]u8 = undefined;
var completed: [max_bytes]u8 = undefined;
var label_pixels: [1280 * 180 * 2]u8 = undefined;
const mincho: []const u8 = @embedFile("xy/fonts/mincho.ttf");
const gothic: []const u8 = @embedFile("xy/fonts/gothic.ttf");

pub export fn xy_animation_init() callconv(.c) bool {
    prepared = false;
    const unused: [1]xy.CSliceReaderDesc = undefined;
    if (!xy.xy_host_init(&unused, 0, null, 0)) return false;
    labels.init(xy.ttf.SliceReader.fromSlice(&mincho), xy.ttf.SliceReader.fromSlice(&gothic)) catch return false;
    model = .{};
    cached_width = 0;
    cached_height = 0;
    prepared = true;
    const source = "xy / GPUI\n\n日本語表示 あいうえお\n青空文庫\n\nShared TrueType / RGB565\n";
    return xy.xy_host_buffer_replace(source, source.len);
}
pub export fn xy_animation_tick(now_us: u64) callconv(.c) bool {
    return prepared and model.advance(now_us);
}
pub export fn xy_animation_key(key: u8, down: bool, now_us: u64) callconv(.c) bool {
    if (!prepared or key > @backingInt(plot.animation.Key.reset)) return false;
    model.key(@fromBackingInt(@intCast(key)), down, now_us);
    return true;
}
pub export fn xy_animation_focus_lost(now_us: u64) callconv(.c) void {
    if (prepared) model.focusLost(now_us);
}
pub export fn xy_animation_state(out: *plot.animation.State) callconv(.c) void {
    out.* = model.state;
}
fn geometry(width: u32, height: u32) ?usize {
    if (!prepared or width < 240 or height < 180 or width > 1280 or height > 720) return null;
    return @as(usize, width) * height * 2;
}
fn area(width: u32, height: u32) plot.Area {
    return .{ .x = 32, .y = 84, .width = width - 64, .height = height - 148 };
}
fn paint(width: u32, height: u32) bool {
    const length = geometry(width, height) orelse return false;
    if (cached_width != width or cached_height != height) {
        const config = view_config.Config{ .style = .{ .body_px = 25, .margin_x_px = 24, .margin_y_px = 24 } };
        const title = "Graph / shared Canvas";
        const status = "Space: pause   Left/Right: speed   R: reset";
        const request = render.protocol.Request{ .workspace = &labels, .frame = &background, .frame_length = length, .config = &config, .text = title, .text_length = title.len, .cursor = 0, .status = status, .status_length = status.len, .show_cursor = 0 };
        labels.renderLogical(&request, width, height, width * 2) catch return false;
        plot.background(canvas.Canvas.init(background[0..length], width, height, width * 2).?, area(width, height));
        cached_width = width;
        cached_height = height;
    }
    @memcpy(completed[0..length], background[0..length]);
    plot.curves(canvas.Canvas.init(completed[0..length], width, height, width * 2).?, area(width, height), model.state);
    return true;
}
pub export fn xy_animation_render_rgb565(out: [*]u8, capacity: usize, width: u32, height: u32) callconv(.c) bool {
    const length = geometry(width, height) orelse return false;
    if (capacity < length or !paint(width, height)) return false;
    @memcpy(out[0..length], completed[0..length]);
    return true;
}
pub export fn xy_animation_render_bgra8(out: [*]u8, capacity: usize, width: u32, height: u32) callconv(.c) bool {
    const length = geometry(width, height) orelse return false;
    if (capacity < length * 2 or !paint(width, height)) return false;
    transfer.bgra8(completed[0..length], width, height, width * 2, out[0 .. length * 2], width * 4) catch return false;
    return true;
}
pub export fn xy_editor_render_bgra8(out: [*]u8, capacity: usize, width: u32, height: u32) callconv(.c) bool {
    const length = geometry(width, height) orelse return false;
    if (capacity < length * 2 or xy.xy_host_render_rgb565(&completed, width, height, width * 2, 0) < 0) return false;
    transfer.bgra8(completed[0..length], width, height, width * 2, out[0 .. length * 2], width * 4) catch return false;
    return true;
}
pub export fn xy_editor_insert(text: [*]const u8, length: u32) callconv(.c) bool {
    return prepared and xy.xy_host_insert_text(text, length);
}
pub export fn xy_editor_key(key: u8) callconv(.c) bool {
    if (!prepared) return false;
    if (key == 2) return xy.xy_host_handle_key(8);
    if (key == 4) return xy.xy_host_insert_text("\n", 1);
    const expression: []const u8 = switch (key) {
        0 => "(buffer/move-graphemes! -1)",
        1 => "(buffer/move-graphemes! 1)",
        3 => "(buffer/undo!)",
        else => return false,
    };
    var reply: [128]u8 = undefined;
    return xy.xy_host_live_run(expression.ptr, @intCast(expression.len), false, &reply, reply.len) >= 0;
}
/// UI labels use the same font resolution, layout and rasterizer as content.
pub export fn xy_label_render_bgra8(out: [*]u8, capacity: usize, text: [*]const u8, length: u32, width: u32, height: u32, size: u8, foreground: u32, background_rgb: u32, centered: bool) callconv(.c) bool {
    if (!prepared or width < 32 or width > 1280 or height < 24 or height > 180 or size < 8 or size > 64 or height <= size or length > 128 or foreground > 0xffffff or background_rgb > 0xffffff) return false;
    const total = @as(usize, width) * height * 4;
    if (capacity < total) return false;
    const bytes = @as(usize, width) * height * 2;
    const config = view_config.Config{ .style = .{ .body_px = size, .line_gap_px = 0, .margin_x_px = 0, .margin_y_px = @intCast((height - size - 1) / 2) }, .appearance = .{ .foreground = foreground, .background = background_rgb, .status_background = background_rgb, .status_padding = 0 } };
    const request = render.protocol.Request{ .workspace = &labels, .frame = &label_pixels, .frame_length = bytes, .config = &config, .text = text, .text_length = length, .cursor = 0, .status = "", .status_length = 0, .show_cursor = 0 };
    labels.renderLabel(&request, width, height, width * 2, centered) catch return false;
    transfer.bgra8(label_pixels[0 .. @as(usize, width) * height * 2], width, height, width * 2, out[0..total], width * 4) catch return false;
    return true;
}
