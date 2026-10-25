//! Bounded single-producer/single-consumer transport for SMP services.
//!
//! One task owns `tryPush` and one task owns `tryPop`. The release/acquire
//! publication points transfer ownership of each slot without a mutex. Wakeup
//! and blocking policy deliberately live outside this data structure.

const std = @import("std");

const cache_line_bytes = 128;

pub fn SpscRing(comptime T: type, comptime capacity: usize) type {
    if (capacity == 0) @compileError("SPSC capacity must be non-zero");
    if (capacity > std.math.maxInt(usize) / 2)
        @compileError("SPSC capacity is too large for wrapping counters");

    return struct {
        const Self = @This();

        write_index: std.atomic.Value(usize) align(cache_line_bytes),
        read_index: std.atomic.Value(usize) align(cache_line_bytes),
        slots: [capacity]T align(cache_line_bytes),

        pub fn init() Self {
            return .{
                .write_index = .init(0),
                .read_index = .init(0),
                // SAFETY: tryPop observes a slot only after the producer has
                // initialized it and published write_index with release.
                .slots = undefined,
            };
        }

        /// Producer-only. Returns false instead of overwriting unread data.
        pub fn tryPush(self: *Self, item: T) bool {
            const write = self.write_index.load(.monotonic);
            const read = self.read_index.load(.acquire);
            if (write -% read == capacity) return false;

            self.slots[write % capacity] = item;
            self.write_index.store(write +% 1, .release);
            return true;
        }

        /// Consumer-only. A returned value is copied out before the slot can
        /// be published back to the producer.
        pub fn tryPop(self: *Self) ?T {
            const read = self.read_index.load(.monotonic);
            const write = self.write_index.load(.acquire);
            if (read == write) return null;

            const item = self.slots[read % capacity];
            self.read_index.store(read +% 1, .release);
            return item;
        }

        /// Diagnostic only: the result can change immediately on the peer.
        pub fn countApprox(self: *const Self) usize {
            while (true) {
                const read_before = self.read_index.load(.acquire);
                const write = self.write_index.load(.acquire);
                const read_after = self.read_index.load(.acquire);
                if (read_before == read_after) return write -% read_after;
            }
        }
    };
}

test "bounded ring fails closed and reuses wrapped slots" {
    var ring = SpscRing(u32, 3).init();
    try std.testing.expect(ring.tryPop() == null);
    try std.testing.expect(ring.tryPush(10));
    try std.testing.expect(ring.tryPush(11));
    try std.testing.expect(ring.tryPush(12));
    try std.testing.expect(!ring.tryPush(13));
    try std.testing.expectEqual(@as(usize, 3), ring.countApprox());
    try std.testing.expectEqual(@as(u32, 10), ring.tryPop().?);
    try std.testing.expect(ring.tryPush(13));
    try std.testing.expectEqual(@as(u32, 11), ring.tryPop().?);
    try std.testing.expectEqual(@as(u32, 12), ring.tryPop().?);
    try std.testing.expectEqual(@as(u32, 13), ring.tryPop().?);
    try std.testing.expect(ring.tryPop() == null);
}

test "wrapping counters preserve occupancy and order" {
    var ring = SpscRing(u8, 3).init();
    const near_wrap = std.math.maxInt(usize) - 1;
    ring.write_index.store(near_wrap, .monotonic);
    ring.read_index.store(near_wrap, .monotonic);

    try std.testing.expect(ring.tryPush(41));
    try std.testing.expect(ring.tryPush(42));
    try std.testing.expectEqual(@as(usize, 2), ring.countApprox());
    try std.testing.expectEqual(@as(u8, 41), ring.tryPop().?);
    try std.testing.expectEqual(@as(u8, 42), ring.tryPop().?);
    try std.testing.expect(ring.tryPop() == null);
}

test "producer and consumer preserve order across host threads" {
    const Ring = SpscRing(u32, 64);
    const item_count: u32 = 100_000;
    var ring = Ring.init();

    const Producer = struct {
        fn run(target: *Ring) void {
            for (0..item_count) |index| {
                const item: u32 = @intCast(index);
                while (!target.tryPush(item)) std.atomic.spinLoopHint();
            }
        }
    };

    const producer = try std.Thread.spawn(.{}, Producer.run, .{&ring});
    for (0..item_count) |expected| {
        const item = while (true) {
            if (ring.tryPop()) |value| break value;
            std.atomic.spinLoopHint();
        };
        try std.testing.expectEqual(@as(u32, @intCast(expected)), item);
    }
    producer.join();
    try std.testing.expect(ring.tryPop() == null);
}
