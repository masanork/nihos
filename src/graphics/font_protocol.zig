//! Experimental, pointer-free qualification protocol. One client dispatcher
//! owns submission; a single font task owns library state. This finite render
//! workload is not a paragraph, raster-buffer or application session API.
const std = @import("std");

pub const Operation = enum(u32) { render_matrix, render_text, stop };
pub const Render = extern struct {
    font: u32 = 0,
    pixels: u32 = 24,
    vertical: u32 = 0,
    hinting: u32 = 0,
    body_length: u32 = 0,
    ruby_length: u32 = 0,
    body: [128]u8 = @splat(0),
    ruby: [64]u8 = @splat(0),

    pub fn validate(self: *const Render) error{InvalidPayload}!void {
        if (self.font > 1 or self.vertical > 1 or self.hinting > 2 or
            (self.pixels != 12 and self.pixels != 16 and self.pixels != 24 and self.pixels != 32) or
            self.body_length == 0 or self.body_length > self.body.len or self.ruby_length > self.ruby.len)
            return error.InvalidPayload;
        if (!std.unicode.utf8ValidateSlice(self.body[0..self.body_length]) or
            !std.unicode.utf8ValidateSlice(self.ruby[0..self.ruby_length])) return error.InvalidPayload;
    }

    pub fn init(font: u32, pixels: u32, vertical: u32, hinting: u32, body: []const u8, ruby: []const u8) error{InvalidPayload}!Render {
        if (body.len > 128 or ruby.len > 64) return error.InvalidPayload;
        var result: Render = .{ .font = font, .pixels = pixels, .vertical = vertical, .hinting = hinting, .body_length = @intCast(body.len), .ruby_length = @intCast(ruby.len) };
        @memcpy(result.body[0..body.len], body);
        @memcpy(result.ruby[0..ruby.len], ruby);
        try result.validate();
        return result;
    }
};
// Private synchronous bridge into C++; this pointer never comes from a client.
pub const Job = extern struct { operation: u32, render: Render };
pub const Outcome = enum(u32) { ok, render_failed, output_full };
pub const Glyph = extern struct {
    id: u32 = 0,
    cluster: u32 = 0,
    run: u32 = 0,
    pixels: u32 = 0,
    x_advance: i32 = 0,
    y_advance: i32 = 0,
    x_offset: i32 = 0,
    y_offset: i32 = 0,
    left: i32 = 0,
    top: i32 = 0,
    width: u32 = 0,
    height: u32 = 0,
};
pub const Output = extern struct {
    outcome: u32 = 1,
    count: u32 = 0,
    glyphs: [16]Glyph = @splat(.{}),

    pub fn validate(self: *const Output) error{InvalidOutput}!void {
        if (self.outcome > 2 or self.count > self.glyphs.len) return error.InvalidOutput;
        if (self.outcome != 0) {
            if (self.count != 0 or !std.mem.allEqual(u8, std.mem.asBytes(&self.glyphs), 0)) return error.InvalidOutput;
            return;
        }
        if (self.count == 0) return error.InvalidOutput;
        for (self.glyphs[0..self.count]) |g| {
            if (g.id == 0 or g.run > 1 or g.cluster >= (if (g.run == 0) @as(u32, 128) else 64) or
                g.pixels < 6 or g.pixels > 32 or g.width > 256 or g.height > 256) return error.InvalidOutput;
        }
        // Unused slots are cleared, so a future shorter reply exposes no old data.
        if (!std.mem.allEqual(u8, std.mem.sliceAsBytes(self.glyphs[self.count..]), 0)) return error.InvalidOutput;
    }
};
pub const Request = struct { id: u32, operation: Operation, render: Render = .{} };
pub const Reply = struct {
    id: u32,
    operation: Operation,
    runs: u32 = 0,
    hashes: [16]u32 = @splat(0),
    retained: u32,
    outcome: Outcome = .ok,
    output: Output = .{},
};

