//! Real checkpoints, independent of animation time and of the text-log ring.
const std = @import("std");
pub const Stage = enum(u8) { crt, memory, storage, display_prepare, cores, display_scanout, console };
pub const Outcome = enum(u8) { pending, running, complete, unavailable, failed };
pub const Key = enum { escape, break_boot, other };
pub const Model = struct {
    outcomes: [7]Outcome = @splat(.pending),
    active: ?Stage = null,
    last_complete: ?Stage = null,
    failed: ?Stage = null,
    error_code: u32 = 0,
    failure_latched: bool = false,
    input_available: bool = false,
    details: bool = false,
    pause_requested: bool = false,
    pub noinline fn begin(self: *Model, stage: Stage) bool {
        if (self.active != null or self.failure_latched or self.outcomes[@backingInt(stage)] != .pending) return false;
        self.outcomes[@backingInt(stage)] = .running;
        self.active = stage;
        return true;
    }
    pub noinline fn complete(self: *Model, stage: Stage) bool {
        if (self.failure_latched or self.active != stage) return false;
        self.outcomes[@backingInt(stage)] = .complete;
        self.last_complete = stage;
        self.active = null;
        return true;
    }
    pub fn unavailable(self: *Model, stage: Stage) bool {
        if (self.failure_latched or self.outcomes[@backingInt(stage)] != .pending) return false;
        self.outcomes[@backingInt(stage)] = .unavailable;
        return true;
    }
    pub fn fail(self: *Model, code: u32) void {
        if (self.failure_latched) return;
        self.failure_latched = true;
        self.failed = self.active;
        if (self.active) |stage| self.outcomes[@backingInt(stage)] = .failed;
        self.error_code = code;
        self.details = true;
    }
    /// An input adapter calls this only for a decoded physical/serial key event.
    /// It requests a view/pause; it does not execute a shell or unwind a driver.
    pub fn onKey(self: *Model, key: Key) bool {
        if (!self.input_available or key == .other) return false;
        self.details = true;
        if (key == .break_boot) self.pause_requested = true;
        return true;
    }
    pub fn atSafeCheckpoint(self: *const Model) bool {
        return self.pause_requested and self.active == null and !self.failure_latched;
    }
    /// Proposed milestone-driven dye target, not a progress percentage.
    /// Timer/frame interpolation may approach this target but never exceed it.
    pub fn dyeTarget(self: *const Model) u8 {
        if (self.outcomes[@backingInt(Stage.memory)] != .complete) return 0;
        if (self.outcomes[@backingInt(Stage.cores)] != .complete) return 85;
        if (self.outcomes[@backingInt(Stage.console)] != .complete or self.outcomes[@backingInt(Stage.display_scanout)] != .complete) return 170;
        return 255;
    }
};

test "a stuck stage stays running and does not acquire completion colour" {
    var model = Model{};
    try std.testing.expect(model.begin(.memory));
    try std.testing.expect(!model.complete(.cores));
    try std.testing.expect(!model.begin(.cores));
    try std.testing.expectEqual(@as(u8, 0), model.dyeTarget());
    try std.testing.expect(model.complete(.memory));
    try std.testing.expectEqual(@as(u8, 85), model.dyeTarget());
    try std.testing.expect(model.begin(.cores));
    model.fail(4);
    try std.testing.expectEqual(Stage.memory, model.last_complete.?);
    try std.testing.expectEqual(Stage.cores, model.failed.?);
    try std.testing.expect(!model.complete(.cores));
    try std.testing.expectEqual(@as(u8, 85), model.dyeTarget());
}

test "a diagnostic key is capability gated and pauses only at a returned checkpoint" {
    var model = Model{};
    try std.testing.expect(!model.onKey(.escape));
    try std.testing.expect(!model.details);
    model.input_available = true;
    try std.testing.expect(model.begin(.storage));
    try std.testing.expect(model.onKey(.break_boot));
    try std.testing.expect(!model.atSafeCheckpoint());
    try std.testing.expect(model.complete(.storage));
    try std.testing.expect(model.atSafeCheckpoint());
}

test "unavailable storage is explicit and does not count as completion" {
    var model = Model{};
    try std.testing.expect(model.unavailable(.storage));
    try std.testing.expect(!model.complete(.storage));
    try std.testing.expect(!model.begin(.storage));
    try std.testing.expectEqual(Outcome.unavailable, model.outcomes[@backingInt(Stage.storage)]);
}

test "failure between operations is sticky without inventing a failed stage" {
    var model = Model{};
    try std.testing.expect(model.begin(.memory));
    try std.testing.expect(model.complete(.memory));
    model.fail(7);
    try std.testing.expect(model.failed == null);
    try std.testing.expect(model.failure_latched);
    try std.testing.expect(!model.begin(.cores));
    model.fail(8);
    try std.testing.expectEqual(@as(u32, 7), model.error_code);
}
