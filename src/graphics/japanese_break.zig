//! Explicit basic Japanese prohibition profile, not UAX14/JIS conformance.
//! Source boundaries are separate from shaping clusters and placement.
const std = @import("std");
pub const layout = @import("line_layout.zig");
pub const Boundary = packed struct(u8) { allowed: bool = false, scalar_start: bool = false, reserved: u6 = 0 };
pub const Error = layout.Error || error{ Source, Capacity, HardBreak, Alias };

pub fn noEnd(cp: u21) bool {
    return switch (cp) {
        '(', '[', '{', 0x2018, 0x201c, 0x3008, 0x300a, 0x300c, 0x300e, 0x3010, 0x3014, 0x3016, 0x3018, 0x301a, 0xff08, 0xff3b, 0xff5b, 0xff62 => true,
        else => false,
    };
}
pub fn noStart(cp: u21) bool {
    return switch (cp) {
        ')',
        ']',
        '}',
        ',',
        '.',
        ':',
        ';',
        '!',
        '?',
        0x00b7,
        0x2019,
        0x201d,
        0x3001,
        0x3002,
        0x3005,
        0x3009,
        0x300b,
        0x300d,
        0x300f,
        0x3011,
        0x3015,
        0x3017,
        0x3019,
        0x301b,
        0x303b,
        0x3041,
        0x3043,
        0x3045,
        0x3047,
        0x3049,
        0x3063,
        0x3083,
        0x3085,
        0x3087,
        0x308e,
        0x3095,
        0x3096,
        0x309b,
        0x309c,
        0x309d,
        0x309e,
        0x30a1,
        0x30a3,
        0x30a5,
        0x30a7,
        0x30a9,
        0x30c3,
        0x30e3,
        0x30e5,
        0x30e7,
        0x30ee,
        0x30f5,
        0x30f6,
        0x30fb,
        0x30fc,
        0x30fd,
        0x30fe,
        0x31f0...0x31ff,
        0xff01,
        0xff09,
        0xff0c,
        0xff0e,
        0xff1a,
        0xff1b,
        0xff1f,
        0xff3d,
        0xff5d,
        0xff61,
        0xff63,
        0xff64,
        0xff65,
        0xff67...0xff70,
        => true,
        else => false,
    };
}

/// Whole paragraph fragment only. Split CR/LF outside this API. Invalid input
/// or insufficient output leaves the caller's map unchanged. Paragraph edges
/// are forced endpoints; an initial closing mark is not silently rewritten.
pub fn map(text: []const u8, output: []Boundary) Error!void {
    if (text.len == std.math.maxInt(usize) or output.len != text.len + 1) return error.Capacity;
    if (!@inComptime() and text.len != 0) {
        const source = @intFromPtr(text.ptr);
        const destination = @intFromPtr(output.ptr);
        if (if (source <= destination) destination - source < text.len else source - destination < output.len) return error.Alias;
    }
    if (!std.unicode.utf8ValidateSlice(text)) return error.Source;
    if (std.mem.indexOfAny(u8, text, "\r\n") != null) return error.HardBreak;
    @memset(output, .{});
    var iterator = (std.unicode.Utf8View.init(text) catch return error.Source).iterator();
    var previous: ?u21 = null;
    while (iterator.i < text.len) {
        const offset = iterator.i;
        const cp = iterator.nextCodepoint() orelse return error.Source;
        output[offset] = .{ .scalar_start = true, .allowed = if (previous) |left| !noEnd(left) and !noStart(cp) else true };
        previous = cp;
    }
    output[text.len] = .{ .allowed = true, .scalar_start = true };
}
pub fn forText(comptime text: []const u8) [text.len + 1]Boundary {
    return comptime blk: {
        var result: [text.len + 1]Boundary = @splat(.{});
        map(text, &result) catch @compileError("invalid basic Japanese paragraph input");
        break :blk result;
    };
}

/// Combine whole shaping clusters until the next permitted source boundary.
/// Callers supply this run's source map; offsets are UTF-8 byte indices.
/// No flow is mutated here. A joined span may exceed the eventual line limit;
/// Flow.place then fails explicitly rather than violating a prohibition.
pub fn span(comptime G: type, glyphs: []const G, start: usize, axis: layout.Axis, boundaries: []const Boundary) Error!layout.Cluster {
    if (start >= glyphs.len or boundaries.len == 0) return error.Source;
    const first = glyphs[start];
    if (first.cluster >= boundaries.len - 1 or !boundaries[first.cluster].scalar_start) return error.Source;
    var result = try layout.cluster(G, glyphs, start, axis);
    while (result.end < glyphs.len and glyphs[result.end].run == first.run) {
        const offset = glyphs[result.end].cluster;
        if (offset >= boundaries.len - 1 or !boundaries[offset].scalar_start) return error.Source;
        if (boundaries[offset].allowed) break;
        const next = try layout.cluster(G, glyphs, result.end, axis);
        const advance = @as(i64, result.advance) + next.advance;
        if (advance > std.math.maxInt(i32)) return error.SpanTooWide;
        result = .{ .end = next.end, .advance = @intCast(advance) };
    }
    return result;
}

