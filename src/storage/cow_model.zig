//! Bounded host model of immutable payloads and alternating committed roots.
//! This is not the future log format, a VFS, or an SD/NOR implementation.
const std = @import("std");
pub const page_bytes = 4096;
pub const magic: u32 = 0x4e49534d;
pub const version: u32 = 1;
pub const checksum_offset = page_bytes - 4;
pub const entries_offset = 24;
pub const entry_bytes = 16;
pub const Error = error{ Io, Corrupt, Unformatted, Faulted, Busy, NoTransaction, NoSpace, TooManyObjects, NotFound, InvalidArgument, GenerationExhausted };

pub const Entry = struct { id: u32 = 0, first: u32 = 0, length: u32 = 0, checksum: u32 = 0 };

pub fn Store(comptime Device: type, comptime object_limit: usize) type {
    if (object_limit == 0 or entries_offset + object_limit * entry_bytes > checksum_offset)
        @compileError("bounded root map required");
    if (Device.capacity % page_bytes != 0 or Device.capacity < 3 * page_bytes or Device.capacity > std.math.maxInt(u32))
        @compileError("invalid model media capacity");
    return struct {
        const Self = @This();
        const Root = struct {
            generation: u64 = 0,
            tail: u32 = 2,
            count: u32 = 0,
            entries: [object_limit]Entry = @splat(.{}),
        };
        device: *Device,
        current: Root = .{},
        staged: Root = .{},
        in_transaction: bool = false,
        faulted: bool = false,

        pub fn format(device: *Device) Error!Self {
            var bytes: [2 * page_bytes]u8 = undefined;
            try device.read(0, &bytes);
            for (bytes) |byte| if (byte != 0xff) return error.Corrupt;
            var self = Self{ .device = device };
            self.current.generation = 1;
            try self.publish(self.current);
            return self;
        }

        pub fn recover(device: *Device) Error!Self {
            var self = Self{ .device = device };
            var blank = true;
            for (0..2) |slot| {
                var bytes: [page_bytes]u8 = undefined;
                try device.read(slot * page_bytes, &bytes);
                for (bytes) |byte| if (byte != 0xff) {
                    blank = false;
                    break;
                };
                const root = self.decode(&bytes, slot) catch |err| switch (err) {
                    error.Corrupt => continue,
                    else => return err,
                };
                if (root.generation > self.current.generation) self.current = root;
            }
            if (self.current.generation == 0) return if (blank) error.Unformatted else error.Corrupt;
            return self;
        }

        pub fn generation(self: *const Self) u64 {
            return self.current.generation;
        }

        pub fn begin(self: *Self) Error!void {
            if (self.faulted) return error.Faulted;
            if (self.in_transaction) return error.Busy;
            if (self.current.generation == std.math.maxInt(u64)) return error.GenerationExhausted;
            self.staged = self.current;
            self.staged.generation += 1;
            self.in_transaction = true;
        }

        fn transaction(self: *Self) Error!void {
            if (self.faulted) return error.Faulted;
            if (!self.in_transaction) return error.NoTransaction;
        }

        fn find(root: *const Root, id: u32) ?usize {
            for (root.entries[0..root.count], 0..) |entry, i| if (entry.id == id) return i;
            return null;
        }

        pub fn put(self: *Self, id: u32, data: []const u8) Error!void {
            try self.transaction();
            if (id == 0 or data.len > std.math.maxInt(u32)) return error.InvalidArgument;
            const existing = find(&self.staged, id);
            if (existing == null and self.staged.count == object_limit) return error.TooManyObjects;
            const pages = data.len / page_bytes + @intFromBool(data.len % page_bytes != 0);
            if (pages > Device.capacity / page_bytes - self.staged.tail) return error.NoSpace;
            const first = if (data.len == 0) 0 else self.staged.tail;
            var position: usize = 0;
            for (0..pages) |i| {
                var buffer: [page_bytes]u8 = @splat(0);
                const n = @min(page_bytes, data.len - position);
                @memcpy(buffer[0..n], data[position..][0..n]);
                self.device.write((self.staged.tail + i) * page_bytes, &buffer) catch return self.ioFailure();
                position += n;
            }
            const index = existing orelse self.staged.count;
            if (existing == null) self.staged.count += 1;
            self.staged.entries[index] = .{ .id = id, .first = first, .length = @intCast(data.len), .checksum = std.hash.Crc32.hash(data) };
            self.staged.tail += @intCast(pages);
        }

        pub fn remove(self: *Self, id: u32) Error!void {
            try self.transaction();
            const index = find(&self.staged, id) orelse return error.NotFound;
            self.staged.count -= 1;
            self.staged.entries[index] = self.staged.entries[self.staged.count];
            self.staged.entries[self.staged.count] = .{};
        }

        pub fn truncate(self: *Self, id: u32, length: u32) Error!void {
            try self.transaction();
            const index = find(&self.staged, id) orelse return error.NotFound;
            var entry = self.staged.entries[index];
            if (length > entry.length) return error.InvalidArgument;
            entry.length = length;
            if (length == 0) entry.first = 0;
            entry.checksum = self.payloadChecksum(entry) catch return self.ioFailure();
            self.staged.entries[index] = entry;
        }

        pub fn rollback(self: *Self) Error!void {
            try self.transaction();
            self.in_transaction = false;
        }

        pub fn commit(self: *Self) Error!void {
            try self.transaction();
            // Data is durable before a root points at it. Success also requires
            // a separate barrier covering the root that locates those bytes.
            self.device.sync() catch return self.ioFailure();
            try self.publish(self.staged);
            self.current = self.staged;
            self.in_transaction = false;
        }

        fn ioFailure(self: *Self) Error {
            self.faulted = true;
            self.in_transaction = false;
            return error.Io;
        }

        fn publish(self: *Self, root: Root) Error!void {
            var bytes: [page_bytes]u8 = @splat(0);
            std.mem.writeInt(u32, bytes[0..4], magic, .little);
            std.mem.writeInt(u32, bytes[4..8], version, .little);
            std.mem.writeInt(u64, bytes[8..16], root.generation, .little);
            std.mem.writeInt(u32, bytes[16..20], root.tail, .little);
            std.mem.writeInt(u32, bytes[20..24], root.count, .little);
            for (root.entries[0..root.count], 0..) |entry, i| {
                const offset = entries_offset + i * entry_bytes;
                std.mem.writeInt(u32, bytes[offset..][0..4], entry.id, .little);
                std.mem.writeInt(u32, bytes[offset + 4 ..][0..4], entry.first, .little);
                std.mem.writeInt(u32, bytes[offset + 8 ..][0..4], entry.length, .little);
                std.mem.writeInt(u32, bytes[offset + 12 ..][0..4], entry.checksum, .little);
            }
            std.mem.writeInt(u32, bytes[checksum_offset..][0..4], std.hash.Crc32.hash(bytes[0..checksum_offset]), .little);
            self.device.write(@as(usize, @intCast(root.generation & 1)) * page_bytes, &bytes) catch return self.ioFailure();
            self.device.sync() catch return self.ioFailure();
        }

        pub fn read(self: *Self, id: u32, offset: usize, destination: []u8) Error!usize {
            if (self.faulted) return error.Faulted;
            const index = find(&self.current, id) orelse return error.NotFound;
            const entry = self.current.entries[index];
            if (offset >= entry.length) return 0;
            const n = @min(destination.len, entry.length - offset);
            self.device.read(@as(usize, entry.first) * page_bytes + offset, destination[0..n]) catch return self.ioFailure();
            return n;
        }

        fn payloadChecksum(self: *Self, entry: Entry) Error!u32 {
            var crc = std.hash.Crc32.init();
            var buffer: [512]u8 = undefined;
            var position: usize = 0;
            while (position < entry.length) {
                const n = @min(buffer.len, entry.length - position);
                try self.device.read(@as(usize, entry.first) * page_bytes + position, buffer[0..n]);
                crc.update(buffer[0..n]);
                position += n;
            }
            return crc.final();
        }

        fn decode(self: *Self, bytes: *const [page_bytes]u8, slot: usize) Error!Root {
            if (std.mem.readInt(u32, bytes[0..4], .little) != magic or
                std.mem.readInt(u32, bytes[4..8], .little) != version or
                std.hash.Crc32.hash(bytes[0..checksum_offset]) != std.mem.readInt(u32, bytes[checksum_offset..][0..4], .little)) return error.Corrupt;
            var root = Root{
                .generation = std.mem.readInt(u64, bytes[8..16], .little),
                .tail = std.mem.readInt(u32, bytes[16..20], .little),
                .count = std.mem.readInt(u32, bytes[20..24], .little),
            };
            if (root.generation == 0 or root.generation & 1 != slot or root.tail < 2 or
                root.tail > Device.capacity / page_bytes or root.count > object_limit) return error.Corrupt;
            for (root.entries[0..root.count], 0..) |*entry, i| {
                const offset = entries_offset + i * entry_bytes;
                entry.* = .{
                    .id = std.mem.readInt(u32, bytes[offset..][0..4], .little),
                    .first = std.mem.readInt(u32, bytes[offset + 4 ..][0..4], .little),
                    .length = std.mem.readInt(u32, bytes[offset + 8 ..][0..4], .little),
                    .checksum = std.mem.readInt(u32, bytes[offset + 12 ..][0..4], .little),
                };
                const pages = @as(u64, entry.length) / page_bytes + @intFromBool(entry.length % page_bytes != 0);
                if (entry.id == 0 or (entry.length == 0 and entry.first != 0) or
                    (entry.length != 0 and (entry.first < 2 or @as(u64, entry.first) + pages > root.tail))) return error.Corrupt;
                for (root.entries[0..i]) |prior| {
                    if (prior.id == entry.id) return error.Corrupt;
                    const prior_pages = @as(u64, prior.length) / page_bytes + @intFromBool(prior.length % page_bytes != 0);
                    if (pages != 0 and prior_pages != 0 and entry.first < @as(u64, prior.first) + prior_pages and
                        prior.first < @as(u64, entry.first) + pages) return error.Corrupt;
                }
                if (try self.payloadChecksum(entry.*) != entry.checksum) return error.Corrupt;
            }
            return root;
        }
    };
}
