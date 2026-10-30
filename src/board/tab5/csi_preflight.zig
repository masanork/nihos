//! CPU0 foreground CSI receiver-only diagnostic. No DMA or sensor stream.
const std = @import("std");
pub const State = enum(u32) { idle, prepare, stop, done, pinned };
pub const Result = enum(u32) { none, ready, busy, prepare_failed, cleanup_failed };
pub const Diagnostic = struct {
    state: State = .idle,
    result: Result = .none,
    pub fn start(self: *Diagnostic) bool {
        if (self.state != .idle) return false;
        self.state = .prepare;
        return true;
    }
    /// Implementations serialize all CSI/ISP and RCC access. On -3 the
    /// prepare operation touched hardware and must be stopped even on failure.
    pub fn poll(self: *Diagnostic, hardware: anytype) void {
        switch (self.state) {
            .prepare => switch (hardware.prepare()) {
                0 => {
                    self.result = .ready;
                    self.state = .stop;
                },
                -3 => {
                    self.result = .prepare_failed;
                    self.state = .stop;
                },
                else => {
                    self.result = .busy;
                    self.state = .done;
                },
            },
            .stop => {
                if (!hardware.stop()) {
                    self.result = .cleanup_failed;
                    self.state = .pinned;
                } else self.state = .done;
            },
            else => {},
        }
    }
};
const Fake = struct {
    value: i32 = 0,
    stopped: bool = true,
    calls: u32 = 0,
    fn prepare(self: *Fake) i32 {
        self.calls += 1;
        return self.value;
    }
    fn stop(self: *Fake) bool {
        self.calls += 1;
        return self.stopped;
    }
};
test "successful receiver preparation is not done until stop succeeds" {
    var d: Diagnostic = .{};
    var h: Fake = .{};
    try std.testing.expect(d.start());
    d.poll(&h);
    try std.testing.expectEqual(State.stop, d.state);
    d.poll(&h);
    try std.testing.expectEqual(State.done, d.state);
    try std.testing.expectEqual(Result.ready, d.result);
}
test "partial prepare needs cleanup; failed cleanup pins the owner" {
    var d: Diagnostic = .{};
    var h: Fake = .{ .value = -3, .stopped = false };
    _ = d.start();
    d.poll(&h);
    d.poll(&h);
    try std.testing.expectEqual(State.pinned, d.state);
    try std.testing.expectEqual(Result.cleanup_failed, d.result);
    try std.testing.expect(!d.start());
    d = .{};
    h = .{ .value = -2 };
    _ = d.start();
    d.poll(&h);
    try std.testing.expectEqual(State.done, d.state);
    try std.testing.expectEqual(Result.busy, d.result);
    try std.testing.expectEqual(@as(u32, 1), h.calls);
}
