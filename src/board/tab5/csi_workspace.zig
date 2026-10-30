//! One exclusive DMA frame lease with bounded cache and erasure work.
//! Backend must enforce owner identity, DMA-capability, and serialized cache ABI.
const std = @import("std");
pub fn Workspace(comptime Backend: type, comptime length: usize, comptime chunk: usize) type {
    if (length == 0 or chunk == 0 or length % chunk != 0) @compileError("invalid frame geometry");
    return struct {
        const Self = @This();
        pub const frame_length = length;
        pub const Phase = enum { idle, prepare_writeback, prepare_invalidate, ready_dma, dma, finish_invalidate, cpu_owned, erase, erase_writeback, failed, pinned };
        phase: Phase = .idle,
        allocation: ?Backend.Allocation = null,
        offset: usize = 0,
        generation: u64 = 0,
        pub fn begin(self: *Self, b: *Backend) bool {
            if (self.phase != .idle or self.generation == std.math.maxInt(u64)) return false;
            const alloc = b.allocate(length, 64) orelse return false;
            self.generation += 1;
            if (b.bytes(alloc).len < length or @intFromPtr(b.bytes(alloc).ptr) & 63 != 0) {
                // Unknown or undersized backend handle cannot safely be freed.
                self.allocation = alloc;
                self.phase = .pinned;
                return false;
            }
            self.allocation = alloc;
            self.offset = 0;
            self.phase = .prepare_writeback;
            return true;
        }
        /// Owner-local identity, never reused within the lifetime of this
        /// workspace; not an application capability or a hardware fence.
        pub fn leaseIdentity(self: *const Self) ?u64 {
            return if (self.allocation != null and self.generation != 0) self.generation else null;
        }
        fn advance(self: *Self, next: Phase) void {
            self.offset += chunk;
            if (self.offset == length) {
                self.offset = 0;
                self.phase = next;
            }
        }
        pub fn poll(self: *Self, b: *Backend) void {
            switch (self.phase) {
                .prepare_writeback, .prepare_invalidate, .finish_invalidate, .erase, .erase_writeback => {},
                else => return,
            }
            const allocation = self.allocation orelse return;
            const data = b.bytes(allocation)[self.offset..][0..chunk];
            switch (self.phase) {
                .prepare_writeback => if (b.writeback(data)) self.advance(.prepare_invalidate) else {
                    self.phase = .pinned;
                },
                .prepare_invalidate => if (b.invalidate(data)) self.advance(.ready_dma) else {
                    self.phase = .pinned;
                },
                .finish_invalidate => if (b.invalidate(data)) self.advance(.cpu_owned) else {
                    self.phase = .pinned;
                },
                .erase => {
                    @memset(data, 0);
                    self.advance(.erase_writeback);
                },
                .erase_writeback => if (b.writeback(data)) {
                    self.offset += chunk;
                    if (self.offset == length) {
                        if (!b.release(allocation)) {
                            self.phase = .pinned;
                            return;
                        }
                        self.allocation = null;
                        self.offset = 0;
                        self.phase = .idle;
                    }
                } else {
                    self.phase = .pinned;
                },
                else => {},
            }
        }
        pub fn beginDma(self: *Self) bool {
            if (self.phase != .ready_dma) return false;
            self.phase = .dma;
            return true;
        }
        /// Success requires independently established stopped bridge/channel and
        /// drained IRQ. An uncertain stop pins memory permanently for this boot.
        pub fn finishDma(self: *Self, clean: bool) bool {
            if (self.phase != .dma) return false;
            if (!clean) {
                self.phase = .pinned;
                return false;
            }
            self.offset = 0;
            self.phase = .finish_invalidate;
            return true;
        }
        pub fn beginErase(self: *Self) bool {
            if (self.phase != .cpu_owned and self.phase != .ready_dma) return false;
            self.offset = 0;
            self.phase = .erase;
            return true;
        }
        /// Cancel before beginDma only. Even a partly invalidated lease must
        /// be erased and written back before the allocator can reuse it.
        pub fn abortPreparation(self: *Self) bool {
            switch (self.phase) {
                .prepare_writeback, .prepare_invalidate, .ready_dma => {},
                else => return false,
            }
            self.offset = 0;
            self.phase = .erase;
            return true;
        }
        /// Retain an existing lease after uncertain hardware cleanup.
        pub fn pin(self: *Self) void {
            if (self.allocation != null) self.phase = .pinned;
        }
    };
}
const Fake = struct {
    pub const Allocation = u8;
    data: [128]u8 align(64) = @splat(0xaa),
    calls: u32 = 0,
    fail: bool = false,
    fail_release: bool = false,
    freed: bool = false,
    fn allocate(_: *Fake, _: usize, _: usize) ?Allocation {
        return 1;
    }
    fn bytes(self: *Fake, _: Allocation) []u8 {
        return &self.data;
    }
    fn writeback(self: *Fake, _: []u8) bool {
        self.calls += 1;
        return !self.fail;
    }
    fn invalidate(self: *Fake, _: []u8) bool {
        self.calls += 1;
        return !self.fail;
    }
    fn release(self: *Fake, _: Allocation) bool {
        if (self.fail or self.fail_release) return false;
        self.freed = true;
        return true;
    }
};
test "frame remains owned through DMA and cache handoff until erased" {
    const W = Workspace(Fake, 128, 64);
    var w: W = .{};
    var b: Fake = .{};
    try std.testing.expect(w.begin(&b));
    for (0..4) |_| w.poll(&b);
    try std.testing.expectEqual(W.Phase.ready_dma, w.phase);
    try std.testing.expect(w.beginDma());
    try std.testing.expect(!w.beginErase());
    try std.testing.expect(w.finishDma(true));
    for (0..2) |_| w.poll(&b);
    try std.testing.expectEqual(W.Phase.cpu_owned, w.phase);
    try std.testing.expect(w.beginErase());
    for (0..4) |_| w.poll(&b);
    try std.testing.expectEqual(W.Phase.idle, w.phase);
    try std.testing.expect(b.freed);
    for (b.data) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
}
test "failed cache or uncertain DMA stop pins allocation" {
    const W = Workspace(Fake, 128, 64);
    var w: W = .{};
    var b: Fake = .{};
    try std.testing.expect(w.begin(&b));
    b.fail = true;
    w.poll(&b);
    try std.testing.expectEqual(W.Phase.pinned, w.phase);
    try std.testing.expect(!b.freed);
    w = .{};
    b = .{};
    try std.testing.expect(w.begin(&b));
    for (0..4) |_| w.poll(&b);
    try std.testing.expect(w.beginDma());
    try std.testing.expect(!w.finishDma(false));
    try std.testing.expectEqual(W.Phase.pinned, w.phase);
    try std.testing.expect(!b.freed);
}

