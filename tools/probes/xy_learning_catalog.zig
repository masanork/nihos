//! Host-only contract tests for the real, generated learning catalogue.
const std = @import("std");
const catalog = @import("learning_catalog");
const fixture = @import("learning_fixture").data;

test "generated catalogue separates input and reference output and retains identity" {
    const pack = try catalog.Pack.init(fixture);
    try std.testing.expectEqual(@as(u32, 3), pack.section_count);
    try std.testing.expectEqual(@as(u32, 25), pack.snippet_count);
    try std.testing.expectEqual(@as(u32, 21), pack.experiment_count);
    const index = (try pack.findSnippet("sicp.expressions.addition")).?;
    const s = try pack.snippet(index);
    try std.testing.expectEqualStrings("(+ 137 349)", s.code);
    try std.testing.expectEqualStrings("486", s.reference_output);
    try std.testing.expectEqualStrings("", s.upstream_expected);
    try std.testing.expect(pack.matchesLibrary(fixture[64..96]));
    var other = fixture[64..96].*;
    other[0] ^= 1;
    try std.testing.expect(!pack.matchesLibrary(&other));
    try std.testing.expect(std.mem.indexOf(u8, try pack.credits(), "CC-BY-SA-4.0") != null);
    // The returned source borrows the immutable image; no copy/allocator is needed.
    try std.testing.expect(@intFromPtr(s.code.ptr) >= @intFromPtr(fixture.ptr));
    try std.testing.expect(@intFromPtr(s.code.ptr) + s.code.len <= @intFromPtr(fixture.ptr) + fixture.len);
}

test "page intersections return a complete snippet and exclude outputs and support" {
    const p = try catalog.Pack.init(fixture);
    const s = try p.snippet((try p.findSnippet("sicp.expressions.addition")).?);
    const a = s.anchor.?;
    const left = (try p.onPage(s.section, a.start, a.start + 1, 0)).?;
    const right = (try p.onPage(s.section, a.end - 1, a.end, 0)).?;
    try std.testing.expectEqualStrings(s.code, left.code);
    try std.testing.expectEqualStrings(s.code, right.code);
    try std.testing.expectEqual(@as(?catalog.Snippet, null), try p.onPage(s.section, a.start, a.start, 0));
    try std.testing.expectEqual(@as(?catalog.Snippet, null), try p.onPage(s.section, a.end, a.end + 1, 0));
    const support = try p.snippet((try p.findSnippet("sicp.recursion.inc-dec")).?);
    try std.testing.expect(support.hidden and support.anchor == null);
    try std.testing.expectError(error.Range, p.onPage(s.section, 0, std.math.maxInt(u32), 0));
}

test "plans retain preparation and invocation without definition-example cycles" {
    const p = try catalog.Pack.init(fixture);
    var found = false;
    for (0..p.experiment_count) |i| {
        const e = try p.experiment(@intCast(i));
        if (!std.mem.eql(u8, e.id, "sicp.recursion.addition-recursive.try")) continue;
        found = true;
        try std.testing.expect(!e.execution_qualified and !e.reference_approved);
        try std.testing.expectEqual(@as(u32, 3), e.plan_count);
        for ([_][]const u8{ "sicp.recursion.inc-dec", "sicp.recursion.addition-recursive", "sicp.recursion.addition-call" }, 0..) |id, j| {
            const s = try p.snippet(try p.reference(e.plan_start, e.plan_count, @intCast(j)));
            try std.testing.expectEqualStrings(id, s.id);
        }
        try std.testing.expectEqualStrings("9", e.reference_text);
        try std.testing.expectError(error.Range, p.reference(e.plan_start, e.plan_count, e.plan_count));
    }
    try std.testing.expect(found);
}

fn write(bytes: []u8, at: usize, n: u32) void {
    std.mem.writeInt(u32, bytes[at..][0..4], n, .little);
}
fn read(bytes: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, bytes[at..][0..4], .little);
}
test "malformed offsets, counts, references, anchors and UTF8 fail closed" {
    var bytes: [fixture.len]u8 = undefined;
    const sa = read(fixture, 36);
    const ea = read(fixture, 40);
    const ra = read(fixture, 44);
    const corruptions = [_]struct { at: usize, value: u32 }{
        .{ .at = 8, .value = 2 },                          .{ .at = 12, .value = 128 },
        .{ .at = 16, .value = std.math.maxInt(u32) },      .{ .at = 20, .value = 4097 },
        .{ .at = 24, .value = 4097 },                      .{ .at = 28, .value = 1 },
        .{ .at = 32, .value = 0 },                         .{ .at = 52, .value = 128 },
        .{ .at = sa, .value = std.math.maxInt(u32) },      .{ .at = sa + 8, .value = 3 },
        .{ .at = sa + 44, .value = std.math.maxInt(u32) }, .{ .at = sa + 52, .value = 25 },
        .{ .at = sa + 56, .value = 16 },                   .{ .at = sa + 64, .value = 0 },
        .{ .at = ea + 8, .value = 25 },                    .{ .at = ea + 20, .value = 0 },
        .{ .at = ra, .value = 25 },
    };
    for (corruptions) |c| {
        bytes = fixture.*;
        write(&bytes, c.at, c.value);
        if (catalog.Pack.init(&bytes)) |_| return error.InvalidCatalogueAccepted else |_| {}
    }
    for ([_]struct { at: usize, value: u32 }{ .{ .at = sa + 4, .value = 129 }, .{ .at = sa + 16, .value = 4097 } }) |c| {
        bytes = fixture.*;
        write(&bytes, c.at, c.value);
        try std.testing.expectError(error.Range, catalog.Pack.init(&bytes));
    }
    bytes = fixture.*;
    bytes[read(fixture, sa + 12)] = 0xff;
    try std.testing.expectError(error.InvalidUtf8, catalog.Pack.init(&bytes));
    for (0..128) |len| {
        try std.testing.expectError(error.InvalidPack, catalog.Pack.init(fixture[0..len]));
    }
}
