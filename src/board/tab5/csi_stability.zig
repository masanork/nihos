//! Host-tested incremental comparison of two pinned-frame scans. Neither the
//! per-chunk FNV nor full-frame SHA-256 constitutes a DMA retirement fence.
const std = @import("std");
pub fn Scan(comptime chunks: usize) type {
    return struct {
        const Self = @This();
        pub const Phase = enum(u32) { idle, first, gap, done, failed, second, zeroing };
        phase: Phase = .idle,
        first: [chunks]u32 = @splat(0),
        index: usize = 0,
        changed: u32 = 0,
        sha_match: u32 = 0,
        inject: bool = false,
        injected: bool = false,
        zero_before: bool = false,
        zeroed: u32 = 0,
        nonzero: u32 = 0,
        sha: @import("camera_sha256.zig").Sha256 = @import("camera_sha256.zig").Sha256.init(.{}),
        first_sha: [32]u8 = @splat(0),
        deadline: u64 = 0,
        last: u64 = 0,
        gap_polls: u32 = 0,
        pub fn start(self: *Self) bool {
            if (self.phase != .idle or chunks == 0) return false;
            self.phase = if (self.zero_before) .zeroing else .first;
            return true;
        }
        /// Up to four chunks and a 1 ms soft budget per foreground visit. A
        /// chunk already in progress cannot be preempted by this budget.
        pub fn pollBatch(self: *Self, backend: anytype, timing: *Timing) void {
            const start_time = backend.counter() orelse {
                self.phase = .failed;
                timing.valid = false;
                return;
            };
            var last_time = start_time;
            var scans: u32 = 0;
            for (0..4) |_| {
                const before_phase = @backingInt(self.phase);
                if (self.phase == .done or self.phase == .failed or self.phase == .idle) break;
                const before = backend.counter() orelse {
                    self.phase = .failed;
                    timing.valid = false;
                    break;
                };
                if (before < last_time) {
                    self.phase = .failed;
                    timing.valid = false;
                    break;
                }
                self.poll(backend, before);
                const after = backend.counter() orelse {
                    self.phase = .failed;
                    timing.valid = false;
                    break;
                };
                if (after < before) {
                    self.phase = .failed;
                    timing.valid = false;
                    break;
                }
                // The gap starts after the last chunk finishes, not at its
                // start timestamp. This includes SHA finalization in the pass.
                if (before_phase == 1 and self.phase == .gap) {
                    self.deadline = std.math.add(u64, after, 50_000) catch {
                        self.phase = .failed;
                        timing.valid = false;
                        break;
                    };
                    self.last = after;
                }
                timing.observe(before_phase, @backingInt(self.phase), before, after);
                if (before_phase == 1 or before_phase == 5) scans += 1;
                last_time = after;
                if (after - start_time >= 1000 or @backingInt(self.phase) != before_phase) break;
            }
            if (scans != 0) {
                const elapsed = last_time - start_time;
                if (elapsed > std.math.maxInt(u32)) timing.valid = false else {
                    timing.max_batch_us = @max(timing.max_batch_us, @as(u32, @intCast(elapsed)));
                    timing.batches += 1;
                }
            }
        }
        /// One bounded chunk per poll; the backend must verify frame identity,
        /// DMA ownership and cache invalidation before every chunk read.
        pub fn poll(self: *Self, backend: anytype, now: ?u64) void {
            switch (self.phase) {
                .zeroing => {
                    if (!backend.zero(self.index)) {
                        self.phase = .failed;
                        return;
                    }
                    self.zeroed += 1;
                    self.index += 1;
                    if (self.index == chunks) {
                        self.index = 0;
                        self.phase = .first;
                    }
                },
                .first, .second => {
                    const bytes = backend.chunk(self.index) orelse {
                        self.phase = .failed;
                        return;
                    };
                    if (bytes.len == 0) {
                        self.phase = .failed;
                        return;
                    }
                    self.sha.update(bytes);
                    if (self.zero_before) {
                        for (bytes) |byte| if (byte != 0) {
                            self.nonzero += 1;
                            break;
                        };
                    }
                    var hash: u32 = 2166136261;
                    for (bytes) |byte| hash = (hash ^ byte) *% 16777619;
                    if (self.phase == .first) self.first[self.index] = hash else if (self.first[self.index] != hash) {
                        self.changed += 1;
                    }
                    self.index += 1;
                    if (self.index == chunks) {
                        self.index = 0;
                        var digest: [32]u8 = undefined;
                        self.sha.final(&digest);
                        if (self.phase == .second) {
                            self.sha_match = @intFromBool(std.mem.eql(u8, &digest, &self.first_sha));
                            self.phase = .done;
                            return;
                        }
                        self.first_sha = digest;
                        self.sha = @import("camera_sha256.zig").Sha256.init(.{});
                        const stamp = now orelse {
                            self.phase = .failed;
                            return;
                        };
                        self.deadline = std.math.add(u64, stamp, 50_000) catch {
                            self.phase = .failed;
                            return;
                        };
                        self.last = stamp;
                        self.phase = .gap;
                    }
                },
                .gap => {
                    const stamp = now orelse {
                        self.phase = .failed;
                        return;
                    };
                    if (stamp < self.last) {
                        self.phase = .failed;
                        return;
                    }
                    self.last = stamp;
                    self.gap_polls += 1;
                    if (stamp >= self.deadline) {
                        if (self.inject) {
                            if (!backend.flip(chunks - 1)) {
                                self.phase = .failed;
                                return;
                            }
                            self.injected = true;
                        }
                        self.phase = .second;
                    } else if (self.gap_polls >= 1024) {
                        self.phase = .failed;
                    }
                },
                else => {},
            }
        }
    };
}
/// Wall-time telemetry for incremental scan work, including preemption and
/// timer-read overhead. It is not a CPU-time or video throughput measurement.
pub const Timing = struct {
    valid: bool = true,
    first_start: ?u64 = null,
    second_start: ?u64 = null,
    last: ?u64 = null,
    first_us: u32 = 0,
    second_us: u32 = 0,
    max_step_us: u32 = 0,
    steps: u32 = 0,
    max_batch_us: u32 = 0,
    batches: u32 = 0,
    pub fn observe(self: *Timing, before_phase: u32, after_phase: u32, before: ?u64, after: ?u64) void {
        if (!self.valid or (before_phase != 1 and before_phase != 5)) return;
        const a = before orelse {
            self.valid = false;
            return;
        };
        const b = after orelse {
            self.valid = false;
            return;
        };
        if (b < a or (self.last != null and a < self.last.?)) {
            self.valid = false;
            return;
        }
        self.last = b;
        const duration = b - a;
        if (duration > std.math.maxInt(u32)) {
            self.valid = false;
            return;
        }
        self.max_step_us = @max(self.max_step_us, @as(u32, @intCast(duration)));
        self.steps += 1;
        if (before_phase == 1 and self.first_start == null) self.first_start = a;
        if (before_phase == 5 and self.second_start == null) self.second_start = a;
        if (before_phase == 1 and after_phase == 2) {
            const elapsed = b - self.first_start.?;
            if (elapsed > std.math.maxInt(u32)) {
                self.valid = false;
                return;
            }
            self.first_us = @intCast(elapsed);
        }
        if (before_phase == 5 and after_phase == 3) {
            const elapsed = b - self.second_start.?;
            if (elapsed > std.math.maxInt(u32)) {
                self.valid = false;
                return;
            }
            self.second_us = @intCast(elapsed);
        }
    }
};
test "timing measures scan spans, individual polls and rejects bad clocks" {
    var t: Timing = .{};
    t.observe(1, 1, 10, 20);
    t.observe(1, 2, 40, 50);
    t.observe(5, 5, 100, 103);
    t.observe(5, 3, 120, 125);
    try std.testing.expect(t.valid);
    try std.testing.expectEqual(@as(u32, 40), t.first_us);
    try std.testing.expectEqual(@as(u32, 25), t.second_us);
    try std.testing.expectEqual(@as(u32, 10), t.max_step_us);
    try std.testing.expectEqual(@as(u32, 4), t.steps);
    t.observe(5, 3, 124, 130);
    try std.testing.expect(!t.valid);
    var missing: Timing = .{};
    missing.observe(1, 1, null, 3);
    try std.testing.expect(!missing.valid);
}
const Fake = struct {
    values: [2][4]u8 = .{ .{ 11, 0, 0, 0 }, .{ 22, 0, 0, 0 } },
    fail: bool = false,
    fn chunk(self: *Fake, i: usize) ?[]const u8 {
        return if (self.fail) null else &self.values[i];
    }
    fn zero(self: *Fake, i: usize) bool {
        if (self.fail) return false;
        @memset(&self.values[i], 0);
        return true;
    }
    fn flip(self: *Fake, i: usize) bool {
        if (self.fail) return false;
        self.values[i][0] ^= 1;
        return true;
    }
};
test "two scans detect changed chunk after a real timer gap" {
    var scan: Scan(2) = .{};
    var fake: Fake = .{};
    try std.testing.expect(scan.start());
    scan.poll(&fake, 100);
    scan.poll(&fake, 101);
    try std.testing.expectEqual(Scan(2).Phase.gap, scan.phase);
    scan.poll(&fake, 50100);
    try std.testing.expectEqual(Scan(2).Phase.gap, scan.phase);
    scan.poll(&fake, 50101);
    fake.values[0][0] += 1;
    scan.poll(&fake, 50102);
    scan.poll(&fake, 50103);
    try std.testing.expectEqual(Scan(2).Phase.done, scan.phase);
    try std.testing.expectEqual(@as(u32, 1), scan.changed);
    try std.testing.expectEqual(@as(u32, 0), scan.sha_match);
}
test "cache failure and stalled clock fail closed" {
    var scan: Scan(2) = .{};
    var fake: Fake = .{ .fail = true };
    try std.testing.expect(scan.start());
    scan.poll(&fake, 1);
    try std.testing.expectEqual(Scan(2).Phase.failed, scan.phase);
    scan = .{};
    fake.fail = false;
    try std.testing.expect(scan.start());
    scan.poll(&fake, 1);
    scan.poll(&fake, 1);
    for (0..1024) |_| scan.poll(&fake, 1);
    try std.testing.expectEqual(Scan(2).Phase.failed, scan.phase);
}

