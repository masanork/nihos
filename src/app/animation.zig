//! Host-independent, bounded fixed-step clock. Time is supplied by the owner.
const std = @import("std");
pub const step_us: u64 = 16_667;
pub const max_steps: u64 = 4;
pub const Key = enum(u8) { pause, slower, faster, reset };
pub const State = extern struct {
    ticks: u64 = 0,
    phase: u64 = 0,
    generation: u64 = 1,
    dropped_us: u64 = 0,
    paused: u32 = 0,
    speed: u32 = 2,
    held: u32 = 0,
};
pub const Model = struct {
    state: State = .{},
    last_us: ?u64 = null,
    remainder_us: u64 = 0,

    pub fn advance(self: *Model, now_us: u64) bool {
        const previous = self.last_us orelse {
            self.last_us = now_us;
            return false;
        };
        // Rebase after a clock reset rather than underflowing or catching up.
        self.last_us = now_us;
        if (now_us < previous) {
            self.remainder_us = 0;
            return false;
        }
        if (self.state.paused != 0) return false;
        const elapsed = now_us - previous;
        const accepted = @min(elapsed, step_us * max_steps);
        self.state.dropped_us +|= elapsed - accepted;
        const total = self.remainder_us + accepted;
        const steps = total / step_us;
        self.remainder_us = total % step_us;
        if (steps == 0) return false;
        self.state.ticks +%= steps;
        self.state.phase +%= steps * self.state.speed;
        self.state.generation +%= 1;
        return true;
    }

    pub fn key(self: *Model, value: Key, down: bool, now_us: u64) void {
        _ = self.advance(now_us);
        const bit = @as(u32, 1) << @as(u5, @intCast(@backingInt(value)));
        if (!down) {
            self.state.held &= ~bit;
            return;
        }
        if (self.state.held & bit != 0) return;
        self.state.held |= bit;
        switch (value) {
            .pause => self.state.paused ^= 1,
            .slower => self.state.speed = @max(1, self.state.speed - 1),
            .faster => self.state.speed = @min(8, self.state.speed + 1),
            .reset => {
                self.state.ticks = 0;
                self.state.phase = 0;
                self.state.dropped_us = 0;
                self.remainder_us = 0;
            },
        }
        self.state.generation +%= 1;
    }

    pub fn focusLost(self: *Model, now_us: u64) void {
        _ = self.advance(now_us);
        self.state.held = 0;
        self.state.paused = 1;
        self.state.generation +%= 1;
    }
};

test "equal elapsed time gives equal ticks independent of callback rate" {
    var fine = Model{};
    var coarse = Model{};
    _ = fine.advance(0);
    _ = coarse.advance(0);
    for (1..121) |n| _ = fine.advance(n * step_us / 2);
    for (1..31) |n| _ = coarse.advance(n * step_us * 2);
    try std.testing.expectEqual(@as(u64, 60), fine.state.ticks);
    try std.testing.expectEqual(fine.state.ticks, coarse.state.ticks);
}

test "pause releases do not toggle and resume never catches up paused time" {
    var model = Model{};
    _ = model.advance(0);
    model.key(.pause, true, step_us);
    model.key(.pause, true, step_us * 2); // OS key repeat.
    model.key(.pause, false, step_us * 3);
    const ticks = model.state.ticks;
    const generation = model.state.generation;
    try std.testing.expect(!model.advance(10_000_000));
    try std.testing.expectEqual(generation, model.state.generation);
    model.key(.pause, true, 20_000_000);
    model.key(.pause, false, 20_000_000);
    try std.testing.expect(model.advance(20_000_000 + step_us));
    try std.testing.expectEqual(ticks + 1, model.state.ticks);
}

test "overload and backwards clocks are bounded and focus loss clears held input" {
    var model = Model{};
    _ = model.advance(100);
    try std.testing.expect(model.advance(1_000_100));
    try std.testing.expectEqual(max_steps, model.state.ticks);
    try std.testing.expectEqual(1_000_000 - step_us * max_steps, model.state.dropped_us);
    try std.testing.expect(!model.advance(0));
    model.key(.faster, true, 0);
    model.focusLost(0);
    try std.testing.expectEqual(@as(u32, 0), model.state.held);
    try std.testing.expectEqual(@as(u32, 1), model.state.paused);
    model.key(.faster, true, 0);
    try std.testing.expectEqual(@as(u32, 4), model.state.speed);
}
