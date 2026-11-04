const std = @import("std");
const adapter = @import("hosted_dma_bus.zig");
const Short = struct {
    prepared: usize = 0,
    finished: usize = 0,
    fail_finish: bool = false,
    pub fn prepareDma(self: *@This(), _: bool, _: []const u8, length: usize) ?u32 {
        self.prepared = length;
        return 0x4ff00000;
    }
    pub fn finishDma(self: *@This(), _: bool, destination: []u8) bool {
        self.finished += 1;
        @memset(destination, 0x42);
        return !self.fail_finish;
    }
};
const Cache = struct {
    pub fn address(_: *@This(), _: anytype) ?u32 {
        return 0x4ff10000;
    }
    pub fn writeback(_: *@This(), _: usize, _: usize) bool {
        return true;
    }
    pub fn invalidate(_: *@This(), _: usize, _: usize) bool {
        return true;
    }
    pub fn fence(_: *@This()) void {}
};

test "short register reads and long writes use separate descriptors in order" {
    var buffer: adapter.Buffer = .{};
    var bus: adapter.Bus(Short, Cache) = .{ .short = .{}, .buffer = &buffer, .cache = .{} };
    var credit: [4]u8 = @splat(0);
    try std.testing.expectEqual(@as(?u32, 0x4ff00000), bus.prepareDma(false, &.{}, 4));
    try std.testing.expect(bus.finishDma(false, &credit));
    try std.testing.expect(std.mem.allEqual(u8, &credit, 0x42));
    const bytes: [1536]u8 = @splat(0x5a);
    try std.testing.expectEqual(@as(?u32, 0x4ff10000), bus.prepareDma(true, &bytes, bytes.len));
    try std.testing.expectEqual(@as(usize, 4), bus.short.prepared);
    try std.testing.expectEqual(@as(?u32, null), bus.prepareDma(false, &.{}, 4));
    buffer.descriptor[0] &= ~(@as(u32, 1) << 31);
    try std.testing.expect(bus.finishDma(true, &.{}));
    try std.testing.expectEqual(adapter.Active.none, bus.active);
    try std.testing.expectEqual(@as(usize, 1), bus.short.finished);
    try std.testing.expectEqualSlices(u8, &bytes, &buffer.data);
    try std.testing.expectEqual(@as(?u32, 0x4ff00000), bus.prepareDma(false, &.{}, 4));
}

test "short failure or retained long descriptor quarantines both routes" {
    for ([_]bool{ false, true }) |long| {
        var buffer: adapter.Buffer = .{};
        var bus: adapter.Bus(Short, Cache) = .{ .short = .{ .fail_finish = true }, .buffer = &buffer, .cache = .{} };
        const bytes: [1024]u8 = @splat(1);
        try std.testing.expect(bus.prepareDma(true, if (long) &bytes else bytes[0..4], if (long) 1024 else 4) != null);
        try std.testing.expect(!bus.finishDma(true, &.{}));
        try std.testing.expectEqual(adapter.Active.retired, bus.active);
        try std.testing.expectEqual(@as(?u32, null), bus.prepareDma(false, &.{}, 4));
        try std.testing.expectEqual(@as(?u32, null), bus.prepareDma(true, &bytes, 1024));
    }
}

test "unsupported long reads and partial source leave DMA untouched" {
    var buffer: adapter.Buffer = .{};
    var bus: adapter.Bus(Short, Cache) = .{ .short = .{}, .buffer = &buffer, .cache = .{} };
    try std.testing.expectEqual(@as(?u32, null), bus.prepareDma(false, &.{}, 1024));
    try std.testing.expectEqual(@as(?u32, null), bus.prepareDma(true, "abc", 1024));
    try std.testing.expectEqual(@as(?u32, null), bus.prepareDma(true, "abc", 4));
    try std.testing.expectEqual(@as(?u32, null), bus.prepareDma(true, "abc", 3));
    try std.testing.expectEqual(@as(?u32, null), bus.prepareDma(false, "abcd", 4));
    try std.testing.expectEqual(adapter.Active.none, bus.active);
    try std.testing.expectEqual(@as(usize, 0), bus.short.prepared);
}

