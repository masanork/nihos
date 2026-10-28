//! Experimental, pointer-free qualification protocol. One client dispatcher
//! owns submission; a single font task owns library state. This finite render
//! matrix is not a paragraph, glyph-buffer or application session API.
const std = @import("std");

pub const Operation = enum(u32) { render_matrix, stop };
pub const Request = struct { id: u32, operation: Operation };
pub const Reply = struct {
    id: u32,
    operation: Operation,
    runs: u32 = 0,
    hashes: [16]u32 = @splat(0),
    retained: u32,
};

pub const State = struct {
    next_id: u32 = 1,
    active: ?u32 = null,
    stopped: bool = false,
    pub const Error = error{ Closed, Busy, Sequence, Exhausted };

    pub fn accept(self: *State, request: Request) Error!void {
        if (self.stopped) return error.Closed;
        if (self.active != null) return error.Busy;
        if (request.id != self.next_id) return error.Sequence;
        // Do not wrap an ID and accidentally accept an old request.
        if (self.next_id == std.math.maxInt(u32)) return error.Exhausted;
        self.next_id += 1;
        switch (request.operation) {
            .render_matrix => self.active = request.id,
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