const TestGlyph = struct { run: u32 = 0, cluster: u32, x_advance: i32 = 64, y_advance: i32 = 0 };
test "source boundaries prohibit opening closing punctuation small kana and long marks" {
    const cases = [_]struct { left: u21, right: u21, allowed: bool }{
        .{ .left = '「', .right = '日', .allowed = false },
        .{ .left = '｢', .right = '日', .allowed = false },
        .{ .left = '日', .right = '」', .allowed = false },
        .{ .left = '日', .right = '、', .allowed = false },
        .{ .left = '日', .right = '。', .allowed = false },
        .{ .left = 'き', .right = 'ょ', .allowed = false },
        .{ .left = 'カ', .right = 'ー', .allowed = false },
        .{ .left = '日', .right = '本', .allowed = true },
        .{ .left = '。', .right = '日', .allowed = true },
    };
    for (cases) |item| {
        try std.testing.expectEqual(item.allowed, !noEnd(item.left) and !noStart(item.right));
    }
    const boundaries = forText("「日本」、きょう");
    try std.testing.expect(boundaries[0].allowed and boundaries[24].allowed);
    try std.testing.expect(!boundaries[1].scalar_start and !boundaries[3].allowed);
    try std.testing.expect(boundaries[6].allowed and !boundaries[9].allowed and !boundaries[12].allowed and !boundaries[18].allowed);
}
test "join before greedy placement prevents a closing mark from starting a line" {
    const glyphs = [_]TestGlyph{ .{ .cluster = 0 }, .{ .cluster = 3 }, .{ .cluster = 6 }, .{ .cluster = 9 } };
    const boundaries = forText("日本、語");
    var flow = try layout.Flow.init(128, 80, 2);
    const first = try span(TestGlyph, &glyphs, 0, .horizontal, &boundaries);
    try std.testing.expectEqual(@as(usize, 1), first.end);
    _ = try flow.place(first.advance);
    const second = try span(TestGlyph, &glyphs, first.end, .horizontal, &boundaries);
    try std.testing.expectEqual(@as(usize, 3), second.end);
    try std.testing.expectEqual(@as(i32, 80), (try flow.place(second.advance)).block_offset);
    var naive = try layout.Flow.init(128, 80, 2);
    _ = try naive.place(64);
    _ = try naive.place(64);
    try std.testing.expectEqual(@as(i32, 0), (try naive.place(64)).inline_offset);
}
test "opening bracket moves with its following cluster and vertical continuation respects punctuation" {
    const glyphs = [_]TestGlyph{ .{ .cluster = 0 }, .{ .cluster = 3 }, .{ .cluster = 6 }, .{ .cluster = 9 } };
    const opening = forText("日「本語");
    const joined = try span(TestGlyph, &glyphs, 1, .horizontal, &opening);
    try std.testing.expectEqual(@as(usize, 3), joined.end);
    var flow = try layout.Flow.init(128, 80, 2);
    _ = try flow.place(64);
    try std.testing.expectEqual(@as(i32, 80), (try flow.place(joined.advance)).block_offset);
    const vertical = [_]TestGlyph{ .{ .cluster = 0, .x_advance = 0, .y_advance = -64 }, .{ .cluster = 3, .x_advance = 0, .y_advance = -64 } };
    const closing = forText("日。");
    const v = try span(TestGlyph, &vertical, 0, .vertical, &closing);
    try std.testing.expectEqual(@as(i32, 128), v.advance);
    var column = try layout.Flow.init(128, 100, 2);
    _ = try column.place(64);
    try std.testing.expectEqual(@as(i32, 100), (try column.place(v.advance)).block_offset);
}
test "multiple glyph clusters and consecutive forbidden boundaries remain indivisible" {
    const boundaries = forText("「日。」語");
    const glyphs = [_]TestGlyph{ .{ .cluster = 0 }, .{ .cluster = 3, .x_advance = 32 }, .{ .cluster = 3, .x_advance = 32 }, .{ .cluster = 6 }, .{ .cluster = 9 }, .{ .cluster = 12 } };
    const joined = try span(TestGlyph, &glyphs, 0, .horizontal, &boundaries);
    try std.testing.expectEqual(@as(usize, 5), joined.end);
    var flow = try layout.Flow.init(128, 80, 2);
    const before = flow;
    try std.testing.expectError(error.SpanTooWide, flow.place(joined.advance));
    try std.testing.expectEqualDeep(before, flow);
}
test "bad source and source capacity preserve map and invalid byte cluster is refused" {
    var output: [3]Boundary = @splat(.{ .allowed = true });
    const before = output;
    try std.testing.expectError(error.Source, map("\xff\xff", &output));
    try std.testing.expectError(error.HardBreak, map("a\n", &output));
    try std.testing.expectError(error.Capacity, map("a", &output));
    try std.testing.expectEqualDeep(before, output);
    const boundaries = forText("日本");
    const bad = [_]TestGlyph{.{ .cluster = 1 }};
    try std.testing.expectError(error.Source, span(TestGlyph, &bad, 0, .horizontal, &boundaries));
    const outside = [_]TestGlyph{.{ .cluster = 6 }};
    try std.testing.expectError(error.Source, span(TestGlyph, &outside, 0, .horizontal, &boundaries));
}

test "source map rejects alias before modifying bytes" {
    var bytes = [_]u8{ 'a', 'b', 'c', 0 };
    const before = bytes;
    const output: []Boundary = @ptrCast(bytes[0..4]);
    try std.testing.expectError(error.Alias, map(bytes[0..3], output));
    try std.testing.expectEqualDeep(before, bytes);
}