const SharedShort = struct {
    pub const shared_host = true;
    const Lease = struct { serial: u32 = 1, generation: u32 = 1, slot: u32 = 1 };
    lease: Lease = .{},
    owned: bool = true,
    prepared: usize = 0,
    finished: usize = 0,

    pub fn ownsSlot(self: *@This(), slot: u32) bool {
        return self.owned and slot == 1 and self.lease.slot == slot;
    }
    pub fn prepareDma(self: *@This(), _: bool, _: []const u8, length: usize) ?u32 {
        self.prepared += 1;
        _ = length;
        return 0x4ff00000;
    }
    pub fn finishDma(self: *@This(), _: bool, _: []u8) bool {
        self.finished += 1;
        return true;
    }
};
const SharedCache = struct {
    short: *SharedShort,
    writes: usize = 0,
    invalidates: usize = 0,
    replace_lease_on_write: bool = false,
    replace_lease_on_invalidate: bool = false,
    pub fn address(_: *@This(), _: anytype) ?u32 {
        return 0x4ff10000;
    }
    pub fn writeback(self: *@This(), _: usize, _: usize) bool {
        self.writes += 1;
        if (self.replace_lease_on_write) self.short.lease.serial += 1;
        return true;
    }
    pub fn invalidate(self: *@This(), _: usize, _: usize) bool {
        self.invalidates += 1;
        if (self.replace_lease_on_invalidate) self.short.lease.generation += 1;
        return true;
    }
    pub fn fence(_: *@This()) void {}
};

test "shared DMA rejects unowned preparation without touching storage" {
    var buffer: adapter.Buffer = .{};
    var bus: adapter.Bus(SharedShort, SharedCache) = undefined;
    bus = .{ .short = .{ .owned = false }, .buffer = &buffer, .cache = .{ .short = &bus.short } };
    const bytes: [1536]u8 = @splat(0x5a);
    try std.testing.expectEqual(@as(?u32, null), bus.prepareDma(true, &bytes, bytes.len));
    try std.testing.expectEqual(@as(usize, 0), bus.cache.writes);
    try std.testing.expectEqual(@as(usize, 0), bus.short.prepared);
    try std.testing.expectEqual(adapter.Active.none, bus.active);
    try std.testing.expectEqual(@import("hosted_long_dma.zig").State.idle, buffer.state);
}

test "newly acquired lease cannot complete an old DMA transfer" {
    var buffer: adapter.Buffer = .{};
    var bus: adapter.Bus(SharedShort, SharedCache) = undefined;
    bus = .{ .short = .{}, .buffer = &buffer, .cache = .{ .short = &bus.short } };
    const bytes: [1536]u8 = @splat(0x5a);
    try std.testing.expect(bus.prepareDma(true, &bytes, bytes.len) != null);
    buffer.descriptor[0] &= ~(@as(u32, 1) << 31);
    bus.short.lease.serial += 1;
    try std.testing.expect(!bus.finishDma(true, &.{}));
    try std.testing.expectEqual(@as(usize, 0), bus.cache.invalidates);
    try std.testing.expectEqual(adapter.Active.retired, bus.active);
    try std.testing.expectEqual(@import("hosted_long_dma.zig").State.retired, buffer.state);
    try std.testing.expectEqual(@as(?u32, null), bus.prepareDma(true, &bytes, bytes.len));
}

test "lost shared ownership quarantines short and long DMA" {
    for ([_]bool{ false, true }) |long| {
        var buffer: adapter.Buffer = .{};
        var bus: adapter.Bus(SharedShort, SharedCache) = undefined;
        bus = .{ .short = .{}, .buffer = &buffer, .cache = .{ .short = &bus.short } };
        const bytes: [1024]u8 = @splat(7);
        try std.testing.expect(bus.prepareDma(true, if (long) &bytes else bytes[0..4], if (long) 1024 else 4) != null);
        bus.short.owned = false;
        try std.testing.expect(!bus.finishDma(true, &.{}));
        try std.testing.expectEqual(@as(usize, 0), bus.short.finished);
        try std.testing.expectEqual(@as(usize, 0), bus.cache.invalidates);
        try std.testing.expectEqual(adapter.Active.retired, bus.active);
        bus.short.owned = true;
        try std.testing.expectEqual(@as(?u32, null), bus.prepareDma(true, &bytes, 1024));
    }
}

test "lease replacement during preparation does not expose descriptor" {
    var buffer: adapter.Buffer = .{};
    var bus: adapter.Bus(SharedShort, SharedCache) = undefined;
    bus = .{ .short = .{}, .buffer = &buffer, .cache = .{ .short = &bus.short, .replace_lease_on_write = true } };
    const bytes: [1024]u8 = @splat(3);
    try std.testing.expectEqual(@as(?u32, null), bus.prepareDma(true, &bytes, bytes.len));
    try std.testing.expectEqual(adapter.Active.retired, bus.active);
    try std.testing.expectEqual(@import("hosted_long_dma.zig").State.retired, buffer.state);
    try std.testing.expectEqual(@as(usize, 0), bus.cache.invalidates);
}

