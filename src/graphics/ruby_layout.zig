//! Bounded group-ruby layout. Inputs are borrowed; success returns a complete
//! value plan, errors publish neither positions nor a changed flow.
const std = @import("std");
pub const policy = @import("japanese_break.zig");
const layout = policy.layout;
pub const Range = struct { start: u32, end: u32 };
pub const Annotation = struct { base: Range, ruby: Range };
pub const Error = policy.Error || error{ Range, Run, Coverage };
const Unit = struct { first: u16, end: u16, ruby_first: u16, ruby_end: u16, advance: i32, base_offset: i32 = 0, ruby_offset: i32 = 0 };
pub const Stats = struct { units: u32 = 0, joins: u32 = 0, groups: u32 = 0, moved: u32 = 0, wide: u32 = 0 };
pub fn Plan(comptime capacity: usize) type {
    if (capacity == 0 or capacity > 1024) @compileError("ruby plan capacity must be 1..1024 glyphs");
    return struct { positions: [capacity]layout.Position = @splat(.{ .inline_offset = 0, .block_offset = 0 }), flow: layout.Flow, stats: Stats = .{}, count: u32 };
}
pub fn scratchBytes(comptime capacity: usize) usize {
    _ = Plan(capacity);
    return @sizeOf([capacity]Unit);
}

inline fn indexAt(comptime G: type, glyphs: []const G, offset: u32, boundaries: []const policy.Boundary) Error!usize {
    if (offset >= boundaries.len or !boundaries[offset].scalar_start) return error.Range;
    if (offset == boundaries.len - 1) return glyphs.len;
    for (glyphs, 0..) |g, i| {
        if (g.cluster == offset and (i == 0 or glyphs[i - 1].cluster != offset)) return i;
    }
    return error.Range;
}
inline fn select(comptime G: type, glyphs: []const G, range: Range, boundaries: []const policy.Boundary) Error!struct { first: usize, end: usize } {
    if (range.start >= range.end) return error.Range;
    const first = try indexAt(G, glyphs, range.start, boundaries);
    const end = try indexAt(G, glyphs, range.end, boundaries);
    if (first >= end) return error.Range;
    return .{ .first = first, .end = end };
}
inline fn advance(comptime G: type, glyphs: []const G, axis: layout.Axis) Error!i32 {
    var total: i64 = 0;
    var at: usize = 0;
    while (at < glyphs.len) {
        const group = try layout.cluster(G, glyphs, at, axis);
        total += group.advance;
        if (total > std.math.maxInt(i32)) return error.SpanTooWide;
        at = group.end;
    }
    return @intCast(total);
}
inline fn validateRun(comptime G: type, glyphs: []const G, boundaries: []const policy.Boundary, axis: layout.Axis) Error!void {
    if (boundaries.len == 0 or !boundaries[0].scalar_start or !boundaries[boundaries.len - 1].scalar_start) return error.Source;
    if ((glyphs.len == 0) != (boundaries.len == 1)) return error.Coverage;
    if (glyphs.len != 0 and glyphs[0].cluster != 0) return error.Coverage;
    var at: usize = 0;
    while (at < glyphs.len) {
        const offset = glyphs[at].cluster;
        if (offset >= boundaries.len - 1 or !boundaries[offset].scalar_start) return error.Source;
        at = (try layout.cluster(G, glyphs, at, axis)).end;
    }
}
inline fn add(a: i32, b: i32) Error!i32 {
    return std.math.cast(i32, @as(i64, a) + b) orelse error.Advance;
}

