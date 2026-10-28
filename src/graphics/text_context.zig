//! Owned bounded runtime source/maps/annotations. No heap or font-library API.
const std = @import("std");
pub const ruby = @import("ruby_layout.zig");
const policy = ruby.policy;
pub const protocol = @import("font_protocol.zig");
pub const max_annotations = 8;
pub const Error = policy.Error || error{ Revision, Annotation, InvalidPayload, Integrity, ReplySource };
pub const Context = struct {
    revision: u32,
    render: protocol.Render,
    annotation_count: u32,
    annotations: [max_annotations]ruby.Annotation = @splat(.{ .base = .{ .start = 0, .end = 0 }, .ruby = .{ .start = 0, .end = 0 } }),
    body_map: [129]policy.Boundary = @splat(.{}),
    ruby_map: [65]policy.Boundary = @splat(.{}),
    source_hash: u32 = 0,
    seal: u32 = 0,

    pub inline fn init(revision: u32, render: protocol.Render, annotations: []const ruby.Annotation) Error!Context {
        // SAFETY: initInto assigns the full value only on success.
        var result: Context = undefined;
        try initInto(&result, revision, render, annotations);
        return result;
    }
    pub inline fn initInto(out: *Context, revision: u32, render: protocol.Render, annotations: []const ruby.Annotation) Error!void {
        if (revision == 0) return error.Revision;
        if (annotations.len > max_annotations) return error.Capacity;
        try render.validate();
        var candidate = Context{ .revision = revision, .render = render, .annotation_count = @intCast(annotations.len) };
        @memset(candidate.render.body[render.body_length..], 0);
        @memset(candidate.render.ruby[render.ruby_length..], 0);
        @memcpy(candidate.annotations[0..annotations.len], annotations);
        try policy.map(candidate.render.body[0..render.body_length], candidate.body_map[0 .. render.body_length + 1]);
        try policy.map(candidate.render.ruby[0..render.ruby_length], candidate.ruby_map[0 .. render.ruby_length + 1]);
        var previous_base: u32 = 0;
        var previous_ruby: u32 = 0;
        for (annotations) |annotation| {
            const base = annotation.base;
            const reading = annotation.ruby;
            if (base.start < previous_base or base.start >= base.end or base.end > render.body_length or
                reading.start != previous_ruby or reading.start >= reading.end or reading.end > render.ruby_length) return error.Annotation;
            if (!candidate.body_map[base.start].scalar_start or !candidate.body_map[base.end].scalar_start or
                !candidate.ruby_map[reading.start].scalar_start or !candidate.ruby_map[reading.end].scalar_start) return error.Annotation;
            previous_base = base.end;
            previous_ruby = reading.end;
        }
        if (previous_ruby != render.ruby_length) return error.Annotation;
        candidate.source_hash = protocol.renderHash(&candidate.render);
        candidate.seal = candidate.checksum();
        out.* = candidate;
    }
    inline fn checksum(self: *const Context) u32 {
        var value: u32 = 2166136261;
        for ([_]u32{ self.revision, self.source_hash, self.annotation_count }) |word| value = (value ^ word) *% 16777619;
        for (self.annotations[0..self.annotation_count]) |annotation| {
            for ([_]u32{ annotation.base.start, annotation.base.end, annotation.ruby.start, annotation.ruby.end }) |word| value = (value ^ word) *% 16777619;
        }
        for (self.body_map[0 .. self.render.body_length + 1]) |entry| value = (value ^ @as(u8, @bitCast(entry))) *% 16777619;
        for (self.ruby_map[0 .. self.render.ruby_length + 1]) |entry| value = (value ^ @as(u8, @bitCast(entry))) *% 16777619;
        return value;
    }
    pub inline fn check(self: *const Context, revision: u32, reply_source: u32) Error!void {
        if (revision == 0 or self.revision != revision) return error.Revision;
        if (self.annotation_count > max_annotations or self.render.body_length == 0 or self.render.body_length > 128 or self.render.ruby_length > 64) return error.Integrity;
        if (reply_source != self.source_hash) return error.ReplySource;
        if (protocol.renderHash(&self.render) != self.source_hash or self.checksum() != self.seal) return error.Integrity;
    }
};

test "runtime source owns bytes annotations and maps across caller poisoning" {
    var render = try protocol.Render.init(0, 24, 0, 0, "日本", "にほん");
    var annotation = [_]ruby.Annotation{.{ .base = .{ .start = 0, .end = 6 }, .ruby = .{ .start = 0, .end = 9 } }};
    const context = try Context.init(7, render, &annotation);
    @memset(&render.body, 0xff);
    @memset(std.mem.sliceAsBytes(&annotation), 0xff);
    try context.check(7, context.source_hash);
    try std.testing.expectEqualStrings("日本", context.render.body[0..6]);
    try std.testing.expectEqual(@as(u32, 6), context.annotations[0].base.end);
    var changed_annotation = context;
    changed_annotation.annotations[0].base.end ^= 1;
    try std.testing.expectError(error.Integrity, changed_annotation.check(7, context.source_hash));
    try std.testing.expect(context.body_map[3].allowed);
    var edited = context.render;
    @memcpy(edited.body[0..3], "「");
    const changed = try Context.init(8, edited, &.{.{ .base = .{ .start = 0, .end = 6 }, .ruby = .{ .start = 0, .end = 9 } }});
    try std.testing.expect(!changed.body_map[3].allowed);
    try std.testing.expect(changed.source_hash != context.source_hash);
}
test "stale mutated and wrong-worker source are refused without changing the context" {
    const context = try Context.init(7, try protocol.Render.init(0, 16, 0, 0, "日本", ""), &.{});
    try std.testing.expectError(error.Revision, context.check(6, context.source_hash));
    try std.testing.expectError(error.ReplySource, context.check(7, context.source_hash ^ 1));
    var bad = context;
    bad.render.body[0] ^= 1;
    try std.testing.expectError(error.Integrity, bad.check(7, context.source_hash));
    bad = context;
    bad.body_map[3].allowed = !bad.body_map[3].allowed;
    try std.testing.expectError(error.Integrity, bad.check(7, context.source_hash));
    bad = context;
    bad.annotation_count = 99;
    try std.testing.expectError(error.Integrity, bad.check(7, context.source_hash));
    try context.check(7, context.source_hash);
}
test "invalid preparation leaves the previously committed value untouched" {
    var active = try Context.init(1, try protocol.Render.init(0, 16, 0, 0, "日本", ""), &.{});
    const before = active;
    var invalid = active.render;
    invalid.body[0] = 0xff;
    const result = Context.init(2, invalid, &.{});
    if (result) |candidate| active = candidate else |err| try std.testing.expectEqual(error.InvalidPayload, err);
    try std.testing.expectEqualDeep(before, active);
    try std.testing.expectError(error.InvalidPayload, Context.initInto(&active, 2, invalid, &.{}));
    try std.testing.expectEqualDeep(before, active);
    const with_ruby = try protocol.Render.init(0, 16, 0, 0, "日本", "に");
    try std.testing.expectError(error.Annotation, Context.init(2, with_ruby, &.{}));
    try std.testing.expectError(error.Annotation, Context.init(2, with_ruby, &.{.{ .base = .{ .start = 1, .end = 6 }, .ruby = .{ .start = 0, .end = 3 } }}));
}
