//! Allocation-free greedy flow of caller-defined indivisible spans.
//! Units are nonnegative 26.6 advances; this is not a Unicode break policy.
const std = @import("std");
pub const Error = error{ Geometry, Advance, SpanTooWide, BlockFull, Order };
pub const Position = struct { inline_offset: i32, block_offset: i32 };
pub const Flow = struct {
    limit: i32,
    step: i32,
    capacity: u16,
    used: i32 = 0,
    line: u16 = 0,
    seen: bool = false,

    pub fn init(limit: i32, step: i32, capacity: u16) Error!Flow {
        if (limit <= 0 or step <= 0 or capacity == 0 or
            @as(i64, capacity - 1) * step > std.math.maxInt(i32)) return error.Geometry;
        return .{ .limit = limit, .step = step, .capacity = capacity };
    }
    /// On error, no span or line is consumed. The caller may retry another box.
    pub noinline fn place(self: *Flow, advance: i32) Error!Position {
        if (advance < 0) return error.Advance;
        if (advance > self.limit) return error.SpanTooWide;
        var line = self.line;
        var start = self.used;
        if (advance > self.limit - start) {
            if (@as(u32, line) + 1 >= self.capacity) return error.BlockFull;
            line += 1;
            start = 0;
        }
        const position = Position{ .inline_offset = start, .block_offset = @as(i32, line) * self.step };
        self.line = line;
        self.used = start + advance;
        self.seen = true;
        return position;
    }
    pub fn lines(self: Flow) u32 {
        return if (self.seen) @as(u32, self.line) + 1 else 0;
    }
};
pub const Axis = enum { horizontal, vertical };
pub const Cluster = struct { end: usize, advance: i32 };

/// Group consecutive equal run/cluster IDs supplied by shaping. Monotone
/// LTR/TTB axis advances only; grouping is not grapheme or word segmentation.
pub noinline fn cluster(comptime G: type, glyphs: []const G, start: usize, axis: Axis) Error!Cluster {
    if (start >= glyphs.len) return error.Order;
    const first = glyphs[start];
    var end = start;
    var advance: i64 = 0;
    while (end < glyphs.len and glyphs[end].run == first.run and glyphs[end].cluster == first.cluster) : (end += 1) {
        const g = glyphs[end];
        const amount: i64 = if (axis == .horizontal) g.x_advance else -@as(i64, g.y_advance);
        const cross = if (axis == .horizontal) g.y_advance else g.x_advance;
        if (amount < 0 or cross != 0) return error.Advance;
        advance += amount;
        if (advance > std.math.maxInt(i32)) return error.SpanTooWide;
    }
    if (end < glyphs.len and glyphs[end].run == first.run and glyphs[end].cluster < first.cluster) return error.Order;
    return .{ .end = end, .advance = @intCast(advance) };
}

test "equal shaping clusters stay together at a line boundary" {
    const G = struct { run: u32 = 0, cluster: u32, x_advance: i32, y_advance: i32 = 0 };
    const glyphs = [_]G{ .{ .cluster = 0, .x_advance = 96 }, .{ .cluster = 3, .x_advance = 48 }, .{ .cluster = 3, .x_advance = 48 } };
    var flow = try Flow.init(128, 64, 2);
    const first = try cluster(G, &glyphs, 0, .horizontal);
    _ = try flow.place(first.advance);
    const second = try cluster(G, &glyphs, first.end, .horizontal);
    try std.testing.expectEqual(@as(usize, 3), second.end);
    const position = try flow.place(second.advance);
    try std.testing.expectEqual(@as(i32, 0), position.inline_offset);
    try std.testing.expectEqual(@as(i32, 64), position.block_offset);
}
test "exact fits zero advance and rejected spans preserve flow" {
    var flow = try Flow.init(64, 80, 1);
    _ = try flow.place(64);
    _ = try flow.place(0);
    const before = flow;
    try std.testing.expectError(error.BlockFull, flow.place(1));
    try std.testing.expectError(error.SpanTooWide, flow.place(65));
    try std.testing.expectError(error.Advance, flow.place(-1));
    try std.testing.expectEqualDeep(before, flow);
    try std.testing.expectError(error.Geometry, Flow.init(0, 1, 1));
    try std.testing.expectError(error.Geometry, Flow.init(1, std.math.maxInt(i32), 3));
}
test "vertical cluster advances and unsupported ordering are explicit" {
    const G = struct { run: u32 = 0, cluster: u32, x_advance: i32 = 0, y_advance: i32 };
    const glyphs = [_]G{ .{ .cluster = 3, .y_advance = -64 }, .{ .cluster = 0, .y_advance = -64 } };
    try std.testing.expectError(error.Order, cluster(G, &glyphs, 0, .vertical));
    const good = [_]G{.{ .cluster = 0, .y_advance = -64 }};
    try std.testing.expectEqual(@as(i32, 64), (try cluster(G, &good, 0, .vertical)).advance);
    try std.testing.expectError(error.Advance, cluster(G, &good, 0, .horizontal));
}
