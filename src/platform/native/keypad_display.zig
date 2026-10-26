//! Initial sparse plan and frame-boundary swaps of small, double-buffered UI textures.
const card = @import("card");
const timer = @import("timer_group");
const leases = @import("keypad_lease.zig");
const plan = card.KeypadPlan;
extern fn nih_display_keypad_configure(*const plan.Config) callconv(.c) bool;
extern fn nih_display_keypad_buffer() callconv(.c) u32;
extern fn nih_display_keypad_publish(u32, u32) callconv(.c) bool;
extern fn nih_display_keypad_count() callconv(.c) u32;
extern fn nih_rom_cache_writeback(u32, u32, u32) callconv(.c) i32;
pub const Prepared = struct { local: leases.Lease, peer: leases.Lease, nodes: u32, pixel_bytes: u32 };
fn bytes(address: usize, length: usize) []u8 {
    return @as([*]u8, @ptrFromInt(address))[0..length];
}
fn view(count: u8) @import("card").KeypadDemo.View {
    return .{ .active = true, .masked_digits = count, .remaining = null, .can_submit = count == 4 };
}
fn paintTextures(index: u32, count: u8) bool {
    const base = plan.scratch_start + index * plan.textureStride();
    return card.PinScreen.paintDynamic(".flash.rodata.card_pin", bytes(base, plan.dots_bytes), bytes(base + plan.dots_bytes, plan.labelBytes()), view(count));
}
pub fn prepare(clock: timer.Timer, frame: []u8) !Prepared {
    if (!card.PinScreen.paintDemo(".flash.rodata.card_pin", frame, 1440, view(0)) or !paintTextures(0, 0) or !paintTextures(1, 0)) return error.Image;
    const output: [*]plan.Segment = @ptrFromInt(plan.planAddress());
    const spans = try plan.build(frame, output[0..plan.planCapacity()]);
    const started = clock.counter() orelse return error.Timer;
    var peer: ?leases.Lease = leases.peer();
    while (peer == null) {
        const now = clock.counter() orelse return error.Timer;
        if (now - started >= 50_000) return error.Lease;
        peer = leases.peer();
    }
    const local = leases.local() orelse return error.Lease;
    if (spans.len > (@as(usize, local.bytes) + peer.?.bytes) / 64) return error.Lease;
    const dots = card.PinScreen.dots_rect;
    const label = card.PinScreen.submitRect();
    const config = plan.Config{
        .plan = @intCast(plan.planAddress()),
        .count = @intCast(spans.len),
        .peer_start = peer.?.start,
        .peer_bytes = peer.?.bytes,
        .dots_x = dots.x,
        .dots_y = dots.y,
        .dots_width = dots.width,
        .dots_height = dots.height,
        .label_x = label.x,
        .label_y = label.y,
        .label_width = label.width,
        .label_height = label.height,
        .paper = card.PinScreen.paper_color,
        .keys = card.PinScreen.key_color,
        .accent = card.PinScreen.accent_color,
        .scratch = plan.scratch_start,
        .stride = @intCast(plan.textureStride()),
        .capacity = @intCast(plan.planCapacity()),
    };
    if (!nih_display_keypad_configure(&config)) return error.Plan;
    if (nih_rom_cache_writeback((1 << 4) | (1 << 5), plan.scratch_start, plan.scratch_end - plan.scratch_start) != 0) return error.Cache;
    var pixel_bytes: u32 = 0;
    for (spans) |span| if (@backingInt(span.kind) >= 3) {
        pixel_bytes += span.words * 8;
    };
    return .{ .local = local, .peer = peer.?, .nodes = @intCast(spans.len), .pixel_bytes = pixel_bytes };
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
    const address = plan.scratch_start + index * plan.textureStride();
    if (nih_rom_cache_writeback((1 << 4) | (1 << 5), @intCast(address), @intCast(plan.textureStride())) != 0) return error.Cache;
    asm volatile ("fence rw,rw" ::: .{ .memory = true });
    if (!nih_display_keypad_publish(index, count)) return error.Busy;
}
pub fn shown() u32 {
    return nih_display_keypad_count();
}
