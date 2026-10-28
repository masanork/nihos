//! Finite composition driver, not a paragraph/ruby layout policy or scanout.
const std = @import("std");
const text = @import("text_context");
const ruby = text.ruby;
pub const Context = text.Context;
const policy = ruby.policy;
const layout = policy.layout;
const surface = @import("surface");
const protocol = text.protocol;
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
pub const RubyReport = struct { frames: u32 = 0, groups: u32 = 0, moved: u32 = 0, wide: u32 = 0, units: u32 = 0, joins: u32 = 0, lines: u32 = 0, clipped: u32 = 0, plan_bytes: u32 = @sizeOf(ruby.Plan(16)), scratch_bytes: u32 = ruby.scratchBytes(16) };
pub var ruby_metrics: RubyReport = .{};
pub const SourceReport = struct { input_pc: u32 = 0, prepare_pc: u32 = 0, verify_pc: u32 = 0, staged: u32 = 0, maps: u32 = 0, rejected: u32 = 0, edited: u32 = 0, poisoned: u32 = 0, echoed: u32 = 0, stale: u32 = 0, content: u32 = 0, annotations: u32 = 0, map_mutations: u32 = 0, wrong_reply: u32 = 0 };
pub var source_metrics: SourceReport = .{};
pub noinline fn stage(out: *Context, revision: u32, render: protocol.Render, annotations: []const ruby.Annotation) text.Error!void {
    if (!contextAllowed()) nih_native_task_failed();
    prepare(out, revision, render, annotations) catch |err| {
        source_metrics.rejected += 1;
        return err;
    };
    if (!@import("native_memory").stacks.bootGuardsIntact(0)) nih_native_task_failed();
    source_metrics.staged += 1;
    source_metrics.maps += 2;
}
pub noinline fn verifySource(source: *Context, revision: u32, source_hash: u32) text.Error!void {
    if (!contextAllowed()) nih_native_task_failed();
    return verify(source, revision, source_hash, false);
}
noinline fn verify(source: *Context, revision: u32, source_hash: u32, probe: bool) linksection(".flash.text.render") text.Error!void {
    source_metrics.verify_pc = asm volatile ("auipc %[pc], 0"
        : [pc] "=r" (-> u32),
    );
    if (probe) {
        if (checkSource(source, revision - 1, source_hash)) |_| nih_native_task_failed() else |err| {
            if (err != error.Revision) nih_native_task_failed();
            source_metrics.stale += 1;
        }
        if (checkSource(source, revision, source_hash ^ 1)) |_| nih_native_task_failed() else |err| {
            if (err != error.ReplySource) nih_native_task_failed();
            source_metrics.wrong_reply += 1;
        }
        source.render.body[0] ^= 1;
        const changed_body = checkSource(source, revision, source_hash);
        source.render.body[0] ^= 1;
        if (changed_body) |_| nih_native_task_failed() else |err| {
            if (err != error.Integrity) nih_native_task_failed();
            source_metrics.content += 1;
        }
        source.annotation_count ^= 1;
        const changed_annotations = checkSource(source, revision, source_hash);
        source.annotation_count ^= 1;
        if (changed_annotations) |_| nih_native_task_failed() else |err| {
            if (err != error.Integrity) nih_native_task_failed();
            source_metrics.annotations += 1;
        }
        source.body_map[0].allowed = !source.body_map[0].allowed;
        const changed_map = checkSource(source, revision, source_hash);
        source.body_map[0].allowed = !source.body_map[0].allowed;
        if (changed_map) |_| nih_native_task_failed() else |err| {
            if (err != error.Integrity) nih_native_task_failed();
            source_metrics.map_mutations += 1;
        }
        checkSource(source, revision, source_hash) catch nih_native_task_failed();
    }
    return checkSource(source, revision, source_hash);
}
noinline fn checkSource(source: *const Context, revision: u32, source_hash: u32) linksection(".flash.text.render") text.Error!void {
    return source.check(revision, source_hash);
}
noinline fn prepare(out: *Context, revision: u32, render: protocol.Render, annotations: []const ruby.Annotation) linksection(".flash.text.render") text.Error!void {
    source_metrics.prepare_pc = asm volatile ("auipc %[pc], 0"
        : [pc] "=r" (-> u32),
    );
    return Context.initInto(out, revision, render, annotations);
}
pub const Placement = struct { paint_pc: u32 = 0, draw_pc: u32 = 0, frames: u32 = 0, draws: u32 = 0, context_checks: u32 = 0, irq_rejected: u32 = 0, active_ticks: u32 = 0, flash_ticks: u32 = 0, trap_pc: u32 = 0 };
pub var placement: Placement = .{};
var painting: bool = false;
extern var __flash_render_start: u8;
extern var __flash_render_end: u8;

