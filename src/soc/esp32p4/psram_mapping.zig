//! Exclusive boot-time MSPI2/MMU1 setup and the vendor L2 cache API.
//! Facts: ESP-IDF v5.4.4 P4 mmu_ll.h, psram_ctrlr_ll.h, cache_reg.h.
//! Three reserved windows exercise nonidentity translation; the rest is heap.
const std = @import("std");

pub const virtual_base: u32 = 0x4800_0000;
pub const page_bytes: u32 = 65536;
pub const window_count = 3;
pub const reserved_bytes: u32 = window_count * page_bytes;
pub const line_bytes: u32 = 64;
pub const mspi: u32 = 0x5008_e000;
pub const cache: u32 = 0x3ff1_0000;
pub const Operation = enum(u32) { invalidate = 1, writeback = 4 };
pub const samples = [_]u32{ 0, 4, 60, 64, 65532 - 64, 65532 };
pub const Exercise = struct { cpu_checks: u32 = 0, command_checks: u32 = 0, transactions: u32 = 0 };

pub fn encrypted(efuse_word: u32) bool {
    return @popCount((efuse_word >> 18) & 7) & 1 != 0;
}

pub fn physicalPage(capacity: u32, window: u32) ?u32 {
    if (capacity < 4 * 1024 * 1024 or capacity > 64 * 1024 * 1024 or
        capacity & (capacity - 1) != 0 or window >= capacity / page_bytes) return null;
    return switch (window) {
        0 => 0,
        1 => capacity / 2 / page_bytes,
        2 => capacity / page_bytes - 1,
        // Swap the displaced pages back into the remaining virtual range.
        // Every physical page occurs exactly once, including the heap tail.
        else => if (window == capacity / 2 / page_bytes) 1 else if (window == capacity / page_bytes - 1) 2 else window,
    };
}

pub fn validSyncRange(address: u32, length: u32, capacity: u32) bool {
    return length != 0 and address % line_bytes == 0 and length % line_bytes == 0 and
        physicalPage(capacity, 0) != null and address >= virtual_base and
        length <= capacity and address - virtual_base <= capacity - length;
}

pub fn Mapper(comptime IO: type) type {
    return struct {
        io: IO,
        ready: bool = false,
        faulted: bool = false,
        entries_checked: u32 = 0,
        syncs: u32 = 0,
        bytes: u32 = 0,
        last_address: u32 = 0,
        last_actual: u32 = 0,
        last_expected: u32 = 0,

        const Self = @This();
        pub const Error = error{ InvalidCapacity, CacheMode, Readback, CacheOperation, Faulted, InvalidRange, NotReady, DataMismatch, CommandError, AlreadyMapped };

        noinline fn check(self: *Self, address: u32, expected: u32, mask: u32) Error!void {
            const actual = self.io.read(address) & mask;
            if (actual != expected) {
                self.last_address = address;
                self.last_actual = actual;
                self.last_expected = expected;
                return error.Readback;
            }
        }

        fn close(self: *Self) void {
            self.io.write(mspi + 0x3c, (self.io.read(mspi + 0x3c) & ~@as(u32, 1)) | (1 << 31));
            self.ready = false;
        }

        pub fn abort(self: *Self) void {
            self.close();
            self.bytes = 0;
            for (0..1024) |index| {
                self.io.write(mspi + 0x380, @intCast(index));
                self.io.write(mspi + 0x37c, 0);
            }
            self.faulted = true;
        }

        /// L2 is retained from the stock loader. Never reconfigure shared
        /// SRAM/cache sizing or Flash MMU0 in this PSRAM-only operation.
        pub fn map(self: *Self, capacity: u32) Error!void {
            if (self.faulted) return error.Faulted;
            if (self.ready) return error.AlreadyMapped;
            if (physicalPage(capacity, 2) == null) return error.InvalidCapacity;
            if (self.io.lineSize() != line_bytes)
                return error.CacheMode;
            self.close();
            errdefer self.abort();
            self.bytes = capacity;
            self.io.enableCache();
            // x8 DDR, fixed read/write latency 2, 32-bit addresses, XTAL/2.
            const sctrl: u32 = 1 | (1 << 3) | (1 << 4) | (1 << 5) | (17 << 6) |
                (31 << 14) | (1 << 20) | (1 << 21) | (7 << 22);
            self.io.write(mspi + 0x40, sctrl);
            const command_mask: u32 = (7 << 10) | (15 << 14) | (63 << 18) | (3 << 26);
            self.io.write(mspi + 0x44, (self.io.read(mspi + 0x44) & ~command_mask) | (63 << 18));
            self.io.write(mspi + 0x48, 15 << 28);
            self.io.write(mspi + 0x4c, (15 << 28) | 0x8080);
            self.io.write(mspi + 0x50, (1 << 16) | 1);
            self.io.write(mspi + 0xd8, (self.io.read(mspi + 0xd8) & ~@as(u32, 31)) | 1);
            self.io.write(mspi + 0x0c, self.io.read(mspi + 0x0c) | (3 << 25));
            try self.check(mspi + 0x40, sctrl, 0xffff_ffff);
            try self.check(mspi + 0x48, 15 << 28, 0xffff_ffff);
            try self.check(mspi + 0x4c, (15 << 28) | 0x8080, 0xffff_ffff);
            try self.check(mspi + 0x50, (1 << 16) | 1, 0xffff_ffff);
            for (0..1024) |index| {
                const entry = if (physicalPage(capacity, @intCast(index))) |page| 0xc00 | page else 0;
                self.io.write(mspi + 0x380, @intCast(index));
                self.io.write(mspi + 0x37c, entry);
                try self.check(mspi + 0x37c, entry, 0xffff_ffff);
                self.entries_checked += 1;
            }
            try self.sync(.invalidate, virtual_base, capacity);
            self.io.write(mspi + 0x3c, (self.io.read(mspi + 0x3c) & ~@as(u32, 1 << 31)) | 1);
            try self.check(mspi + 0x3c, 1, (1 << 31) | 1);
            self.ready = true;
        }

        pub noinline fn sync(self: *Self, operation: Operation, address: u32, length: u32) Error!void {
            if (self.faulted) return error.Faulted;
            if (!validSyncRange(address, length, self.bytes)) return error.InvalidRange;
            if (!self.io.sync(operation, address, length)) {
                self.faulted = true;
                return error.CacheOperation;
            }
            self.syncs += 1;
        }

        fn mismatch(self: *Self, address: u32, actual: u32, expected: u32) Error {
            self.last_address = address;
            self.last_actual = actual;
            self.last_expected = expected;
            return error.DataMismatch;
        }

        /// CPU and command views must agree through a real, nonidentity map.
        /// CPU provides read/write/fence; commands provides physical words.
        pub noinline fn exercise(self: *Self, commands: anytype, cpu: anytype) Error!Exercise {
            if (self.faulted) return error.Faulted;
            if (!self.ready) return error.NotReady;
            errdefer self.abort();
            var report = Exercise{};
            const before = commands.transactions;
            for (0..2) |pass| {
                for (0..window_count) |window| {
                    for (samples) |offset| {
                        const value = 0x76a9_0000 ^ (@as(u32, @intCast(window)) << 16) ^ offset;
                        cpu.write(virtual_base + @as(u32, @intCast(window)) * page_bytes + offset, if (pass == 0) value else ~value);
                    }
                }
                cpu.fence();
                try self.sync(.writeback, virtual_base, reserved_bytes);
                for (0..window_count) |window| {
                    const physical = physicalPage(commands.capacity, @intCast(window)).? * page_bytes;
                    for (samples) |offset| {
                        const value = 0x76a9_0000 ^ (@as(u32, @intCast(window)) << 16) ^ offset;
                        const expected = if (pass == 0) value else ~value;
                        const actual = commands.readWord(physical + offset) catch return error.CommandError;
                        if (actual != expected) return self.mismatch(physical + offset, actual, expected);
                        report.command_checks += 1;
                        commands.writeWord(physical + offset, ~expected) catch return error.CommandError;
                    }
                }
                try self.sync(.invalidate, virtual_base, reserved_bytes);
                cpu.fence();
                for (0..window_count) |window| {
                    for (samples) |offset| {
                        const value = 0x76a9_0000 ^ (@as(u32, @intCast(window)) << 16) ^ offset;
                        const expected = if (pass == 0) ~value else value;
                        const address = virtual_base + @as(u32, @intCast(window)) * page_bytes + offset;
                        const actual = cpu.read(address);
                        if (actual != expected) return self.mismatch(address, actual, expected);
                        report.cpu_checks += 1;
                    }
                }
            }
            report.transactions = commands.transactions - before;
            return report;
        }
    };
}