/// Input source maps must match the glyphs' source revision. Run 0 is body,
/// run 1 is concatenated ruby. Keep this bounded planner in its caller's code
/// placement; native paint inlines it in the audited task-only Flash function.
pub inline fn plan(comptime capacity: usize, comptime G: type, glyphs: []const G, body_map: []const policy.Boundary, ruby_map: []const policy.Boundary, annotations: []const Annotation, axis: layout.Axis, initial: layout.Flow, cross_offset: i32) Error!Plan(capacity) {
    if (glyphs.len == 0 or glyphs.len > capacity or annotations.len > capacity) return error.Capacity;
    if (cross_offset < 0 or (annotations.len != 0 and cross_offset == 0)) return error.Geometry;
    var body_count: usize = 0;
    while (body_count < glyphs.len and glyphs[body_count].run == 0) : (body_count += 1) {}
    if (body_count == 0) return error.Run;
    for (glyphs[body_count..]) |g| if (g.run != 1) return error.Run;
    const body = glyphs[0..body_count];
    const ruby = glyphs[body_count..];
    try validateRun(G, body, body_map, axis);
    try validateRun(G, ruby, ruby_map, axis);
    var previous_base: u32 = 0;
    var previous_ruby: u32 = 0;
    for (annotations) |annotation| {
        if (annotation.base.start < previous_base or annotation.ruby.start != previous_ruby) return error.Range;
        _ = try select(G, body, annotation.base, body_map);
        _ = try select(G, ruby, annotation.ruby, ruby_map);
        previous_base = annotation.base.end;
        previous_ruby = annotation.ruby.end;
    }
    if (previous_ruby != ruby_map.len - 1) return error.Coverage;
    // SAFETY: only the filled prefix is read, and every body glyph contributes
    // to exactly one unit; unit_count can never exceed glyphs.len <= capacity.
    var units: [capacity]Unit = undefined;
    var unit_count: usize = 0;
    var at: usize = 0;
    var annotation_index: usize = 0;
    var result = Plan(capacity){ .flow = initial, .count = @intCast(glyphs.len) };
    while (at < body.len) {
        var unit = Unit{ .first = @intCast(at), .end = 0, .ruby_first = 0, .ruby_end = 0, .advance = 0 };
        if (annotation_index < annotations.len and body[at].cluster == annotations[annotation_index].base.start) {
            const annotation = annotations[annotation_index];
            const base_range = try select(G, body, annotation.base, body_map);
            const ruby_range = try select(G, ruby, annotation.ruby, ruby_map);
            const base_advance = try advance(G, body[base_range.first..base_range.end], axis);
            const ruby_advance = try advance(G, ruby[ruby_range.first..ruby_range.end], axis);
            unit.end = @intCast(base_range.end);
            unit.ruby_first = @intCast(body_count + ruby_range.first);
            unit.ruby_end = @intCast(body_count + ruby_range.end);
            unit.advance = @max(base_advance, ruby_advance);
            unit.base_offset = @divTrunc(unit.advance - base_advance, 2);
            unit.ruby_offset = @divTrunc(unit.advance - ruby_advance, 2);
            result.stats.groups += 1;
            if (ruby_advance > base_advance) result.stats.wide += 1;
            annotation_index += 1;
        } else {
            const cluster = try layout.cluster(G, body, at, axis);
            unit.end = @intCast(cluster.end);
            unit.advance = cluster.advance;
        }
        units[unit_count] = unit;
        unit_count += 1;
        at = unit.end;
    }
    if (annotation_index != annotations.len) return error.Range;
    result.stats.units = @intCast(unit_count);
    var first: usize = 0;
    while (first < unit_count) {
        var end = first + 1;
        var width = units[first].advance;
        while (end < unit_count and !body_map[body[units[end].first].cluster].allowed) : (end += 1) {
            width = try add(width, units[end].advance);
            result.stats.joins += 1;
        }
        const position = try result.flow.place(width);
        var inline_offset = position.inline_offset;
        for (units[first..end]) |unit| {
            var pen = try add(inline_offset, unit.base_offset);
            for (unit.first..unit.end) |i| {
                result.positions[i] = .{ .inline_offset = pen, .block_offset = position.block_offset };
                pen = try add(pen, if (axis == .horizontal) glyphs[i].x_advance else -glyphs[i].y_advance);
            }
            if (unit.ruby_first != unit.ruby_end) {
                if (position.block_offset > @as(i32, initial.line) * initial.step) result.stats.moved += 1;
                pen = try add(inline_offset, unit.ruby_offset);
                for (unit.ruby_first..unit.ruby_end) |i| {
                    result.positions[i] = .{ .inline_offset = pen, .block_offset = position.block_offset - cross_offset };
                    pen = try add(pen, if (axis == .horizontal) glyphs[i].x_advance else -glyphs[i].y_advance);
                }
            }
            inline_offset = try add(inline_offset, unit.advance);
        }
        first = end;
    }
    return result;
}