test "explicit retirement keeps storage quarantined until external recovery" {
    var buffer: adapter.Buffer = .{};
    var bus: adapter.Bus(SharedShort, SharedCache) = undefined;
    bus = .{ .short = .{}, .buffer = &buffer, .cache = .{ .short = &bus.short } };
    const bytes: [1024]u8 = @splat(9);
    try std.testing.expect(bus.prepareDma(true, &bytes, bytes.len) != null);
    bus.retire();
    try std.testing.expect(!bus.finishDma(true, &.{}));
    try std.testing.expectEqual(@as(usize, 0), bus.cache.invalidates);
    try std.testing.expectEqual(adapter.Active.retired, bus.active);
}

test "loss detected by another prepare permanently retires the old transfer" {
    var buffer: adapter.Buffer = .{};
    var bus: adapter.Bus(SharedShort, SharedCache) = undefined;
    bus = .{ .short = .{}, .buffer = &buffer, .cache = .{ .short = &bus.short } };
    const bytes: [1024]u8 = @splat(5);
    try std.testing.expect(bus.prepareDma(true, &bytes, bytes.len) != null);
    bus.short.lease.generation += 1;
    try std.testing.expectEqual(@as(?u32, null), bus.prepareDma(true, &bytes, bytes.len));
    try std.testing.expectEqual(adapter.Active.retired, bus.active);
    try std.testing.expectEqual(@import("hosted_long_dma.zig").State.retired, buffer.state);
}

test "lease loss during completion quarantines a cleared descriptor" {
    var buffer: adapter.Buffer = .{};
    var bus: adapter.Bus(SharedShort, SharedCache) = undefined;
    bus = .{ .short = .{}, .buffer = &buffer, .cache = .{ .short = &bus.short, .replace_lease_on_invalidate = true } };
    const bytes: [1024]u8 = @splat(5);
    try std.testing.expect(bus.prepareDma(true, &bytes, bytes.len) != null);
    buffer.descriptor[0] &= ~(@as(u32, 1) << 31);
    try std.testing.expect(!bus.finishDma(true, &.{}));
    try std.testing.expectEqual(@as(usize, 1), bus.cache.invalidates);
    try std.testing.expectEqual(adapter.Active.retired, bus.active);
    try std.testing.expectEqual(@import("hosted_long_dma.zig").State.retired, buffer.state);
}

test "shared lease identity is checked when the short bus is a pointer" {
    var buffer: adapter.Buffer = .{};
    var short: SharedShort = .{};
    var bus: adapter.Bus(*SharedShort, SharedCache) = .{ .short = &short, .buffer = &buffer, .cache = .{ .short = &short } };
    const bytes: [1024]u8 = @splat(6);
    try std.testing.expect(bus.prepareDma(true, &bytes, bytes.len) != null);
    short.lease.serial += 1;
    try std.testing.expect(!bus.finishDma(true, &.{}));
    try std.testing.expectEqual(adapter.Active.retired, bus.active);
    try std.testing.expectEqual(@as(usize, 0), bus.cache.invalidates);
}

test "shared owner can complete and then use a new lease after idle" {
    var buffer: adapter.Buffer = .{};
    var bus: adapter.Bus(SharedShort, SharedCache) = undefined;
    bus = .{ .short = .{}, .buffer = &buffer, .cache = .{ .short = &bus.short } };
    const bytes: [1536]u8 = @splat(0x5a);
    try std.testing.expect(bus.prepareDma(true, &bytes, bytes.len) != null);
    buffer.descriptor[0] &= ~(@as(u32, 1) << 31);
    try std.testing.expect(bus.finishDma(true, &.{}));
    try std.testing.expectEqual(adapter.Active.none, bus.active);
    try std.testing.expectEqual(@as(usize, 1), bus.cache.invalidates);
    bus.short.lease.serial += 1;
    try std.testing.expect(bus.prepareDma(true, bytes[0..4], 4) != null);
    try std.testing.expect(bus.finishDma(true, &.{}));
    try std.testing.expectEqual(@as(usize, 1), bus.short.finished);
}