test "unchanged two-pass digest matches" {
    var scan: Scan(2) = .{};
    var fake: Fake = .{};
    try std.testing.expect(scan.start());
    scan.poll(&fake, 1);
    scan.poll(&fake, 2);
    scan.poll(&fake, 50002);
    scan.poll(&fake, 50003);
    scan.poll(&fake, 50004);
    try std.testing.expectEqual(Scan(2).Phase.done, scan.phase);
    try std.testing.expectEqual(@as(u32, 0), scan.changed);
    try std.testing.expectEqual(@as(u32, 1), scan.sha_match);
}

test "negative control modifies exactly one chunk between scans" {
    var scan: Scan(2) = .{ .inject = true };
    var fake: Fake = .{};
    try std.testing.expect(scan.start());
    scan.poll(&fake, 1);
    scan.poll(&fake, 2);
    scan.poll(&fake, 50002);
    scan.poll(&fake, 50003);
    scan.poll(&fake, 50004);
    try std.testing.expectEqual(Scan(2).Phase.done, scan.phase);
    try std.testing.expect(scan.injected);
    try std.testing.expectEqual(@as(u32, 1), scan.changed);
    try std.testing.expectEqual(@as(u32, 0), scan.sha_match);
}

test "zero diagnostic erases each chunk and scans for changes" {
    var scan: Scan(2) = .{ .zero_before = true };
    var fake: Fake = .{};
    try std.testing.expect(scan.start());
    scan.poll(&fake, 1);
    scan.poll(&fake, 2);
    try std.testing.expectEqual(@as(u32, 2), scan.zeroed);
    scan.poll(&fake, 3);
    scan.poll(&fake, 4);
    scan.poll(&fake, 50004);
    scan.poll(&fake, 50005);
    scan.poll(&fake, 50006);
    try std.testing.expectEqual(Scan(2).Phase.done, scan.phase);
    try std.testing.expectEqual(@as(u32, 0), scan.nonzero);
    try std.testing.expectEqual(@as(u32, 1), scan.sha_match);
}
test "zero diagnostic detects nonzero data even when scans agree" {
    var scan: Scan(2) = .{ .zero_before = true };
    var fake: Fake = .{};
    try std.testing.expect(scan.start());
    scan.poll(&fake, 1);
    scan.poll(&fake, 2);
    fake.values[0][0] = 1;
    scan.poll(&fake, 3);
    scan.poll(&fake, 4);
    scan.poll(&fake, 50004);
    scan.poll(&fake, 50005);
    scan.poll(&fake, 50006);
    try std.testing.expectEqual(Scan(2).Phase.done, scan.phase);
    try std.testing.expectEqual(@as(u32, 2), scan.nonzero);
    try std.testing.expectEqual(@as(u32, 1), scan.sha_match);
}