test "window plan uses distinct first middle and last physical pages" {
    for ([_]u32{ 4, 8, 16, 32, 64 }) |megabytes| {
        const capacity = megabytes * 1024 * 1024;
        try std.testing.expectEqual(@as(u32, 0), physicalPage(capacity, 0).?);
        try std.testing.expectEqual(capacity / 2 / page_bytes, physicalPage(capacity, 1).?);
        try std.testing.expectEqual(capacity / page_bytes - 1, physicalPage(capacity, 2).?);
    }
    try std.testing.expect(physicalPage(0, 0) == null);
    try std.testing.expect(physicalPage(6 * 1024 * 1024, 0) == null);
    try std.testing.expect(physicalPage(32 * 1024 * 1024, 512) == null);
}

test "all supported full capacity maps are bijective and retain displaced pages" {
    for ([_]u32{ 4, 8, 16, 32, 64 }) |megabytes| {
        const capacity = megabytes * 1024 * 1024;
        var seen: [1024]bool = @splat(false);
        for (0..capacity / page_bytes) |index| {
            const physical = physicalPage(capacity, @intCast(index)).?;
            try std.testing.expect(physical < capacity / page_bytes and !seen[physical]);
            seen[physical] = true;
        }
        for (seen[0 .. capacity / page_bytes]) |present| try std.testing.expect(present);
        try std.testing.expectEqual(@as(u32, 1), physicalPage(capacity, capacity / 2 / page_bytes).?);
        try std.testing.expectEqual(@as(u32, 2), physicalPage(capacity, capacity / page_bytes - 1).?);
    }
}

test "cache maintenance rejects zero unaligned overflowing and unrelated ranges" {
    const capacity = 32 * 1024 * 1024;
    try std.testing.expect(validSyncRange(virtual_base, capacity, capacity));
    try std.testing.expect(validSyncRange(virtual_base + capacity - 64, 64, capacity));
    for ([_][2]u32{ .{ virtual_base, 0 }, .{ virtual_base + 1, 64 }, .{ virtual_base, 63 }, .{ 0x40000000, 64 }, .{ virtual_base + capacity, 64 }, .{ 0xffffffc0, 128 } }) |range|
        try std.testing.expect(!validSyncRange(range[0], range[1], capacity));
    try std.testing.expect(!validSyncRange(virtual_base, 64, 0));
}

test "plain command/cache fixture rejects an active encryption counter" {
    for (0..8) |counter| {
        const expected = counter == 1 or counter == 2 or counter == 4 or counter == 7;
        try std.testing.expectEqual(expected, encrypted(@as(u32, @intCast(counter)) << 18));
    }
    try std.testing.expect(!encrypted(0xffe3_ffff));
}