test "cache or release failure after capture never returns allocation" {
    const W = Workspace(Fake, 128, 64);
    var w: W = .{};
    var b: Fake = .{};
    try std.testing.expect(w.begin(&b));
    for (0..4) |_| w.poll(&b);
    try std.testing.expect(w.beginDma());
    try std.testing.expect(w.finishDma(true));
    b.fail = true;
    w.poll(&b);
    try std.testing.expectEqual(W.Phase.pinned, w.phase);
    try std.testing.expect(!b.freed);
    w = .{};
    b = .{};
    try std.testing.expect(w.begin(&b));
    for (0..4) |_| w.poll(&b);
    try std.testing.expect(w.beginErase());
    for (0..3) |_| w.poll(&b);
    b.fail_release = true;
    w.poll(&b);
    try std.testing.expectEqual(W.Phase.pinned, w.phase);
    try std.testing.expect(!b.freed);
}

test "cancellation during preparation erases the entire lease before release" {
    const W = Workspace(Fake, 128, 64);
    for (0..5) |steps| {
        var w: W = .{};
        var b: Fake = .{};
        try std.testing.expect(w.begin(&b));
        for (0..steps) |_| w.poll(&b);
        try std.testing.expect(w.abortPreparation());
        try std.testing.expect(!b.freed);
        for (0..4) |_| w.poll(&b);
        try std.testing.expectEqual(W.Phase.idle, w.phase);
        try std.testing.expect(b.freed);
        for (b.data) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    }
    var w: W = .{};
    var b: Fake = .{};
    try std.testing.expect(w.begin(&b));
    for (0..4) |_| w.poll(&b);
    try std.testing.expect(w.beginDma());
    try std.testing.expect(!w.abortPreparation());
    try std.testing.expect(!b.freed);
}

test "workspace generations distinguish reused allocation and never wrap" {
    const W = Workspace(Fake, 128, 64);
    var w: W = .{};
    var b: Fake = .{};
    try std.testing.expectEqual(@as(?u64, null), w.leaseIdentity());
    try std.testing.expect(w.begin(&b));
    const first = w.leaseIdentity().?;
    try std.testing.expect(w.abortPreparation());
    for (0..4) |_| w.poll(&b);
    try std.testing.expectEqual(@as(?u64, null), w.leaseIdentity());
    try std.testing.expect(w.begin(&b));
    const second = w.leaseIdentity().?;
    try std.testing.expect(second > first);
    for (0..4) |_| w.poll(&b);
    try std.testing.expect(w.beginDma());
    w.pin();
    try std.testing.expectEqual(@as(?u64, second), w.leaseIdentity());
    try std.testing.expect(!w.begin(&b));
    var exhausted: W = .{ .generation = std.math.maxInt(u64) };
    try std.testing.expect(!exhausted.begin(&b));
    try std.testing.expectEqual(@as(?u64, null), exhausted.leaseIdentity());
}
