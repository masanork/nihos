//! Initial sparse plan and frame-boundary swaps of small, double-buffered UI textures.
const card = @import("card");
const timer = @import("timer_group");
const plan = card.KeypadPlan;
const options = @import("native_options");
pub var read_remaining: ?u8 = null;
pub var static_frame = false;
pub var overview_frame = false;
extern fn nih_display_keypad_configure(*const plan.Config) callconv(.c) bool;
extern fn nih_display_keypad_buffer() callconv(.c) u32;
extern fn nih_display_keypad_publish(u32, u32) callconv(.c) bool;
extern fn nih_display_keypad_count() callconv(.c) u32;
extern fn nih_rom_cache_writeback(u32, u32, u32) callconv(.c) i32;
pub const low_start: u32 = 0x4ff40000;
pub const low_end: u32 = 0x4ff60000;
pub const high_start: u32 = 0x4ff70000;
pub const high_end: u32 = 0x4ff9f000;
pub const Prepared = struct { local_start: u32, local_bytes: u32, nodes: u32, pixel_bytes: u32, font_low: u32, font_low_bytes: u32 };
fn bytes(address: usize, length: usize) []u8 {
    return @as([*]u8, @ptrFromInt(address))[0..length];
}
fn view(count: u8) @import("card").KeypadDemo.View {
    return .{ .active = true, .masked_digits = count, .remaining = null, .can_submit = count == 4 };
}
noinline fn paintTextures(index: u32, count: u8) linksection(if (options.card_read) ".flash.text.card" else ".text") bool {
    const base = low_start + index * plan.textureStride();
    return card.PinScreen.paintDynamic(".flash.rodata.card_pin", bytes(base, plan.dots_bytes), bytes(base + plan.dots_bytes, plan.labelBytes()), view(count));
}
pub noinline fn prepare(clock: timer.Timer, frame: []u8) linksection(if (options.card_read) ".flash.text.card" else ".text") !Prepared {
    _ = clock;
    if (!static_frame and (!paintTextures(0, 0) or !paintTextures(1, 0))) return error.Image;
    const atlas = card.KeypadAtlas.Store(".flash.keypad");
    const spans = if (options.card_read) runtime: {
        if (!static_frame and !card.PinScreen.paintRead(".flash.rodata.card_pin", frame, 1440, .{ .active = true, .masked_digits = 0, .remaining = read_remaining, .can_submit = false })) return error.Image;
        const out = @as([*]plan.Segment, @ptrFromInt(plan.scratch_start))[0..plan.planCapacity()];
        break :runtime if (overview_frame) try plan.buildOverview(frame, out) else if (static_frame) try plan.buildStatic(frame, out) else try plan.build(frame, out);
    } else card.KeypadAtlas.segments(".flash.keypad");
    const descriptor_start = low_start + 2 * plan.textureStride();
    const descriptor_bytes = spans.len * 64;
    if (descriptor_bytes > low_end - descriptor_start) return error.Lease;
    const dots = card.PinScreen.dots_rect;
    const label = card.PinScreen.submitRect();
    const config = plan.Config{
        .plan = if (options.card_read) plan.scratch_start else @intFromPtr(&atlas.spans),
        .count = @intCast(spans.len),
        .peer_start = 0,
        .peer_bytes = 0,
        .dots_x = dots.x,
        .dots_y = dots.y,
        .dots_width = dots.width,
        .dots_height = dots.height,
        .label_x = label.x,
        .label_y = label.y,
        .label_width = label.width,
        .label_height = if (static_frame) 0 else label.height,
        .paper = card.PinScreen.paper_color,
        .keys = card.PinScreen.key_color,
        .accent = card.PinScreen.accent_color,
        .scratch = low_start,
        .stride = @intCast(plan.textureStride()),
        .capacity = @intCast(plan.planCapacity()),
        .pixels = if (options.card_read) 0x48030000 else @intFromPtr(&atlas.pixels),
        .pixels_bytes = if (options.card_read) frame.len else atlas.pixels.len,
    };
    if (!nih_display_keypad_configure(&config)) return error.Plan;
    if (nih_rom_cache_writeback(1 << 4, low_start, @intCast(2 * plan.textureStride())) != 0) return error.Cache;
    var pixel_bytes: u32 = 0;
    for (spans) |span| if (@backingInt(span.kind) >= 3) {
        pixel_bytes += span.words * 8;
    };
    const font_low: u32 = @intCast(descriptor_start + descriptor_bytes);
    return .{ .local_start = @intCast(descriptor_start), .local_bytes = @intCast(descriptor_bytes), .nodes = @intCast(spans.len), .pixel_bytes = pixel_bytes, .font_low = font_low, .font_low_bytes = low_end - font_low };
}
pub fn update(count: u8) !void {
    const index = nih_display_keypad_buffer();
    if (index > 1) return error.Busy;
    if (!paintTextures(index, count)) return error.Image;
    const status = asm volatile ("csrrci %[value],mstatus,8"
        : [value] "=r" (-> u32),
        :
        : .{ .memory = true });
    defer if (status & 8 != 0) asm volatile ("csrsi mstatus,8" ::: .{ .memory = true });
    const address = low_start + index * plan.textureStride();
    if (nih_rom_cache_writeback(1 << 4, @intCast(address), @intCast(plan.textureStride())) != 0) return error.Cache;
    asm volatile ("fence rw,rw" ::: .{ .memory = true });
    if (!nih_display_keypad_publish(index, count)) return error.Busy;
}
pub fn shown() u32 {
    return nih_display_keypad_count();
}
