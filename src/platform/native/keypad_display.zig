//! Initial sparse plan and frame-boundary swaps of small, double-buffered UI textures.
const card = @import("card");
const timer = @import("timer_group");
const plan = card.KeypadPlan;
const options = @import("native_options");
pub var read_remaining: ?u8 = null;
pub var static_frame = false;
pub var overview_frame = false;
pub var demo_frame = false;
pub var pin_kind: u8 = 0;
pub var notice_frame = false;
pub var scene_paper: u16 = card.PinScreen.paper_color;
extern fn nih_display_keypad_configure(*const plan.Config) callconv(.c) bool;
extern fn nih_display_keypad_buffer() callconv(.c) u32;
extern fn nih_display_keypad_publish(u32, u32) callconv(.c) bool;
extern fn nih_display_keypad_count() callconv(.c) u32;
extern fn nih_display_notice_publish(u32) callconv(.c) bool;
extern fn nih_rom_cache_writeback(u32, u32, u32) callconv(.c) i32;
const sram = @import("native_tasks").memory.dma;
const Lease = sram.Lease;
extern fn nih_display_keypad_memory(u32, u32, u32, u32) callconv(.c) bool;
extern fn nih_display_keypad_idle() callconv(.c) bool;
extern fn nih_display_keypad_fits(*const plan.Config, u32, u32, bool) callconv(.c) bool;
var leases: [2]Lease = .{ .{}, .{} };
pub var low_start: u32 = 0;
pub var low_end: u32 = 0;
pub var high_start: u32 = 0;
pub var high_end: u32 = 0;
noinline fn acquire() linksection(if (options.card_read) ".flash.text.card" else ".text") !void {
    if (leases[0].owner != 0 and leases[1].owner != 0) return;
    if (leases[0].owner != 0 or leases[1].owner != 0) return error.Lease;
    // Bounded budgets, not fixed addresses. The base may grant less when
    // other services own SRAM; stage() validates the actual candidate fit.
    leases[0] = sram.take(sram.display_owner, 64 * 1024, 128 * 1024) orelse return error.Lease;
    leases[1] = sram.take(sram.display_owner, 8 * 1024, 188 * 1024) orelse {
        if (sram.release(leases[0])) leases[0] = .{};
        return error.Lease;
    };
    low_start = leases[0].start;
    low_end = low_start + leases[0].bytes;
    high_start = leases[1].start;
    high_end = high_start + leases[1].bytes;
    if (!nih_display_keypad_memory(low_start, low_end, high_start, high_end)) {
        _ = release();
        return error.Lease;
    }
}
/// Caller must have confirmed that all display DMA references are retired.
pub noinline fn release() linksection(if (options.card_read) ".flash.text.card" else ".text") bool {
    if (!nih_display_keypad_idle()) return false;
    var ok = true;
    for (&leases, 0..) |*lease, index| if (lease.owner != 0) {
        if (!sram.release(lease.*)) {
            ok = false;
        } else {
            lease.* = .{};
            if (index == 0) {
                low_start = 0;
                low_end = 0;
            } else {
                high_start = 0;
                high_end = 0;
            }
        }
    };
    if (ok) {
        low_start = 0;
        low_end = 0;
        high_start = 0;
        high_end = 0;
    }
    return ok;
}
pub const Prepared = struct { local_start: u32, local_bytes: u32, nodes: u32, pixel_bytes: u32, font_low: u32, font_low_bytes: u32 };
pub const Staged = struct { config: plan.Config, prepared: Prepared };
pub noinline fn publishNotice(frame: []const u8) linksection(if (options.card_auto) ".flash.photo" else ".text") !void {
    if (!options.card_auto or !notice_frame or !static_frame) return error.Plan;
    const out = @as([*]plan.Segment, @ptrFromInt(plan.scratch_start))[0..plan.planCapacity()];
    const spans = try plan.buildStatic(frame, out);
    if (!nih_display_notice_publish(@intCast(spans.len))) return error.Plan;
}
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
/// CPU-only PSRAM work. The live display borrows copied SRAM pixels/LLIs,
/// never this framebuffer or plan; do not touch either SRAM pool here.
pub noinline fn stage(frame: []u8) linksection(if (options.card_read) ".flash.text.card" else ".text") !Staged {
    try acquire();
    const atlas = card.KeypadAtlas.Store(".flash.keypad");
    const spans = if (options.card_read) runtime: {
        if (!static_frame) {
            const painted = if (demo_frame) card.PinScreen.paintDemo(".flash.rodata.card_pin", frame, 1440, view(0)) else card.PinScreen.paintRead(".flash.rodata.card_pin", frame, 1440, .{ .active = true, .masked_digits = 0, .remaining = read_remaining, .can_submit = false });
            if (!painted) return error.Image;
            if (options.card_auto and pin_kind != 0) try card.ResultScreen.licensePinHeader(".flash.keypad.auto_font", frame, pin_kind);
        }
        const out = @as([*]plan.Segment, @ptrFromInt(plan.scratch_start))[0..plan.planCapacity()];
        break :runtime if (overview_frame) try plan.buildOverview(frame, out) else if (static_frame) try plan.buildStaticColor(frame, out, scene_paper) else try plan.build(frame, out);
    } else card.KeypadAtlas.segments(".flash.keypad");
    const descriptor_start = low_start + (if (static_frame) @as(usize, 0) else 2 * plan.textureStride());
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
        .paper = scene_paper,
        .keys = card.PinScreen.key_color,
        .accent = card.PinScreen.accent_color,
        .scratch = low_start,
        .stride = if (static_frame) 0 else @intCast(plan.textureStride()),
        .capacity = @intCast(plan.planCapacity()),
        .pixels = if (options.card_read) 0x48030000 else @intFromPtr(&atlas.pixels),
        .pixels_bytes = if (options.card_read) frame.len else atlas.pixels.len,
    };
    // No SRAM or live scene changes until the exact candidate fits.
    if (!nih_display_keypad_fits(&config, @intCast(descriptor_start), @intCast(descriptor_bytes), options.card_auto and notice_frame)) return error.Lease;
    var pixel_bytes: u32 = 0;
    for (spans) |span| if (@backingInt(span.kind) >= 3) {
        pixel_bytes += span.words * 8;
    };
    const font_low: u32 = @intCast(descriptor_start + descriptor_bytes);
    return .{ .config = config, .prepared = .{ .local_start = @intCast(descriptor_start), .local_bytes = @intCast(descriptor_bytes), .nodes = @intCast(spans.len), .pixel_bytes = pixel_bytes, .font_low = font_low, .font_low_bytes = low_end - font_low } };
}
/// Requires quiesced DMA. Only now may the old SRAM textures be overwritten.
pub noinline fn bind(staged: *const Staged) linksection(if (options.card_read) ".flash.text.card" else ".text") !Prepared {
    if (!static_frame and (!paintTextures(0, 0) or !paintTextures(1, 0))) return error.Image;
    if (!nih_display_keypad_configure(&staged.config)) return error.Plan;
    if (staged.config.stride != 0 and nih_rom_cache_writeback(1 << 4, low_start, 2 * staged.config.stride) != 0) return error.Cache;
    return staged.prepared;
}
pub noinline fn prepare(clock: timer.Timer, frame: []u8) linksection(if (options.card_read) ".flash.text.card" else ".text") !Prepared {
    _ = clock;
    const staged = try stage(frame);
    return bind(&staged);
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
