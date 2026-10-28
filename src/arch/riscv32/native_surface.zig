//! Finite composition driver, not a paragraph/ruby layout policy or scanout.
const std = @import("std");
const policy = @import("japanese_break");
const layout = policy.layout;
const options = @import("native_options");
const surface = @import("surface");
const protocol = @import("font_protocol");
const heap = @import("native_memory").reusable;
extern fn nih_native_task_failed() callconv(.c) noreturn;
pub const width = 192;
pub const height = 96;
pub const stride = 400;
pub const Report = struct {
    frames: u32 = 0,
    blits: u32 = 0,
    clipped: u32 = 0,
    guards: u32 = 0,
    rejected: u32 = 0,
    peak_charge: u32 = 0,
    live_charge: u32 = 0,
};
pub var metrics: Report = .{};
pub const WrapReport = struct { frames: u32 = 0, clusters: u32 = 0, lines: u32 = 0, wrapped_runs: u32 = 0, transitions: u32 = 0, clipped: u32 = 0 };
pub var wrap_metrics: WrapReport = .{};
pub const PolicyReport = struct { frames: u32 = 0, spans: u32 = 0, joined: u32 = 0, lines: u32 = 0, transitions: u32 = 0, clipped: u32 = 0 };
pub var policy_metrics: PolicyReport = .{};
pub const Placement = struct { paint_pc: u32 = 0, draw_pc: u32 = 0, frames: u32 = 0, draws: u32 = 0, context_checks: u32 = 0, irq_rejected: u32 = 0, active_ticks: u32 = 0, flash_ticks: u32 = 0, trap_pc: u32 = 0 };
pub var placement: Placement = .{};
var painting: bool = false;
extern var __flash_render_start: u8;
extern var __flash_render_end: u8;

// Only the fixture's CPU0 bootstrap consumer may enter, with MIE set. This
// check and the timer probe remain SRAM code and touch no PSRAM/Flash input.
noinline fn contextAllowed() bool {
    const identity = heap.currentIdentity() catch return false;
    return identity >> 16 == 0;
}
pub noinline fn captureTimer(pc: u32) void {
    if (contextAllowed()) nih_native_task_failed();
    placement.irq_rejected += 1;
    if (!@as(*const volatile bool, &painting).*) return;
    placement.active_ticks += 1;
    if (pc >= @intFromPtr(&__flash_render_start) and pc < @intFromPtr(&__flash_render_end)) {
        placement.flash_ticks += 1;
        placement.trap_pc = pc;
    }
}
// Qualification uses canonical immutable source bytes, not the poisoned caller
// packet. Native dynamic source-to-boundary preparation remains a separate gate.
const Maps = struct { body: []const policy.Boundary, ruby: []const policy.Boundary };
// Immutable boundaries use the existing loader-mapped display-data span.
// Rendering already requires active Flash mappings; no executable kernel code moves.
fn SourceMap(comptime index: usize, comptime ruby: bool) type {
    return struct {
        const value linksection(".flash.rodata.display") = policy.forText(if (ruby) options.font_text_cases[index].ruby else options.font_text_cases[index].body);
    };
}
const maps: [options.font_text_cases.len]Maps linksection(".flash.rodata.display") = blk: {
    var result: [options.font_text_cases.len]Maps = @splat(.{ .body = &.{}, .ruby = &.{} });
    for (0..options.font_text_cases.len) |i| {
        result[i] = .{ .body = &SourceMap(i, false).value, .ruby = &SourceMap(i, true).value };
    }
    break :blk result;
};
pub const Result = struct { surface_hash: u32 = 0, wrap_hash: u32 = 0, policy_hash: u32 = 0 };
fn digest(bytes: []const u8) u32 {
    var value: u32 = 2166136261;
    for (bytes) |byte| value = (value ^ byte) *% 16777619;
    return value;
}
pub noinline fn compose(reply: *const protocol.Reply, pixels: []const u8) Result {
    if (!contextAllowed()) nih_native_task_failed();
    placement.context_checks += 1;
    const before = heap.availableBytes() orelse nih_native_task_failed();
    const allocation = heap.allocTask(stride * height + 64, 16) catch nih_native_task_failed();
    const charge: u32 = @intCast(before - (heap.availableBytes() orelse nih_native_task_failed()));
    metrics.peak_charge = @max(metrics.peak_charge, charge);
    metrics.live_charge = charge;
    @memset(allocation.bytes, 0xa5);
    const data = allocation.bytes[32..][0 .. stride * height];
    const target = surface.Surface.init(data, width, height, stride) orelse nih_native_task_failed();
    @as(*volatile bool, &painting).* = true;
    const result = paint(&target, data, reply, pixels);
    @as(*volatile bool, &painting).* = false;
    if (!contextAllowed() or !@import("native_memory").stacks.bootGuardsIntact(0)) nih_native_task_failed();
    placement.context_checks += 1;
    for (0..height) |y| if (!std.mem.allEqual(u8, data[y * stride + width * 2 ..][0 .. stride - width * 2], 0xa5)) nih_native_task_failed();
    if (!std.mem.allEqual(u8, allocation.bytes[0..32], 0xa5) or !std.mem.allEqual(u8, allocation.bytes[32 + stride * height ..], 0xa5)) nih_native_task_failed();
    metrics.guards += 1;
    heap.freeTask(allocation) catch nih_native_task_failed();
    if ((heap.availableBytes() orelse nih_native_task_failed()) != before) nih_native_task_failed();
    metrics.live_charge = 0;
    metrics.frames += 1;
    return result;
}

