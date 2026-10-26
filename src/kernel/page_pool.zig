//! Serialized page leases with metadata outside payload memory. The caller
//! owns synchronization, zeroing and the lifetime of every registered region.
const std = @import("std");
pub const Region = struct { memory: []u8 };
pub const Lease = struct { bytes: []u8, owner: u32, slot: u32, ticket: u64, charged: u32 };
pub const Error = error{ InvalidRequest, OutOfMemory, Full, InvalidLease, WrongOwner, SerialExhausted };
pub fn Pool(comptime page_bytes: usize, comptime max_pages: usize, comptime max_leases: usize) type {
    if (page_bytes < 64 or page_bytes & (page_bytes - 1) != 0 or max_pages == 0 or max_leases == 0 or
        page_bytes > std.math.maxInt(u32) or max_pages > std.math.maxInt(u32) / page_bytes)
        @compileError("invalid page pool geometry");
    return struct {
        const Self = @This();
        const Entry = struct { owner: u32, first: u32, pages: u32, length: u32, ticket: u64 };
        regions: [2]?[]u8 = .{ null, null },
        occupied: [(max_pages + 31) / 32]u32 = @splat(0),
        entries: [max_leases]?Entry = @splat(null),
        pages: u32 = 0,
        free_pages: u32 = 0,
        serial: u64 = 0,

        pub fn init(regions: []const Region) ?Self {
            if (regions.len == 0 or regions.len > 2) return null;
            var result = Self{};
            for (regions, 0..) |region, index| {
                const memory = region.memory;
                if (@intFromPtr(memory.ptr) % page_bytes != 0 or memory.len == 0 or memory.len % page_bytes != 0 or
                    @addWithOverflow(@intFromPtr(memory.ptr), memory.len)[1] != 0 or memory.len / page_bytes > max_pages - result.pages) return null;
                for (regions[0..index]) |previous| {
                    if (@intFromPtr(memory.ptr) < @intFromPtr(previous.memory.ptr) + previous.memory.len and
                        @intFromPtr(previous.memory.ptr) < @intFromPtr(memory.ptr) + memory.len) return null;
                }
                result.regions[index] = memory;
                result.pages += @intCast(memory.len / page_bytes);
            }
            result.free_pages = result.pages;
            return result;
        }
        fn used(self: *const Self, page: usize) bool {
            return self.occupied[page / 32] & (@as(u32, 1) << @intCast(page % 32)) != 0;
        }
        fn mark(self: *Self, first: u32, count: u32, busy: bool) void {
            for (first..first + count) |page| {
                const bit = @as(u32, 1) << @intCast(page % 32);
                if (busy) self.occupied[page / 32] |= bit else self.occupied[page / 32] &= ~bit;
            }
        }
        fn address(self: *const Self, first: u32) usize {
            var base: u32 = 0;
            for (self.regions) |maybe| {
                const memory = maybe orelse break;
                const count: u32 = @intCast(memory.len / page_bytes);
                if (first < base + count) return @intFromPtr(memory.ptr) + (first - base) * page_bytes;
                base += count;
            }
            unreachable;
        }
        pub noinline fn alloc(self: *Self, owner: u32, length: usize, alignment: usize) Error!Lease {
            if (owner == 0 or length == 0 or length > std.math.maxInt(u32) or alignment == 0 or
                alignment > page_bytes or alignment & (alignment - 1) != 0 or length > max_pages * page_bytes) return error.InvalidRequest;
            if (self.serial == std.math.maxInt(u64)) return error.SerialExhausted;
            const needed: u32 = @intCast((length + page_bytes - 1) / page_bytes);
            if (needed > self.free_pages) return error.OutOfMemory;
            const slot = for (self.entries, 0..) |entry, index| {
                if (entry == null) break index;
            } else return error.Full;
            var base: u32 = 0;
            for (self.regions) |maybe| {
                const memory = maybe orelse break;
                const count: u32 = @intCast(memory.len / page_bytes);
                var consecutive: u32 = 0;
                for (base..base + count) |page| {
                    consecutive = if (self.used(page)) 0 else consecutive + 1;
                    if (consecutive != needed) continue;
                    const first: u32 = @intCast(page + 1 - needed);
                    self.serial += 1;
                    self.entries[slot] = .{ .owner = owner, .first = first, .pages = needed, .length = @intCast(length), .ticket = self.serial };
                    self.mark(first, needed, true);
                    self.free_pages -= needed;
                    const bytes: [*]u8 = @ptrFromInt(self.address(first));
                    return .{ .bytes = bytes[0..length], .owner = owner, .slot = @intCast(slot), .ticket = self.serial, .charged = @intCast(needed * page_bytes) };
                }
                base += count;
            }
            return error.OutOfMemory; // Free pages can straddle separate regions.
        }
        pub noinline fn free(self: *Self, owner: u32, lease: Lease) Error!void {
            if (owner == 0 or owner != lease.owner) return error.WrongOwner;
            if (lease.slot >= max_leases) return error.InvalidLease;
            const entry = self.entries[lease.slot] orelse return error.InvalidLease;
            if (entry.owner != owner) return error.WrongOwner;
            if (entry.ticket != lease.ticket or entry.length != lease.bytes.len or
                lease.charged != entry.pages * page_bytes or @intFromPtr(lease.bytes.ptr) != self.address(entry.first)) return error.InvalidLease;
            self.mark(entry.first, entry.pages, false);
            self.free_pages += entry.pages;
            self.entries[lease.slot] = null;
        }
        pub fn capacity(self: *const Self) u32 {
            return @intCast(self.pages * page_bytes);
        }
        pub fn remaining(self: *const Self) u32 {
            return @intCast(self.free_pages * page_bytes);
        }
        pub fn largestFree(self: *const Self) u32 {
            var base: u32 = 0;
            var largest: u32 = 0;
            for (self.regions) |maybe| {
                const memory = maybe orelse break;
                const count: u32 = @intCast(memory.len / page_bytes);
                var run: u32 = 0;
                for (base..base + count) |page| {
                    run = if (self.used(page)) 0 else run + 1;
                    largest = @max(largest, run);
                }
                base += count;
            }
            return @intCast(largest * page_bytes);
        }
    };
}

