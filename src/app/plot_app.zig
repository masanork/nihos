//! Plot application lifecycle over the common event contract, without I/O.
const std = @import("std");
pub const protocol = @import("protocol.zig");
pub const animation = @import("animation.zig");
pub const Session = struct {
    model: animation.Model = .{},
    held: u32 = 0,
    pressed: u32 = 0,
    released: u32 = 0,
    stopped: bool = false,
    focused: bool = true,

    pub fn dispatch(self: *Session, event: protocol.Event) protocol.Status {
        const valid = event.validate();
        if (valid != .ok) return valid;
        const kind: protocol.Kind = @fromBackingInt(@intCast(event.kind));
        if (self.stopped) return if (kind == .cancel) .ok else .closed;
        if (!self.focused and (kind == .key_down or kind == .key_up)) return .inactive;
        const previous = self.snapshot();
        self.pressed = 0;
        self.released = 0;
        switch (kind) {
            .tick => _ = self.model.advance(event.monotonic_us),
            .key_down, .key_up => {
                const bit = @as(u32, 1) << @as(u5, @intCast(event.code));
                const down = kind == .key_down;
                if (down) {
                    self.pressed = bit & ~self.held;
                    self.held |= bit;
                } else {
                    self.released = bit & self.held;
                    self.held &= ~bit;
                }
                // Slots 0..3 are plot controls; 4..31 are retained for app input.
                if (event.code <= @backingInt(animation.Key.reset)) self.model.key(@fromBackingInt(@intCast(event.code)), down, event.monotonic_us) else _ = self.model.advance(event.monotonic_us);
            },
            .focus_lost, .cancel => {
                self.released = self.held;
                self.held = 0;
                self.focused = false;
                self.stopped = kind == .cancel;
                self.model.state.held = 0;
                self.model.state.paused = 1;
                self.model.last_us = event.monotonic_us;
                self.model.remainder_us = 0;
                self.model.state.generation +%= 1;
            },
            .focus_gained => {
                self.focused = true;
                self.model.last_us = event.monotonic_us;
                self.model.remainder_us = 0;
                // Focus gain never resumes execution implicitly.
            },
        }
        return if (std.meta.eql(previous, self.snapshot())) .ok else .changed;
    }
    pub fn snapshot(self: *const Session) protocol.Snapshot {
        const state = self.model.state;
        return .{ .ticks = state.ticks, .phase = state.phase, .generation = state.generation, .dropped_us = state.dropped_us, .paused = state.paused, .speed = state.speed, .held = self.held, .pressed = self.pressed, .released = self.released, .stopped = @intFromBool(self.stopped), .focused = @intFromBool(self.focused) };
    }
};

fn testEvent(kind: protocol.Kind, code: u32, now: u64) protocol.Event {
    return .{ .kind = @backingInt(kind), .code = code, .monotonic_us = now };
}
test "input edges, focus and cancel have bounded lifecycle with no hidden update" {
    var app = Session{};
    _ = app.dispatch(testEvent(.tick, 0, 0));
    _ = app.dispatch(testEvent(.key_down, 31, 0));
    try std.testing.expectEqual(@as(u32, 0x80000000), app.snapshot().pressed);
    _ = app.dispatch(testEvent(.key_down, 31, 0));
    try std.testing.expectEqual(@as(u32, 0), app.snapshot().pressed);
    _ = app.dispatch(testEvent(.focus_lost, 0, 10_000_000));
    try std.testing.expectEqual(@as(u64, 0), app.snapshot().ticks);
    try std.testing.expectEqual(@as(u32, 0x80000000), app.snapshot().released);
    const lost = app.snapshot();
    try std.testing.expectEqual(protocol.Status.inactive, app.dispatch(testEvent(.key_down, 0, 11_000_000)));
    try std.testing.expectEqualDeep(lost, app.snapshot());
    _ = app.dispatch(testEvent(.focus_gained, 0, 20_000_000));
    _ = app.dispatch(testEvent(.tick, 0, 21_000_000));
    try std.testing.expectEqual(@as(u64, 0), app.snapshot().ticks);
    _ = app.dispatch(testEvent(.key_down, 0, 21_000_000));
    _ = app.dispatch(testEvent(.key_up, 0, 21_000_000));
    _ = app.dispatch(testEvent(.tick, 0, 21_000_000 + animation.step_us));
    try std.testing.expectEqual(@as(u64, 1), app.snapshot().ticks);
    _ = app.dispatch(testEvent(.cancel, 0, 100_000_000));
    const cancelled = app.snapshot();
    try std.testing.expectEqual(@as(u64, 1), cancelled.ticks);
    try std.testing.expectEqual(protocol.Status.closed, app.dispatch(testEvent(.tick, 0, 200_000_000)));
    try std.testing.expectEqual(protocol.Status.closed, app.dispatch(testEvent(.focus_gained, 0, 200_000_000)));
    try std.testing.expectEqual(protocol.Status.ok, app.dispatch(testEvent(.cancel, 0, 200_000_000)));
    try std.testing.expectEqualDeep(cancelled, app.snapshot());
}
test "invalid event cannot change input or clock state" {
    var app = Session{};
    _ = app.dispatch(testEvent(.key_down, 2, 0));
    const before = app;
    try std.testing.expectEqual(protocol.Status.invalid, app.dispatch(.{ .kind = 1, .code = 32, .monotonic_us = 100_000_000 }));
    try std.testing.expectEqualDeep(before, app);
}
