//! Debounced physical insertion gate. Authentication never starts twice while held.
pub const Event = enum { none, detect, removed };
pub const State = enum { waiting, active, removal, retired };
pub const Gate = struct {
    state: State = .waiting,
    stable: u2 = 0,
    previous: bool = false,
    job: u32 = 0,
    pub fn observe(self: *Gate, present: bool) Event {
        if (self.state == .retired) return .none;
        if (present != self.previous) self.stable = 0;
        self.previous = present;
        self.stable = @intCast(@min(2, @as(u3, self.stable) + 1));
        if (self.stable < 2) return .none;
        if (self.state == .waiting and present) {
            if (self.job == 0xffffffff) {
                self.state = .retired;
                return .none;
            }
            self.job += 1;
            self.state = .active;
            return .detect;
        }
        if (!present and (self.state == .active or self.state == .removal)) {
            self.state = .waiting;
            return .removed;
        }
        return .none;
    }
    pub fn finish(self: *Gate) void {
        if (self.state != .retired) self.state = .removal;
        self.stable = 0;
    }
};
test "held card and glitches cannot repeat a job; only stable removal rearms" {
    const t = @import("std").testing;
    var gate = Gate{};
    try t.expectEqual(Event.none, gate.observe(true));
    try t.expectEqual(Event.detect, gate.observe(true));
    gate.finish();
    for (0..100) |_| try t.expectEqual(Event.none, gate.observe(true));
    try t.expectEqual(Event.none, gate.observe(false));
    try t.expectEqual(Event.none, gate.observe(true));
    try t.expectEqual(Event.none, gate.observe(false));
    try t.expectEqual(Event.removed, gate.observe(false));
    _ = gate.observe(true);
    try t.expectEqual(Event.detect, gate.observe(true));
    try t.expectEqual(@as(u32, 2), gate.job);
}