// Borrowed buffers only. The SRAM wrapper owns allocation and retirement.
noinline fn paint(target: *const surface.Surface, data: []u8, reply: *const protocol.Reply, pixels: []const u8) linksection(".flash.text.render") Result {
    placement.paint_pc = asm volatile ("auipc %[pc], 0"
        : [pc] "=r" (-> u32),
    );
    placement.frames += 1;
    var result: Result = .{};
    const vertical = reply.id == 8;
    const glyphs = reply.output.glyphs[0..reply.output.count];
    for (0..3) |pass| {
        const wrapped = pass != 0;
        const prohibited = pass == 2;
        if (!target.fill(0xf79e)) nih_native_task_failed();
        const body_limit: i32 = if (!wrapped) std.math.maxInt(i32) else if (vertical) 64 * 64 else if (prohibited and reply.id == 9) 80 * 64 else 96 * 64;
        const capacity: u16 = if (!wrapped) 1 else if (prohibited) (if (vertical) @as(u16, 4) else 3) else (if (vertical) @as(u16, 3) else 2);
        var flows = [_]layout.Flow{
            layout.Flow.init(body_limit, (if (vertical) @as(i32, 40) else 32) * 64, capacity) catch nih_native_task_failed(),
            layout.Flow.init(if (wrapped) 96 * 64 else std.math.maxInt(i32), (if (vertical) @as(i32, 40) else 16) * 64, 1) catch nih_native_task_failed(),
        };
        if (prohibited and vertical) _ = flows[0].place(32 * 64) catch nih_native_task_failed();
        var start: usize = 0;
        while (start < glyphs.len) {
            const run = glyphs[start].run;
            const boundaries = if (run == 0) maps[reply.id - 5].body else maps[reply.id - 5].ruby;
            const group = (if (prohibited) policy.span(protocol.Glyph, glyphs, start, if (vertical) .vertical else .horizontal, boundaries) else layout.cluster(protocol.Glyph, glyphs, start, if (vertical) .vertical else .horizontal)) catch nih_native_task_failed();
            const position = flows[run].place(group.advance) catch nih_native_task_failed();
            var px: i64 = if (vertical) -@as(i64, position.block_offset) else position.inline_offset;
            var py: i64 = if (vertical) -@as(i64, position.inline_offset) else -@as(i64, position.block_offset);
            for (glyphs[start..group.end]) |g| {
                const ox: i64 = if (vertical) (if (run == 0) @as(i64, 150) else 178) else if (!wrapped and reply.id == 9) -8 else 8;
                const oy: i64 = if (vertical) 8 else if (run == 1) 18 else if (reply.id == 9) (if (wrapped) @as(i64, 32) else 80) else 48;
                const clipped = draw(target, pixels, &g, px, py, ox, oy);
                if (prohibited) {
                    if (clipped) policy_metrics.clipped += 1;
                } else if (wrapped) {
                    if (clipped) wrap_metrics.clipped += 1;
                } else {
                    metrics.blits += 1;
                    if (clipped) metrics.clipped += 1;
                }
                px += g.x_advance;
                py += g.y_advance;
            }
            if (prohibited) policy_metrics.spans += 1 else if (wrapped) {
                wrap_metrics.clusters += 1;
            }
            start = group.end;
        }
        const value = digest(data);
        if (!wrapped) {
            result.surface_hash = value;
            const first = glyphs[0];
            if (target.blit(.{ .bytes = pixels[first.pixel_offset..][0 .. first.width * first.height - 1], .width = first.width, .height = first.height, .stride = first.width }, 0, 0, 0)) nih_native_task_failed();
            if (target.blit(.{ .bytes = data[0..1], .width = 1, .height = 1, .stride = 1 }, 0, 0, 0)) nih_native_task_failed();
            metrics.rejected += 2;
            if (digest(data) != value) nih_native_task_failed();
        } else {
            for (flows) |flow| {
                const lines = flow.lines();
                if (prohibited) policy_metrics.lines += lines else wrap_metrics.lines += lines;
                if (lines > 1) {
                    if (prohibited) policy_metrics.transitions += lines - 1 else {
                        wrap_metrics.wrapped_runs += 1;
                        wrap_metrics.transitions += lines - 1;
                    }
                }
            }
            if (prohibited) {
                policy_metrics.joined = wrap_metrics.clusters - policy_metrics.spans;
                result.policy_hash = value;
                policy_metrics.frames += 1;
            } else {
                result.wrap_hash = value;
                wrap_metrics.frames += 1;
            }
        }
    }
    return result;
}

// Keep one checked pixel-placement path for all three diagnostic passes.
noinline fn draw(target: *const surface.Surface, pixels: []const u8, g: *const protocol.Glyph, px: i64, py: i64, ox: i64, oy: i64) linksection(".flash.text.render") bool {
    placement.draw_pc = asm volatile ("auipc %[pc], 0"
        : [pc] "=r" (-> u32),
    );
    placement.draws += 1;
    const x = std.math.cast(i32, ox + @divFloor(px + g.x_offset, 64) + g.left) orelse nih_native_task_failed();
    const y = std.math.cast(i32, oy - @divFloor(py + g.y_offset, 64) - g.top) orelse nih_native_task_failed();
    if (!target.blit(.{ .bytes = pixels[g.pixel_offset..][0 .. g.width * g.height], .width = g.width, .height = g.height, .stride = g.width }, x, y, if (g.run == 0) 0x192b else 0xb9a7)) nih_native_task_failed();
    return x < 0 or y < 0 or @as(i64, x) + g.width > width or @as(i64, y) + g.height > height;
}