test "batch limits count and time while preserving stop and failure" {
    const B = struct {
        data: [8]u8 = @splat(1),
        now: u64 = 0,
        cost: u64 = 0,
        calls: u32 = 0,
        fail_clock: bool = false,
        fn counter(self: *@This()) ?u64 {
            if (self.fail_clock) return null;
            self.now += 1;
            return self.now;
        }
        fn chunk(self: *@This(), i: usize) ?[]const u8 {
            self.calls += 1;
            self.now += self.cost;
            return self.data[i..][0..1];
        }
        fn zero(_: *@This(), _: usize) bool {
            return true;
        }
        fn flip(_: *@This(), _: usize) bool {
            return true;
        }
    };
    var scan: Scan(8) = .{};
    var b: B = .{};
    var t: Timing = .{};
    try std.testing.expect(scan.start());
    scan.pollBatch(&b, &t);
    try std.testing.expectEqual(@as(u32, 4), b.calls);
    scan.pollBatch(&b, &t);
    try std.testing.expectEqual(Scan(8).Phase.gap, scan.phase);
    try std.testing.expectEqual(b.now + 50_000, scan.deadline);
    try std.testing.expectEqual(@as(u32, 8), t.steps);
    scan = .{};
    b = .{ .cost = 700 };
    t = .{};
    try std.testing.expect(scan.start());
    scan.pollBatch(&b, &t);
    try std.testing.expectEqual(@as(u32, 2), b.calls); // budget checked after each indivisible chunk
    try std.testing.expect(t.max_batch_us >= 1000);
    scan = .{};
    b = .{ .fail_clock = true };
    t = .{};
    try std.testing.expect(scan.start());
    scan.pollBatch(&b, &t);
    try std.testing.expectEqual(Scan(8).Phase.failed, scan.phase);
    try std.testing.expect(!t.valid);
}
