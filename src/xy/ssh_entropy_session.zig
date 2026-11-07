//! Poll-driven admission of an SSH CSPRNG from an exclusive seed collector.
//! The backend and its physical entropy still require independent qualification.
const std = @import("std");
const entropy_mod = @import("ssh_entropy.zig");
const collector_mod = @import("ssh_seed_collector.zig");
pub const Generations = collector_mod.Generations;

/// Own stable storage for the backend, generation counter and session until
/// cleanup reaches idle. Do not copy or reset a live instance. The backend
/// must implement the collector's bounded acquisition and cleanup contract.
pub fn Session(comptime Backend: type) type {
    return struct {
        const Self = @This();
        const Collector = collector_mod.Collector(Backend);
        pub const State = enum { idle, collecting, restoring, ready, cleaning, failed_cleanup, failed };
        collector: Collector,
        entropy: entropy_mod.Entropy = .{},
        state: State = .idle,

        pub fn init(backend: *Backend, generations: *collector_mod.Generations) Self {
            return .{ .collector = Collector.init(backend, generations) };
        }

        pub fn begin(self: *Self, now: u64, timeout: u64) !void {
            if (self.state != .idle) return error.Busy;
            self.entropy.clear();
            try self.collector.begin(now, timeout);
            self.state = .collecting;
        }

        /// Each call performs at most one collector sample or cleanup step.
        /// Seeded output becomes available only after the source is restored.
        pub fn poll(self: *Self, now: u64) void {
            switch (self.state) {
                .collecting => {
                    self.collector.poll(now);
                    if (self.collector.state == .ready) {
                        self.entropy.seedFrom(&self.collector) catch {
                            self.collector.cancel();
                            self.state = .failed_cleanup;
                            return;
                        };
                        self.collector.cancel();
                        self.state = .restoring;
                    } else if (self.collector.state == .cleaning) {
                        self.entropy.clear();
                        self.state = .failed_cleanup;
                    }
                },
                .restoring, .cleaning, .failed_cleanup => {
                    self.collector.poll(now);
                    if (self.collector.state == .idle) {
                        self.state = switch (self.state) {
                            .restoring => .ready,
                            .cleaning => .idle,
                            .failed_cleanup => .failed,
                            else => unreachable,
                        };
                    }
                },
                .idle, .ready, .failed => {},
            }
        }

        pub fn available(self: *const Self) bool {
            return self.state == .ready and self.entropy.available();
        }

        pub fn fill(self: *Self, out: []u8) !void {
            if (!self.available()) {
                std.crypto.secureZero(u8, out);
                return error.EntropyUnavailable;
            }
            self.entropy.fill(out) catch |err| {
                self.state = .failed;
                return err;
            };
        }

        /// Erase output state immediately; keep polling until cleanup ends.
        pub fn cancel(self: *Self) void {
            self.entropy.clear();
            if (self.state == .idle) return;
            self.collector.cancel();
            self.state = .cleaning;
        }
    };
}

const Fake = struct {
    held: bool = false,
    release_ready: bool = true,
    fail: bool = false,
    byte: u8 = 1,
    pub fn begin(self: *@This()) !void {
        if (self.held) return error.Busy;
        self.held = true;
    }
    pub fn owned(self: *@This()) bool {
        return self.held;
    }
    pub fn sample(self: *@This()) !?u8 {
        if (self.fail) return error.SampleFailed;
        defer self.byte +%= 1;
        return self.byte;
    }
    pub fn release(self: *@This()) bool {
        if (!self.release_ready) return false;
        self.held = false;
        return true;
    }
};

test "source cleanup precedes CSPRNG availability" {
    var backend: Fake = .{ .release_ready = false };
    var generations: collector_mod.Generations = .{};
    var session = Session(Fake).init(&backend, &generations);
    try session.begin(0, 100);
    for (0..entropy_mod.seed_bytes) |_| session.poll(1);
    try std.testing.expectEqual(.restoring, session.state);
    var output: [32]u8 = @splat(0xaa);
    try std.testing.expectError(error.EntropyUnavailable, session.fill(&output));
    try std.testing.expect(std.mem.allEqual(u8, &output, 0));
    session.poll(2);
    try std.testing.expect(!session.available() and backend.held);
    try std.testing.expectError(error.Busy, session.begin(2, 100));
    backend.release_ready = true;
    session.poll(3);
    try std.testing.expect(session.available() and !backend.held);
    try session.fill(&output);
    try std.testing.expect(!std.mem.allEqual(u8, &output, 0));
    session.cancel();
    try std.testing.expect(!session.available());
    session.poll(4);
    try std.testing.expectEqual(.idle, session.state);
    try session.begin(5, 100);
    try std.testing.expectEqual(@as(u64, 2), generations.last);
}

test "timeout and cancellation wipe secrets while cleanup remains held" {
    var backend: Fake = .{ .release_ready = false };
    var generations: collector_mod.Generations = .{};
    var session = Session(Fake).init(&backend, &generations);
    try session.begin(10, 3);
    session.poll(11);
    session.poll(13);
    try std.testing.expectEqual(.failed_cleanup, session.state);
    try std.testing.expect(std.mem.allEqual(u8, &session.collector.seed, 0));
    session.poll(14);
    try std.testing.expect(backend.held and !session.available());
    try std.testing.expectError(error.Busy, session.begin(14, 10));
    backend.release_ready = true;
    session.poll(15);
    try std.testing.expectEqual(.failed, session.state);
    session.cancel();
    session.poll(16);
    try session.begin(17, 20);
    session.poll(18);
    session.cancel();
    try std.testing.expect(std.mem.allEqual(u8, &session.collector.seed, 0));
    session.poll(19);
    try std.testing.expectEqual(.idle, session.state);
}

test "sample error cannot expose output and cleanup is retried" {
    var backend: Fake = .{ .fail = true, .release_ready = false };
    var generations: collector_mod.Generations = .{};
    var session = Session(Fake).init(&backend, &generations);
    try session.begin(0, 10);
    session.poll(1);
    try std.testing.expectEqual(.failed_cleanup, session.state);
    session.poll(2);
    try std.testing.expect(backend.held and !session.available());
    backend.release_ready = true;
    session.poll(3);
    try std.testing.expectEqual(.failed, session.state);
    try std.testing.expect(!backend.held);
}