test "page leases reuse memory without reviving stale or foreign leases" {
    var memory: [8 * 4096]u8 align(4096) = undefined;
    var pool = Pool(4096, 8, 4).init(&.{.{ .memory = &memory }}).?;
    const first = try pool.alloc(1, 4096, 64);
    const second = try pool.alloc(2, 4097, 4096);
    try std.testing.expectEqual(@as(u32, 4096), first.charged);
    try std.testing.expectEqual(@as(u32, 8192), second.charged);
    try std.testing.expectError(error.WrongOwner, pool.free(2, first));
    var changed = first;
    changed.bytes = changed.bytes[1..];
    try std.testing.expectError(error.InvalidLease, pool.free(1, changed));
    try pool.free(1, first);
    const replacement = try pool.alloc(1, 4096, 64);
    try std.testing.expectEqual(first.bytes.ptr, replacement.bytes.ptr);
    try std.testing.expect(first.ticket != replacement.ticket);
    try std.testing.expectError(error.InvalidLease, pool.free(1, first));
    try pool.free(1, replacement);
    try pool.free(2, second);
    try std.testing.expectEqual(pool.capacity(), pool.remaining());
}
test "page allocation cannot cross disjoint regions or bypass lease quotas" {
    var memory: [12 * 4096]u8 align(4096) = undefined;
    var pool = Pool(4096, 8, 2).init(&.{ .{ .memory = memory[0 .. 4 * 4096] }, .{ .memory = memory[8 * 4096 ..] } }).?;
    try std.testing.expectError(error.OutOfMemory, pool.alloc(1, 5 * 4096, 64));
    const a = try pool.alloc(1, 1, 1);
    const b = try pool.alloc(2, 1, 1);
    try std.testing.expectError(error.Full, pool.alloc(1, 1, 1));
    try pool.free(1, a);
    try pool.free(2, b);
    try std.testing.expectEqual(@as(u32, 8 * 4096), pool.remaining());
    try std.testing.expect(Pool(4096, 8, 2).init(&.{ .{ .memory = memory[0 .. 4 * 4096] }, .{ .memory = memory[4096 .. 5 * 4096] } }) == null);
    try std.testing.expect(Pool(4096, 8, 2).init(&.{.{ .memory = memory[1..4097] }}) == null);
    try std.testing.expectError(error.InvalidRequest, pool.alloc(0, 1, 1));
    try std.testing.expectError(error.InvalidRequest, pool.alloc(1, 1, 3));
    pool.serial = std.math.maxInt(u64);
    try std.testing.expectError(error.SerialExhausted, pool.alloc(1, 1, 1));
}
test "four and eight MiB payloads are charged exactly with external metadata" {
    // SAFETY: each allocation is initialized before its payload is inspected.
    const memory = try std.testing.allocator.alignedAlloc(u8, .fromByteUnits(4096), 8 * 1024 * 1024);
    defer std.testing.allocator.free(memory);
    var pool = Pool(4096, 2048, 4).init(&.{.{ .memory = memory }}).?;
    for ([_]usize{ 4 * 1024 * 1024, 8 * 1024 * 1024 }) |length| {
        const lease = try pool.alloc(1, length, 64);
        try std.testing.expectEqual(@as(u32, @intCast(length)), lease.charged);
        @memset(lease.bytes, 0x5a);
        try std.testing.expectEqual(@as(u8, 0x5a), lease.bytes[length - 1]);
        try pool.free(1, lease);
        try std.testing.expectEqual(@as(u32, 8 * 1024 * 1024), pool.remaining());
    }
}