pub const State = struct {
    next_id: u32 = 1,
    active: ?u32 = null,
    stopped: bool = false,
    pub const Error = error{ Closed, Busy, Sequence, Exhausted, InvalidPayload };

    pub fn accept(self: *State, request: Request) Error!void {
        if (self.stopped) return error.Closed;
        if (self.active != null) return error.Busy;
        if (request.id != self.next_id) return error.Sequence;
        if (request.operation == .render_text) try request.render.validate();
        // Do not wrap an ID and accidentally accept an old request.
        if (self.next_id == std.math.maxInt(u32)) return error.Exhausted;
        self.next_id += 1;
        switch (request.operation) {
            .render_matrix, .render_text => self.active = request.id,
            .stop => self.stopped = true,
        }
    }

    pub fn complete(self: *State, id: u32) Error!void {
        if (self.active == null or self.active.? != id) return error.Sequence;
        self.active = null;
    }
};

test "invalid or busy requests do not consume an ID or replace in-flight work" {
    var state: State = .{};
    try std.testing.expectError(error.Sequence, state.accept(.{ .id = 0, .operation = .render_matrix }));
    try state.accept(.{ .id = 1, .operation = .render_matrix });
    try std.testing.expectError(error.Busy, state.accept(.{ .id = 2, .operation = .stop }));
    try std.testing.expectError(error.Sequence, state.complete(2));
    try state.complete(1);
    try std.testing.expectError(error.Sequence, state.accept(.{ .id = 1, .operation = .render_matrix }));
    try state.accept(.{ .id = 2, .operation = .render_matrix });
    try state.complete(2);
    try state.accept(.{ .id = 3, .operation = .stop });
    try std.testing.expectError(error.Closed, state.accept(.{ .id = 4, .operation = .render_matrix }));
}

test "ID exhaustion fails before changing protocol state" {
    var state: State = .{ .next_id = std.math.maxInt(u32) };
    try std.testing.expectError(error.Exhausted, state.accept(.{ .id = state.next_id, .operation = .render_matrix }));
    try std.testing.expect(state.active == null and !state.stopped);
}

test "bounded payload owns bytes and rejects invalid UTF-8 and settings without consuming ID" {
    var text = [_]u8{ 'A', 'B' };
    const render = try Render.init(0, 24, 0, 1, &text, "");
    text[0] = 'Z';
    try std.testing.expectEqualStrings("AB", render.body[0..render.body_length]);
    var state: State = .{};
    inline for (.{ .{ "font", 2 }, .{ "pixels", 0 }, .{ "vertical", 2 }, .{ "hinting", 3 }, .{ "body_length", 129 }, .{ "ruby_length", 65 } }) |bad| {
        var request = Request{ .id = 1, .operation = .render_text, .render = render };
        @field(request.render, bad[0]) = bad[1];
        try std.testing.expectError(error.InvalidPayload, state.accept(request));
        try std.testing.expectEqual(@as(u32, 1), state.next_id);
    }
    try std.testing.expectError(error.InvalidPayload, Render.init(0, 24, 0, 0, "\xc0\x80", ""));
    try std.testing.expectError(error.InvalidPayload, Render.init(0, 24, 0, 0, "", ""));
    try std.testing.expectError(error.InvalidPayload, Render.init(0, 24, 0, 0, "A", "\xe3\x81"));
    try std.testing.expectEqual(@as(usize, 216), @sizeOf(Render));
    try std.testing.expectEqual(@as(usize, 220), @sizeOf(Job));
    try state.accept(.{ .id = 1, .operation = .render_text, .render = render });
}

test "glyph output bounds and failed output forbid partial or stale publication" {
    try std.testing.expectEqual(@as(usize, 48), @sizeOf(Glyph));
    try std.testing.expectEqual(@as(usize, 776), @sizeOf(Output));
    var output: Output = .{};
    try output.validate();
    output.count = 1;
    output.glyphs[0] = .{ .id = 4, .pixels = 24, .width = 20, .height = 22, .x_advance = 1536, .top = 21 };
    try std.testing.expectError(error.InvalidOutput, output.validate());
    output.outcome = 0;
    try output.validate();
    output.count = 17;
    try std.testing.expectError(error.InvalidOutput, output.validate());
    output.count = 1;
    output.glyphs[1].id = 99;
    try std.testing.expectError(error.InvalidOutput, output.validate());
    output.glyphs[1] = .{};
    output.glyphs[0].run = 2;
    try std.testing.expectError(error.InvalidOutput, output.validate());
}
