//! Host fault model, not an SD/NOR driver. Only completed sync guarantees
//! persistence. Unfenced writes may reach stable media before that barrier.
const std = @import("std");
pub const sector_bytes = 512;
pub const Background = enum { none, alternating, all };
pub const Order = enum { ascending, descending };
pub const Cut = struct { event: usize, prefix: usize };

pub fn Media(comptime byte_count: usize) type {
    if (byte_count == 0 or byte_count % sector_bytes != 0) @compileError("whole sectors required");
    return struct {
        const Self = @This();
        pub const capacity = byte_count;
        cache: [byte_count]u8 = @splat(0xff),
        stable: [byte_count]u8 = @splat(0xff),
        dirty: [byte_count / sector_bytes]bool = @splat(false),
        background: Background = .none,
        order: Order = .ascending,
        cut: ?Cut = null,
        events: usize = 0,
        tripped: bool = false,
        programmed_bytes: usize = 0,
        syncs: usize = 0,
        read_error: bool = false,
        // Negative control: a lying sync implementation that omits locating
        // metadata. The real model protocol must detect its durability failure.
        omit_root_sync: bool = false,

        pub fn read(self: *Self, offset: usize, destination: []u8) error{Io}!void {
            if (self.read_error or offset > capacity or destination.len > capacity - offset) return error.Io;
            @memcpy(destination, self.cache[offset..][0..destination.len]);
        }

        fn event(self: *Self, offset: usize, data: []const u8, persist: bool) error{Io}!void {
            const current = self.events;
            self.events += 1;
            if (self.cut) |cut| if (cut.event == current) {
                const n = if (persist) @min(cut.prefix, data.len) else 0;
                @memcpy(self.stable[offset..][0..n], data[0..n]);
                self.programmed_bytes += n;
                self.tripped = true;
                return error.Io;
            };
            if (persist) {
                @memcpy(self.stable[offset..][0..data.len], data);
                self.programmed_bytes += data.len;
            }
        }

        pub fn write(self: *Self, offset: usize, data: []const u8) error{Io}!void {
            if (self.tripped or offset % sector_bytes != 0 or data.len % sector_bytes != 0 or
                offset > capacity or data.len > capacity - offset) return error.Io;
            var position: usize = 0;
            while (position < data.len) : (position += sector_bytes) {
                const start = offset + position;
                const sector = start / sector_bytes;
                @memcpy(self.cache[start..][0..sector_bytes], data[position..][0..sector_bytes]);
                self.dirty[sector] = true;
                const persist = switch (self.background) {
                    .none => false,
                    .alternating => sector % 2 == 0,
                    .all => true,
                };
                try self.event(start, self.cache[start..][0..sector_bytes], persist);
            }
        }

        pub fn sync(self: *Self) error{Io}!void {
            if (self.tripped) return error.Io;
            try self.event(0, &.{}, false);
            for (0..self.dirty.len) |i| {
                const sector = if (self.order == .ascending) i else self.dirty.len - 1 - i;
                if (!self.dirty[sector]) continue;
                if (self.omit_root_sync and sector < 8192 / sector_bytes) continue;
                const start = sector * sector_bytes;
                try self.event(start, self.cache[start..][0..sector_bytes], true);
                self.dirty[sector] = false;
            }
            self.syncs += 1;
        }

        pub fn powerLoss(self: *Self) void {
            self.cache = self.stable;
            self.dirty = @splat(false);
            self.cut = null;
            self.tripped = false;
            self.events = 0;
        }
    };
}

test "unfenced writeback, torn sectors and failed barriers preserve only stable bytes" {
    var media = Media(8192){};
    const data: [512]u8 = @splat(0x39);
    try media.write(0, &data);
    media.powerLoss();
    try std.testing.expectEqual(@as(u8, 0xff), media.cache[0]);
    media.cut = .{ .event = 2, .prefix = 17 };
    try media.write(0, &data);
    try std.testing.expectError(error.Io, media.sync());
    try std.testing.expectError(error.Io, media.write(512, &data));
    media.powerLoss();
    try std.testing.expectEqualSlices(u8, data[0..17], media.cache[0..17]);
    try std.testing.expectEqual(@as(u8, 0xff), media.cache[17]);
    media.background = .all;
    try media.write(512, &data);
    media.powerLoss();
    try std.testing.expectEqualSlices(u8, &data, media.cache[512..1024]);
}
