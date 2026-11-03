//! Single boot-epoch arbitration for the native P4 RNG register.
//! This does not enable the analog noise source or qualify entropy.
const std = @import("std");

/// The SQLite task holds the gate throughout every operation which may call
/// its randomness callback. Entropy clients hold a generation-bound token.
/// All register consumers must use this same instance. Never copy or reset it.
pub const Gate = struct {
    const sqlite: u32 = 1;
    const allocating: u32 = std.math.maxInt(u32);
    state: u32 = 0,
    next: u32 = 2,

    pub fn trySqlite(self: *Gate) bool {
        return @cmpxchgStrong(u32, &self.state, 0, sqlite, .acquire, .monotonic) == null;
    }
    pub fn releaseSqlite(self: *Gate) bool {
        return @cmpxchgStrong(u32, &self.state, sqlite, 0, .release, .monotonic) == null;
    }
    /// Returns zero when busy or the boot-epoch token space is exhausted.
    pub fn tryEntropy(self: *Gate) u32 {
        if (@cmpxchgStrong(u32, &self.state, 0, allocating, .acquire, .monotonic) != null) return 0;
        // The allocator marker serializes access to next across both cores.
        const token = self.next;
        if (token == 0) {
            @atomicStore(u32, &self.state, 0, .release);
            return 0;
        }
        self.next = token +% 2;
        @atomicStore(u32, &self.state, token, .release);
        return token;
    }
    pub fn ownsEntropy(self: *Gate, token: u32) bool {
        return token != 0 and token != sqlite and token != allocating and token & 1 == 0 and
            @atomicLoad(u32, &self.state, .acquire) == token;
    }
    pub fn releaseEntropy(self: *Gate, token: u32) bool {
        if (token == 0 or token == sqlite or token == allocating or token & 1 != 0) return false;
        return @cmpxchgStrong(u32, &self.state, token, 0, .release, .monotonic) == null;
    }
};

test "SQLite and entropy exclude each other and stale tokens cannot unlock" {
    var gate: Gate = .{};
    try std.testing.expect(gate.trySqlite());
    try std.testing.expectEqual(@as(u32, 0), gate.tryEntropy());
    try std.testing.expect(!gate.releaseEntropy(2));
    try std.testing.expect(gate.releaseSqlite());
    const first = gate.tryEntropy();
    try std.testing.expect(first != 0 and gate.ownsEntropy(first));
    try std.testing.expect(!gate.trySqlite());
    try std.testing.expect(!gate.releaseSqlite());
    try std.testing.expect(gate.releaseEntropy(first));
    const second = gate.tryEntropy();
    try std.testing.expect(second != first and gate.ownsEntropy(second));
    try std.testing.expect(!gate.releaseEntropy(first));
    try std.testing.expect(gate.ownsEntropy(second));
    try std.testing.expect(gate.releaseEntropy(second));
    try std.testing.expect(gate.trySqlite());
    try std.testing.expect(gate.releaseSqlite());
}

test "exhausted token space fails closed without blocking SQLite" {
    var gate: Gate = .{ .next = std.math.maxInt(u32) - 1 };
    const last = gate.tryEntropy();
    try std.testing.expectEqual(std.math.maxInt(u32) - 1, last);
    try std.testing.expect(gate.releaseEntropy(last));
    try std.testing.expectEqual(@as(u32, 0), gate.tryEntropy());
    try std.testing.expect(gate.trySqlite());
    try std.testing.expect(gate.releaseSqlite());
}

test "two threads never enter SQLite and entropy sections together" {
    const Worker = struct {
        gate: *Gate,
        inside: *u32,
        overlap: *u32,
        fn run(self: *@This(), entropy: bool) void {
            for (0..10_000) |_| {
                var token: u32 = 0;
                if (entropy) {
                    while (token == 0) token = self.gate.tryEntropy();
                } else {
                    while (!self.gate.trySqlite()) {}
                }
                if (@atomicRmw(u32, self.inside, .Add, 1, .acq_rel) != 0)
                    @atomicStore(u32, self.overlap, 1, .release);
                _ = @atomicRmw(u32, self.inside, .Sub, 1, .acq_rel);
                const released = if (entropy) self.gate.releaseEntropy(token) else self.gate.releaseSqlite();
                if (!released) @atomicStore(u32, self.overlap, 1, .release);
            }
        }
    };
    var gate: Gate = .{};
    var inside: u32 = 0;
    var overlap: u32 = 0;
    var worker = Worker{ .gate = &gate, .inside = &inside, .overlap = &overlap };
    const thread = try std.Thread.spawn(.{}, Worker.run, .{ &worker, true });
    worker.run(false);
    thread.join();
    try std.testing.expectEqual(@as(u32, 0), @atomicLoad(u32, &overlap, .acquire));
}
