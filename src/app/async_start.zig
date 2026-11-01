//! Foreground-owned startup policy. The worker and its backing outlive cancel.
const std = @import("std");

pub const Phase = enum { idle, opening, cancelling, ready, closing, reaping, done };
pub const Action = enum { none, start_open, start_close, publish_ready, release, fail };

pub const Startup = struct {
    phase: Phase = .idle,
    generation: u32 = 0,
    result: i32 = 0,

    pub fn begin(self: *Startup, generation: u32) ?Action {
        if (self.phase != .idle or generation == 0) return null;
        self.generation = generation;
        self.phase = .opening;
        return .start_open;
    }

    /// Cancellation is cooperative: no storage is released while open runs.
    pub fn cancel(self: *Startup) Action {
        return switch (self.phase) {
            .opening => blk: {
                self.phase = .cancelling;
                break :blk .none;
            },
            .ready => blk: {
                self.phase = .closing;
                break :blk .start_close;
            },
            else => .none,
        };
    }

    pub fn opened(self: *Startup, generation: u32, result: i32) ?Action {
        if (generation != self.generation or (self.phase != .opening and self.phase != .cancelling)) return null;
        self.result = result;
        if (result != 0) {
            self.phase = .reaping;
            return .none;
        }
        if (self.phase == .cancelling) {
            self.phase = .closing;
            return .start_close;
        }
        self.phase = .ready;
        return .publish_ready;
    }

    pub fn closed(self: *Startup, generation: u32, result: i32) ?Action {
        if (generation != self.generation or self.phase != .closing) return null;
        self.result = result;
        self.phase = .reaping;
        return .none;
    }

    /// Called only after the task runtime has actually reaped this generation.
    pub fn reaped(self: *Startup, generation: u32, arenas_recovered: bool) ?Action {
        if (generation != self.generation or self.phase != .reaping) return null;
        self.phase = .done;
        return if (arenas_recovered) .release else .fail;
    }
};

test "cancel during open never publishes and only releases after matching reap" {
    var s: Startup = .{};
    try std.testing.expectEqual(Action.start_open, s.begin(7).?);
    try std.testing.expectEqual(Action.none, s.cancel());
    try std.testing.expect(s.reaped(7, true) == null);
    try std.testing.expect(s.opened(6, 0) == null);
    try std.testing.expectEqual(Action.start_close, s.opened(7, 0).?);
    try std.testing.expect(s.reaped(7, true) == null);
    try std.testing.expectEqual(Action.none, s.closed(7, 0).?);
    try std.testing.expect(s.reaped(6, true) == null);
    try std.testing.expectEqual(Action.release, s.reaped(7, true).?);
    try std.testing.expect(s.reaped(7, true) == null);
}

test "open failure and damaged arena cannot release borrowed storage" {
    var failed: Startup = .{};
    _ = failed.begin(3);
    try std.testing.expectEqual(Action.none, failed.opened(3, -41).?);
    try std.testing.expectEqual(Action.fail, failed.reaped(3, false).?);
    var ready: Startup = .{};
    _ = ready.begin(4);
    try std.testing.expectEqual(Action.publish_ready, ready.opened(4, 0).?);
    try std.testing.expectEqual(Action.start_close, ready.cancel());
    try std.testing.expectEqual(Action.none, ready.closed(4, 0).?);
    try std.testing.expectEqual(Action.release, ready.reaped(4, true).?);
}
