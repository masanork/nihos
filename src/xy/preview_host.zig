//! Host inspection of the actual Tab5 scene renderer, with caller-owned ROM data.
const reading = @import("native_reading.zig");
const catalog = @import("catalog.zig");
const navigation = @import("navigation.zig");
const protocol = @import("render_protocol.zig");
// SAFETY: ready gates every use; initSlices initializes the stable owner before publication.
var instance: reading.Session = undefined;
// SAFETY: ready remains false until Pack.init validates the borrowed ROM range.
var pack: catalog.Pack = undefined;
// SAFETY: xy_tab5_init initializes lessons before any input or render.
var lessons: @import("learning_session.zig").Session = undefined;
var nav: navigation.State = .{};
var config: protocol.Config = .{};
var ready = false;
var last_error: u32 = 0;
pub export fn xy_tab5_init(data: [*]const u8, len: u32) callconv(.c) bool {
    ready = false;
    pack = catalog.Pack.init(data[0..len]) catch return false;
    instance.initSlices(pack.font(0) catch return false, pack.font(1) catch return false) catch return false;
    lessons.initInPlace();
    if (pack.learningBytes() catch return false) |data_bytes| lessons.bind(data_bytes) catch return false;
    nav = .{};
    config = .{};
    config.style.body_px = 32;
    config.style.ruby_px = 16;
    nav.chapter_count = pack.counts() catch return false;
    nav.home();
    ready = true;
    return true;
}
pub export fn xy_tab5_key(key: u8) callconv(.c) void {
    if (!ready) return;
    const event: navigation.Key = switch (key) {
        13, 10 => .enter,
        3 => .cancel,
        4 => .eof,
        8, 127 => .backspace,
        12 => .clear,
        26 => .undo,
        27 => .escape,
        128 => .up,
        129 => .down,
        130 => .left,
        131 => .right,
        else => .{ .text = key },
    };
    if (nav.screen == .examples or nav.screen == .exercise) lessons.handle(&nav, event) else nav.handle(event, &config);
}
pub export fn xy_tab5_touch(x: u32, y: u32) callconv(.c) void {
    if (!ready) return;
    if (nav.screen == .examples or nav.screen == .exercise) lessons.touch(&nav, x, y) else nav.touch(x, y, &config);
}
pub export fn xy_tab5_state(field: u32) callconv(.c) u32 {
    return switch (field) {
        0 => @backingInt(nav.screen),
        1 => nav.book,
        2 => nav.chapter,
        3 => nav.offset,
        4 => nav.end,
        5 => instance.glyphs,
        6 => config.style.body_px,
        7 => config.style.axis,
        8 => last_error,
        9 => nav.text_length,
        else => 0,
    };
}
pub export fn xy_tab5_render(pixels: [*]u8, len: u32) callconv(.c) bool {
    if (!ready or len != 720 * 1280 * 2) return false;
    const req = protocol.Request{ .learning = &lessons, .workspace = &instance, .navigation = &nav, .frame = pixels, .frame_length = len, .config = &config, .text = "", .text_length = 0, .cursor = 0, .status = "", .status_length = 0, .show_cursor = 0 };
    reading.render(&instance, &req, pack) catch |err| {
        last_error = @intFromError(err);
        return false;
    };
    return true;
}

pub export fn xy_tab5_learning_replace(text: [*]const u8, length: u32) callconv(.c) bool {
    if (!ready or nav.screen != .exercise) return false;
    lessons.replace(text[0..length]) catch return false;
    return true;
}
pub export fn xy_tab5_learning_copy(field: u32, out: [*]u8, cap: u32) callconv(.c) i32 {
    if (!ready) return -1;
    const s = lessons.slot() orelse return -1;
    const text = switch (field) {
        0 => s.code.slice(),
        1 => s.notes.slice(),
        2 => s.result[0..s.result_len],
        else => return -1,
    };
    if (text.len > cap) return -1;
    @memcpy(out[0..text.len], text);
    return @intCast(text.len);
}