// Only the fixture's CPU0 bootstrap consumer may enter, with MIE set. This
// check and the timer probe remain SRAM code and touch no PSRAM/Flash input.
pub noinline fn contextAllowed() bool {
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
pub const Result = struct { surface_hash: u32 = 0, wrap_hash: u32 = 0, policy_hash: u32 = 0, ruby_hash: u32 = 0 };
fn digest(bytes: []const u8) u32 {
    var value: u32 = 2166136261;
    for (bytes) |byte| value = (value ^ byte) *% 16777619;
    return value;
}
pub noinline fn compose(source: *Context, reply: *const protocol.Reply, pixels: []const u8) Result {
    if (!contextAllowed()) nih_native_task_failed();
    placement.context_checks += 1;
    verify(source, reply.id, reply.sourceHash(), true) catch nih_native_task_failed();
    const before = heap.availableBytes() orelse nih_native_task_failed();
    const allocation = heap.allocTask(stride * height + 64, 16) catch nih_native_task_failed();
    const charge: u32 = @intCast(before - (heap.availableBytes() orelse nih_native_task_failed()));
    metrics.peak_charge = @max(metrics.peak_charge, charge);
    metrics.live_charge = charge;
    @memset(allocation.bytes, 0xa5);
    const data = allocation.bytes[32..][0 .. stride * height];
    const target = surface.Surface.init(data, width, height, stride) orelse nih_native_task_failed();
    @as(*volatile bool, &painting).* = true;
    const result = paint(&target, data, source, reply, pixels);
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
noinline fn paint(target: *const surface.Surface, data: []u8, source: *const Context, reply: *const protocol.Reply, pixels: []const u8) linksection(".flash.text.render") Result {
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
            const boundaries = if (run == 0) source.body_map[0 .. source.render.body_length + 1] else source.ruby_map[0 .. source.render.ruby_length + 1];
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
    var flow = layout.Flow.init((if (vertical) @as(i32, 96) else if (reply.id == 9) @as(i32, 80) else 96) * 64, (if (vertical or reply.id == 5) @as(i32, 40) else 32) * 64, if (vertical) 4 else 3) catch nih_native_task_failed();
    if (reply.id != 9) _ = flow.place((if (vertical) @as(i32, 32) else 48) * 64) catch nih_native_task_failed();
    const planned = ruby.plan(16, protocol.Glyph, glyphs, source.body_map[0 .. source.render.body_length + 1], source.ruby_map[0 .. source.render.ruby_length + 1], source.annotations[0..source.annotation_count], if (vertical) .vertical else .horizontal, flow, 26 * 64) catch nih_native_task_failed();
    if (!target.fill(0xf79e)) nih_native_task_failed();
    for (glyphs, 0..) |g, i| {
        const position = planned.positions[i];
        const px: i64 = if (vertical) -@as(i64, position.block_offset) else position.inline_offset;
        const py: i64 = if (vertical) -@as(i64, position.inline_offset) else -@as(i64, position.block_offset);
        if (draw(target, pixels, &g, px, py, if (vertical) 150 else 8, if (vertical) 8 else if (reply.id == 9) @as(i64, 32) else 24)) ruby_metrics.clipped += 1;
    }
    ruby_metrics.frames += 1;
    ruby_metrics.groups += planned.stats.groups;
    ruby_metrics.moved += planned.stats.moved;
    ruby_metrics.wide += planned.stats.wide;
    ruby_metrics.units += planned.stats.units;
    ruby_metrics.joins += planned.stats.joins;
    ruby_metrics.lines += planned.flow.lines();
    result.ruby_hash = digest(data);
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
