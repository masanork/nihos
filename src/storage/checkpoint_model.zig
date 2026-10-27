//! Host-only paged-index experiment. Every transaction publishes a checkpoint;
//! there is no replay log or GC. Payload checksums are verified on demand.
const std = @import("std");
pub const page_bytes = 4096;
pub const crc_offset = page_bytes - 4;
pub const leaf_entries = (crc_offset - 32) / 32;
pub const root_magic: u32 = 0x4e494332;
pub const leaf_magic: u32 = 0x4e494c32;
pub const version: u32 = 1;
pub const Config = struct { leaf_pages: u16 = 128, index_pages: u32 = 4096, payload_start_page: ?u64 = null };
pub const Value = struct { first: u64, length: u64, checksum: u32 };
pub const Error = error{ Io, Corrupt, Unformatted, Faulted, NotReady, Busy, NoTransaction, NoSpace, NotFound, InvalidArgument, GenerationExhausted };

pub fn Store(comptime Device: type, comptime config: Config) type {
    const data_start = config.payload_start_page orelse (2 + @as(u64, config.index_pages));
    if (config.leaf_pages == 0 or config.leaf_pages > 128 or config.index_pages < config.leaf_pages or
        Device.capacity % page_bytes != 0 or data_start < 2 + @as(u64, config.index_pages) or
        data_start >= Device.capacity / page_bytes) @compileError("invalid experimental checkpoint geometry");
    return struct {
        const Self = @This();
        const Ref = struct { page: u64 = 0, checksum: u32 = 0 };
        const Root = struct {
            generation: u64 = 0,
            index_next: u64 = 2,
            payload_next: u64 = data_start,
            count: u32 = 0,
            refs: [config.leaf_pages]Ref = @splat(.{}),
        };
        pub const max_objects = config.leaf_pages * leaf_entries;
        pub const mount_limit_bytes = (2 + 2 * @as(usize, config.leaf_pages)) * page_bytes;
        pub const payload_start = data_start;
        // SAFETY: format/recover assign device before I/O; ready gates public operations.
        device: *Device = undefined,
        current: Root = .{},
        staged: Root = .{},
        cache: [page_bytes]u8 = @splat(0),
        ready: bool = false,
        faulted: bool = false,
        in_transaction: bool = false,
        mount_bytes: usize = 0,

        fn readPage(self: *Self, page: u64, bytes: *[page_bytes]u8) Error!void {
            self.device.read(page * page_bytes, bytes) catch return self.ioFailure();
        }
        fn writePage(self: *Self, page: u64, bytes: *const [page_bytes]u8) Error!void {
            self.device.write(page * page_bytes, bytes) catch return self.ioFailure();
        }
        fn ioFailure(self: *Self) Error {
            self.faulted = true;
            self.in_transaction = false;
            return error.Io;
        }
        fn usable(self: *Self) Error!void {
            if (self.faulted) return error.Faulted;
            if (!self.ready) return error.NotReady;
        }
        fn transaction(self: *Self) Error!void {
            try self.usable();
            if (!self.in_transaction) return error.NoTransaction;
        }
        fn validKey(key: u32) Error!void {
            if (key == 0 or key > max_objects) return error.InvalidArgument;
        }
        fn leafIndex(key: u32) usize {
            return (key - 1) / leaf_entries;
        }
        fn entryOffset(key: u32) usize {
            return 32 + ((key - 1) % leaf_entries) * 32;
        }
        fn finishPage(bytes: *[page_bytes]u8) u32 {
            const checksum = std.hash.Crc32.hash(bytes[0..crc_offset]);
            std.mem.writeInt(u32, bytes[crc_offset..][0..4], checksum, .little);
            return checksum;
        }
        fn pageValid(bytes: *const [page_bytes]u8) bool {
            return std.hash.Crc32.hash(bytes[0..crc_offset]) == std.mem.readInt(u32, bytes[crc_offset..][0..4], .little);
        }

        pub fn format(self: *Self, device: *Device) Error!void {
            if (self.ready) return error.Busy;
            self.* = .{ .device = device };
            for (0..2) |slot| {
                try self.readPage(slot, &self.cache);
                for (self.cache) |byte| if (byte != 0xff) return error.Corrupt;
            }
            self.current.generation = 1;
            try self.publish(&self.current);
            self.ready = true;
        }

        pub fn recover(self: *Self, device: *Device) Error!void {
            if (self.ready) return error.Busy;
            self.* = .{ .device = device };
            var blank = true;
            for (0..2) |slot| {
                var bytes: [page_bytes]u8 = undefined;
                try self.readPage(slot, &bytes);
                self.mount_bytes += page_bytes;
                for (bytes) |byte| if (byte != 0xff) {
                    blank = false;
                    break;
                };
                const root = self.decodeRoot(&bytes, slot) catch |err| switch (err) {
                    error.Corrupt => continue,
                    else => return err,
                };
                if (root.generation > self.current.generation) self.current = root;
            }
            if (self.current.generation == 0) return if (blank) error.Unformatted else error.Corrupt;
            self.ready = true;
        }

        pub fn generation(self: *const Self) u64 {
            return self.current.generation;
        }
        pub fn begin(self: *Self) Error!void {
            try self.usable();
            if (self.in_transaction) return error.Busy;
            if (self.current.generation == std.math.maxInt(u64)) return error.GenerationExhausted;
            self.staged = self.current;
            self.staged.generation += 1;
            self.in_transaction = true;
        }
        pub fn rollback(self: *Self) Error!void {
            try self.transaction();
            self.in_transaction = false;
        }

        fn decodeEntry(root: *const Root, bytes: []const u8) Error!?Value {
            const state = std.mem.readInt(u32, bytes[0..4], .little);
            const first = std.mem.readInt(u64, bytes[8..16], .little);
            const length = std.mem.readInt(u64, bytes[16..24], .little);
            const checksum = std.mem.readInt(u32, bytes[24..28], .little);
            if (std.mem.readInt(u32, bytes[4..8], .little) != 0 or std.mem.readInt(u32, bytes[28..32], .little) != 0) return error.Corrupt;
            if (state == 0) {
                if (first != 0 or length != 0 or checksum != 0) return error.Corrupt;
                return null;
            }
            if (state != 1) return error.Corrupt;
            if (length == 0) {
                if (first != 0 or checksum != 0) return error.Corrupt;
            } else {
                const pages = length / page_bytes + @intFromBool(length % page_bytes != 0);
                if (first < data_start or first > root.payload_next or pages > root.payload_next - first) return error.Corrupt;
            }
            return .{ .first = first, .length = length, .checksum = checksum };
        }

        fn loadLeaf(self: *Self, root: *const Root, index: usize) Error!void {
            const ref = root.refs[index];
            if (ref.page == 0) {
                self.cache = @splat(0);
                return;
            }
            try self.readPage(ref.page, &self.cache);
            if (!pageValid(&self.cache) or std.mem.readInt(u32, self.cache[crc_offset..][0..4], .little) != ref.checksum or
                std.mem.readInt(u32, self.cache[0..4], .little) != leaf_magic or
                std.mem.readInt(u32, self.cache[4..8], .little) != version or
                std.mem.readInt(u32, self.cache[8..12], .little) != index or
                std.mem.readInt(u32, self.cache[12..16], .little) != 0) return error.Corrupt;
            const leaf_epoch = std.mem.readInt(u64, self.cache[16..24], .little);
            if (leaf_epoch == 0 or leaf_epoch > root.generation) return error.Corrupt;
            for (0..leaf_entries) |i| _ = try decodeEntry(root, self.cache[32 + i * 32 ..][0..32]);
        }

        fn lookup(self: *Self, root: *const Root, key: u32) Error!?Value {
            try validKey(key);
            try self.loadLeaf(root, leafIndex(key));
            return decodeEntry(root, self.cache[entryOffset(key)..][0..32]);
        }
        fn checkedLookup(self: *Self, root: *const Root, key: u32) Error!?Value {
            return self.lookup(root, key) catch |err| {
                if (err == error.Corrupt) {
                    self.faulted = true;
                    self.in_transaction = false;
                }
                return err;
            };
        }
        pub fn get(self: *Self, key: u32) Error!Value {
            try self.usable();
            return try self.checkedLookup(&self.current, key) orelse error.NotFound;
        }

        fn preflight(self: *Self, pages: usize) Error!void {
            if (self.staged.index_next >= 2 + @as(u64, config.index_pages) or
                pages > Device.capacity / page_bytes - self.staged.payload_next) return error.NoSpace;
        }
        fn replace(self: *Self, key: u32, value: ?Value, existed: bool) Error!void {
            const offset = entryOffset(key);
            @memset(self.cache[offset..][0..32], 0);
            if (value) |item| {
                std.mem.writeInt(u32, self.cache[offset..][0..4], 1, .little);
                std.mem.writeInt(u64, self.cache[offset + 8 ..][0..8], item.first, .little);
                std.mem.writeInt(u64, self.cache[offset + 16 ..][0..8], item.length, .little);
                std.mem.writeInt(u32, self.cache[offset + 24 ..][0..4], item.checksum, .little);
            }
            std.mem.writeInt(u32, self.cache[0..4], leaf_magic, .little);
            std.mem.writeInt(u32, self.cache[4..8], version, .little);
            std.mem.writeInt(u32, self.cache[8..12], @intCast(leafIndex(key)), .little);
            std.mem.writeInt(u64, self.cache[16..24], self.staged.generation, .little);
            const checksum = finishPage(&self.cache);
            try self.writePage(self.staged.index_next, &self.cache);
            self.staged.refs[leafIndex(key)] = .{ .page = self.staged.index_next, .checksum = checksum };
            self.staged.index_next += 1;
            if (value != null and !existed) self.staged.count += 1;
            if (value == null and existed) self.staged.count -= 1;
        }

        pub fn put(self: *Self, key: u32, data: []const u8) Error!void {
            try self.transaction();
            try validKey(key);
            const pages = data.len / page_bytes + @intFromBool(data.len % page_bytes != 0);
            try self.preflight(pages);
            const existed = try self.checkedLookup(&self.staged, key) != null;
            var position: usize = 0;
            for (0..pages) |i| {
                var bytes: [page_bytes]u8 = @splat(0);
                const n = @min(page_bytes, data.len - position);
                @memcpy(bytes[0..n], data[position..][0..n]);
                try self.writePage(self.staged.payload_next + i, &bytes);
                position += n;
            }
            const value = Value{ .first = if (data.len == 0) 0 else self.staged.payload_next, .length = data.len, .checksum = std.hash.Crc32.hash(data) };
            self.staged.payload_next += pages;
            try self.replace(key, value, existed);
        }
        pub fn remove(self: *Self, key: u32) Error!void {
            try self.transaction();
            try validKey(key);
            try self.preflight(0);
            if (try self.checkedLookup(&self.staged, key) == null) return error.NotFound;
            try self.replace(key, null, true);
        }
        pub fn commit(self: *Self) Error!void {
            try self.transaction();
            self.device.sync() catch return self.ioFailure();
            try self.publish(&self.staged);
            self.current = self.staged;
            self.in_transaction = false;
        }

        pub fn read(self: *Self, key: u32, offset: u64, destination: []u8) Error!usize {
            const value = try self.get(key);
            // Metadata-only mount intentionally defers payload verification.
            // This first experiment verifies the whole extent on every read.
            var crc = std.hash.Crc32.init();
            var buffer: [512]u8 = undefined;
            var position: u64 = 0;
            while (position < value.length) {
                const n: usize = @intCast(@min(buffer.len, value.length - position));
                self.device.read(value.first * page_bytes + position, buffer[0..n]) catch return self.ioFailure();
                crc.update(buffer[0..n]);
                position += n;
            }
            if (crc.final() != value.checksum) {
                self.faulted = true;
                return error.Corrupt;
            }
            if (offset >= value.length) return 0;
            const n: usize = @intCast(@min(destination.len, value.length - offset));
            self.device.read(value.first * page_bytes + offset, destination[0..n]) catch return self.ioFailure();
            return n;
        }

        fn publish(self: *Self, root: *const Root) Error!void {
            var bytes: [page_bytes]u8 = @splat(0);
            std.mem.writeInt(u32, bytes[0..4], root_magic, .little);
            std.mem.writeInt(u32, bytes[4..8], version, .little);
            std.mem.writeInt(u64, bytes[8..16], root.generation, .little);
            std.mem.writeInt(u64, bytes[16..24], Device.capacity / page_bytes, .little);
            std.mem.writeInt(u64, bytes[24..32], root.index_next, .little);
            std.mem.writeInt(u64, bytes[32..40], root.payload_next, .little);
            std.mem.writeInt(u32, bytes[40..44], config.leaf_pages, .little);
            std.mem.writeInt(u32, bytes[44..48], config.index_pages, .little);
            std.mem.writeInt(u64, bytes[48..56], data_start, .little);
            std.mem.writeInt(u32, bytes[56..60], root.count, .little);
            for (root.refs, 0..) |ref, i| {
                std.mem.writeInt(u64, bytes[64 + i * 16 ..][0..8], ref.page, .little);
                std.mem.writeInt(u32, bytes[72 + i * 16 ..][0..4], ref.checksum, .little);
            }
            _ = finishPage(&bytes);
            try self.writePage(root.generation & 1, &bytes);
            self.device.sync() catch return self.ioFailure();
        }

        fn decodeRoot(self: *Self, bytes: *const [page_bytes]u8, slot: usize) Error!Root {
            if (!pageValid(bytes) or std.mem.readInt(u32, bytes[0..4], .little) != root_magic or
                std.mem.readInt(u32, bytes[4..8], .little) != version or
                std.mem.readInt(u64, bytes[16..24], .little) != Device.capacity / page_bytes or
                std.mem.readInt(u32, bytes[40..44], .little) != config.leaf_pages or
                std.mem.readInt(u32, bytes[44..48], .little) != config.index_pages or
                std.mem.readInt(u64, bytes[48..56], .little) != data_start or
                std.mem.readInt(u32, bytes[60..64], .little) != 0) return error.Corrupt;
            var root = Root{ .generation = std.mem.readInt(u64, bytes[8..16], .little), .index_next = std.mem.readInt(u64, bytes[24..32], .little), .payload_next = std.mem.readInt(u64, bytes[32..40], .little), .count = std.mem.readInt(u32, bytes[56..60], .little) };
            if (root.generation == 0 or root.generation & 1 != slot or root.index_next < 2 or root.index_next > 2 + @as(u64, config.index_pages) or
                root.payload_next < data_start or root.payload_next > Device.capacity / page_bytes or root.count > max_objects) return error.Corrupt;
            for (&root.refs, 0..) |*ref, i| {
                ref.* = .{ .page = std.mem.readInt(u64, bytes[64 + i * 16 ..][0..8], .little), .checksum = std.mem.readInt(u32, bytes[72 + i * 16 ..][0..4], .little) };
                if (std.mem.readInt(u32, bytes[76 + i * 16 ..][0..4], .little) != 0) return error.Corrupt;
                if (ref.page == 0) {
                    if (ref.checksum != 0) return error.Corrupt;
                    continue;
                }
                if (ref.page < 2 or ref.page >= root.index_next) return error.Corrupt;
                for (root.refs[0..i]) |prior| if (prior.page == ref.page) return error.Corrupt;
            }
            var count: u32 = 0;
            for (root.refs, 0..) |ref, i| {
                if (ref.page == 0) continue;
                self.mount_bytes += page_bytes;
                try self.loadLeaf(&root, i);
                for (0..leaf_entries) |j| if (try decodeEntry(&root, self.cache[32 + j * 32 ..][0..32]) != null) {
                    count += 1;
                };
            }
            if (count != root.count) return error.Corrupt;
            return root;
        }
    };
}