const TestGlyph = struct { run: u32 = 0, cluster: u32, x_advance: i32 = 64, y_advance: i32 = 0 };
test "group ruby follows its base to the next line and reserves the wider sequence" {
    const glyphs = [_]TestGlyph{ .{ .cluster = 0 }, .{ .cluster = 3 }, .{ .run = 1, .cluster = 0 }, .{ .run = 1, .cluster = 3 }, .{ .run = 1, .cluster = 6 } };
    const body = policy.forText("日本");
    const ruby = policy.forText("にほん");
    const annotations = [_]Annotation{.{ .base = .{ .start = 0, .end = 6 }, .ruby = .{ .start = 0, .end = 9 } }};
    var flow = try layout.Flow.init(192, 256, 2);
    _ = try flow.place(64);
    const before = flow;
    const output = try plan(8, TestGlyph, &glyphs, &body, &ruby, &annotations, .horizontal, flow, 80);
    try std.testing.expectEqualDeep(before, flow);
    try std.testing.expectEqual(@as(i32, 256), output.positions[0].block_offset);
    try std.testing.expectEqual(@as(i32, 32), output.positions[0].inline_offset);
    try std.testing.expectEqual(@as(i32, 0), output.positions[2].inline_offset);
    try std.testing.expectEqual(@as(i32, 176), output.positions[2].block_offset);
    try std.testing.expectEqual(@as(u32, 1), output.stats.moved);
    try std.testing.expectEqual(@as(u32, 1), output.stats.wide);
}
test "multiple ordered annotations move independently in vertical flow" {
    const glyphs = [_]TestGlyph{ .{ .cluster = 0, .x_advance = 0, .y_advance = -64 }, .{ .cluster = 3, .x_advance = 0, .y_advance = -64 }, .{ .run = 1, .cluster = 0, .x_advance = 0, .y_advance = -64 }, .{ .run = 1, .cluster = 3, .x_advance = 0, .y_advance = -64 } };
    const body = policy.forText("日本");
    const ruby = policy.forText("にほ");
    const annotations = [_]Annotation{ .{ .base = .{ .start = 0, .end = 3 }, .ruby = .{ .start = 0, .end = 3 } }, .{ .base = .{ .start = 3, .end = 6 }, .ruby = .{ .start = 3, .end = 6 } } };
    const output = try plan(4, TestGlyph, &glyphs, &body, &ruby, &annotations, .vertical, try layout.Flow.init(64, 160, 2), 80);
    try std.testing.expectEqual(@as(i32, 160), output.positions[1].block_offset);
    try std.testing.expectEqual(@as(i32, 80), output.positions[3].block_offset);
    try std.testing.expectEqual(@as(u32, 2), output.stats.groups);
}
test "prohibition after a ruby parent joins the following closing mark" {
    const glyphs = [_]TestGlyph{ .{ .cluster = 0 }, .{ .cluster = 3 }, .{ .run = 1, .cluster = 0 } };
    const body = policy.forText("日。");
    const ruby = policy.forText("に");
    const annotations = [_]Annotation{.{ .base = .{ .start = 0, .end = 3 }, .ruby = .{ .start = 0, .end = 3 } }};
    var flow = try layout.Flow.init(128, 160, 2);
    _ = try flow.place(64);
    const output = try plan(4, TestGlyph, &glyphs, &body, &ruby, &annotations, .horizontal, flow, 80);
    try std.testing.expectEqual(@as(i32, 160), output.positions[0].block_offset);
    try std.testing.expectEqual(output.positions[0].block_offset, output.positions[1].block_offset);
    try std.testing.expectEqual(@as(u32, 1), output.stats.joins);
}
test "mid-cluster overlapping uncovered and overflowing annotations publish no plan" {
    const glyphs = [_]TestGlyph{ .{ .cluster = 0 }, .{ .cluster = 0 }, .{ .run = 1, .cluster = 0 } };
    const body = policy.forText("日本");
    const ruby = policy.forText("に");
    const cut = [_]Annotation{.{ .base = .{ .start = 0, .end = 3 }, .ruby = .{ .start = 0, .end = 3 } }};
    const full = [_]Annotation{.{ .base = .{ .start = 0, .end = 6 }, .ruby = .{ .start = 0, .end = 3 } }};
    const flow = try layout.Flow.init(64, 80, 1);
    try std.testing.expectError(error.Range, plan(4, TestGlyph, &glyphs, &body, &ruby, &cut, .horizontal, flow, 80));
    try std.testing.expectError(error.Coverage, plan(4, TestGlyph, &glyphs, &body, &ruby, &.{}, .horizontal, flow, 80));
    try std.testing.expectError(error.Range, plan(4, TestGlyph, &glyphs, &body, &ruby, &.{ full[0], full[0] }, .horizontal, flow, 80));
    try std.testing.expectError(error.SpanTooWide, plan(4, TestGlyph, &glyphs, &body, &ruby, &full, .horizontal, flow, 80));
    const fitted = try plan(4, TestGlyph, &glyphs, &body, &ruby, &full, .horizontal, try layout.Flow.init(128, 80, 1), 80);
    try std.testing.expectEqual(@as(i32, 64), fitted.positions[1].inline_offset);
    try std.testing.expectEqual(@as(i32, 32), fitted.positions[2].inline_offset);
    var full_box = try layout.Flow.init(128, 80, 1);
    _ = try full_box.place(64);
    try std.testing.expectError(error.BlockFull, plan(4, TestGlyph, &glyphs, &body, &ruby, &full, .horizontal, full_box, 80));
    try std.testing.expectEqual(@as(i32, 64), full_box.used);
    try std.testing.expectEqual(@as(i32, 0), flow.used);
}

test "interleaved runs invalid scalar offsets and insufficient capacity fail before placement" {
    const body = policy.forText("日本");
    const ruby = policy.forText("に");
    const glyphs = [_]TestGlyph{ .{ .cluster = 0 }, .{ .cluster = 3 }, .{ .run = 1, .cluster = 0 } };
    const annotation = [_]Annotation{.{ .base = .{ .start = 0, .end = 6 }, .ruby = .{ .start = 0, .end = 3 } }};
    const flow = try layout.Flow.init(128, 80, 2);
    try std.testing.expectError(error.Capacity, plan(2, TestGlyph, &glyphs, &body, &ruby, &annotation, .horizontal, flow, 80));
    var bad = glyphs;
    bad[1].cluster = 1;
    try std.testing.expectError(error.Source, plan(4, TestGlyph, &bad, &body, &ruby, &annotation, .horizontal, flow, 80));
    bad = glyphs;
    bad[0].run = 1;
    try std.testing.expectError(error.Run, plan(4, TestGlyph, &bad, &body, &ruby, &annotation, .horizontal, flow, 80));
}
