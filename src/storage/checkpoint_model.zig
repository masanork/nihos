//! Host-only paged-index experiment. Every transaction publishes a checkpoint;
//! Index and payload pages are reclaimed by reachability without relocation.
//! There is no replay log. Payload checksums are verified on demand.
const std = @import("std");
pub const page_bytes = 4096;
pub const crc_offset = page_bytes - 4;
pub const leaf_entries = (crc_offset - 32) / 32;
pub const root_magic: u32 = 0x4e494332;
pub const leaf_magic: u32 = 0x4e494c32;
pub const version: u32 = 3;
pub const checksum_magic: u32 = 0x4e495332;
pub const checksums_per_page = (crc_offset - 32) / 4;
pub fn dataPages(length: u64) u64 {
    return length / page_bytes + @intFromBool(length % page_bytes != 0);
}
pub fn checksumPages(length: u64) u64 {
    const pages = dataPages(length);
    return pages / checksums_per_page + @intFromBool(pages % checksums_per_page != 0);
}
pub const Config = struct {
    leaf_pages: u16 = 128,
    index_pages: u32 = 4096,
    payload_start_page: ?u64 = null,
    reader_slots: u8 = 2,
    payload_reserve_pages: u32 = 0,
    payload_window_bytes: u16 = 4096,
};
pub const Value = struct { first: u64, length: u64, checksum: u32 };
pub const Reader = struct { slot: u8, token: u64 };
pub const IndexSpace = struct { capacity_pages: u32, protected_pages: u32, available_pages: u32 };
pub const PayloadSpace = struct { usable_pages: u64, reserved_pages: u32, free_pages: u64, largest_run: u64 };
pub const Error = error{ Io, Corrupt, Unformatted, Faulted, NotReady, Busy, NoTransaction, NoSpace, NotFound, InvalidArgument, GenerationExhausted, ReaderLimit, InvalidReader };

pub fn Store(comptime Device: type, comptime config: Config) type {
    const data_start = config.payload_start_page orelse (2 + @as(u64, config.index_pages));
    const capacity_pages = Device.capacity / page_bytes;
    if (config.leaf_pages == 0 or config.leaf_pages > 128 or config.index_pages < config.leaf_pages or
        Device.capacity % page_bytes != 0 or data_start < 2 + @as(u64, config.index_pages) or
        config.payload_reserve_pages >= capacity_pages or data_start >= capacity_pages - config.payload_reserve_pages or
        config.payload_window_bytes == 0 or config.payload_window_bytes > 16384) @compileError("invalid experimental checkpoint geometry");
    const data_end = capacity_pages - config.payload_reserve_pages;
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
        const Pin = struct { root: Root = .{}, token: u64 = 0 };
        pub const max_objects = config.leaf_pages * leaf_entries;
        pub const reader_limit = config.reader_slots;
        pub const index_pool_pages = config.index_pages;
        // Current + retained disk root + staged transaction + reader snapshots.
        pub const max_protected_index_pages = (3 + @as(u32, config.reader_slots)) * config.leaf_pages;
        pub const mount_limit_bytes = (2 + 2 * @as(usize, config.leaf_pages)) * page_bytes;
        pub const payload_start = data_start;
        pub const payload_end = data_end;
        // SAFETY: format/recover assign device before I/O; ready gates public operations.
        device: *Device = undefined,
        current: Root = .{},
        staged: Root = .{},
        retained: Root = .{},
        readers: [config.reader_slots]Pin = @splat(.{}),
        next_reader: u64 = 1,
        cache: [page_bytes]u8 = @splat(0),
        occupancy: [config.payload_window_bytes]u8 = @splat(0),
        search_windows: u32 = 0,
        search_leaf_reads: u32 = 0,
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
                if (root.generation > self.current.generation) {
                    self.retained = self.current;
                    self.current = root;
                } else self.retained = root;
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

        /// Instance-scoped host handle, not an isolated public capability ABI.
        pub fn pin(self: *Self) Error!Reader {
            try self.usable();
            if (self.next_reader == std.math.maxInt(u64)) return error.GenerationExhausted;
            for (&self.readers, 0..) |*reader, i| if (reader.token == 0) {
                reader.* = .{ .root = self.current, .token = self.next_reader };
                self.next_reader += 1;
                return .{ .slot = @intCast(i), .token = reader.token };
            };
            return error.ReaderLimit;
        }
        fn readerRoot(self: *Self, reader: Reader) Error!*const Root {
            if (reader.slot >= self.readers.len or reader.token == 0 or self.readers[reader.slot].token != reader.token) return error.InvalidReader;
            return &self.readers[reader.slot].root;
        }
        pub fn release(self: *Self, reader: Reader) Error!void {
            // Allow resource release after an I/O/integrity fault as well.
            if (!self.ready) return error.NotReady;
            _ = try self.readerRoot(reader);
            self.readers[reader.slot].token = 0;
        }
        fn rootReferences(root: *const Root, page: u64) bool {
            for (root.refs) |ref| if (ref.page == page) return true;
            return false;
        }
        fn protectedIndex(self: *const Self, page: u64) bool {
            if (rootReferences(&self.current, page) or rootReferences(&self.retained, page) or
                (self.in_transaction and rootReferences(&self.staged, page))) return true;
            for (&self.readers) |*reader| if (reader.token != 0 and rootReferences(&reader.root, page)) return true;
            return false;
        }
        fn availableIndex(self: *const Self) ?u64 {
            for (0..config.index_pages) |i| {
                const page = 2 + @as(u64, i);
                if (!self.protectedIndex(page)) return page;
            }
            return null;
        }
        pub fn indexSpace(self: *Self) Error!IndexSpace {
            try self.usable();
            var used: u32 = 0;
            for (0..config.index_pages) |i| if (self.protectedIndex(2 + @as(u64, i))) {
                used += 1;
            };
            return .{ .capacity_pages = config.index_pages, .protected_pages = used, .available_pages = config.index_pages - used };
        }
        /// A root-only checkpoint retires the previous disk root without
        /// allocating index/payload pages. Pinned readers remain protected.
        pub fn collectIndex(self: *Self) Error!IndexSpace {
            try self.collectPayload();
            return self.indexSpace();
        }
        /// Retire the older disk root using only the two fixed anchors. This
        /// requires no free payload/index pages; pinned snapshots stay live.
        pub fn collectPayload(self: *Self) Error!void {
            try self.begin();
            try self.commit();
        }

        fn markRange(self: *Self, start: usize, end: usize) void {
            var cursor = start;
            while (cursor < end and cursor % 8 != 0) : (cursor += 1) self.occupancy[cursor / 8] |= @as(u8, 1) << @as(u3, @intCast(cursor % 8));
            const full_end = end / 8 * 8;
            if (cursor < full_end) {
                @memset(self.occupancy[cursor / 8 .. full_end / 8], 0xff);
                cursor = full_end;
            }
            while (cursor < end) : (cursor += 1) self.occupancy[cursor / 8] |= @as(u8, 1) << @as(u3, @intCast(cursor % 8));
        }
        fn markRoot(self: *Self, root: *const Root, start: u64, end: u64) Error!void {
            for (root.refs, 0..) |ref, index| {
                if (ref.page == 0) continue;
                self.search_leaf_reads +|= 1;
                self.loadLeaf(root, index) catch |err| {
                    if (err == error.Corrupt) return self.corruption();
                    return err;
                };
                for (0..leaf_entries) |entry| {
                    const value = try decodeEntry(root, self.cache[32 + entry * 32 ..][0..32]) orelse continue;
                    if (value.length == 0) continue;
                    const last = value.first + dataPages(value.length) + checksumPages(value.length);
                    const overlap_start = @max(start, value.first);
                    const overlap_end = @min(end, last);
                    if (overlap_start < overlap_end) self.markRange(@intCast(overlap_start - start), @intCast(overlap_end - start));
                }
            }
        }
        fn markWindow(self: *Self, start: u64, end: u64) Error!void {
            self.search_windows +|= 1;
            @memset(&self.occupancy, 0);
            try self.markRoot(&self.current, start, end);
            try self.markRoot(&self.retained, start, end);
            if (self.in_transaction) try self.markRoot(&self.staged, start, end);
            for (&self.readers) |*reader| if (reader.token != 0) try self.markRoot(&reader.root, start, end);
        }
        fn occupied(self: *const Self, offset: usize) bool {
            return self.occupancy[offset / 8] & (@as(u8, 1) << @as(u3, @intCast(offset % 8))) != 0;
        }
        fn findPayload(self: *Self, pages: u64) Error!u64 {
            self.search_windows = 0;
            self.search_leaf_reads = 0;
            if (pages == 0) return 0;
            if (pages > data_end - data_start) return error.NoSpace;
            // Never rewind high-water marks. A tail beyond every protected
            // root's high-water mark needs no bitmap scan.
            var tail = @max(self.current.payload_next, self.retained.payload_next);
            if (self.in_transaction) tail = @max(tail, self.staged.payload_next);
            for (&self.readers) |*reader| if (reader.token != 0) {
                tail = @max(tail, reader.root.payload_next);
            };
            if (pages <= data_end - tail) return tail;
            var start: u64 = data_start;
            var run: u64 = 0;
            while (start < data_end) {
                const end = start + @min(self.occupancy.len * 8, data_end - start);
                try self.markWindow(start, end);
                for (0..@intCast(end - start)) |offset| {
                    run = if (self.occupied(offset)) 0 else run + 1;
                    if (run == pages) return start + offset + 1 - run;
                }
                start = end;
            }
            return error.NoSpace;
        }
        /// Exact union statistics, scanning fixed-size bitmap windows. This
        /// may read metadata for every window; it is not a bounded-time API.
        pub fn payloadSpace(self: *Self) Error!PayloadSpace {
            try self.usable();
            self.search_windows = 0;
            self.search_leaf_reads = 0;
            var result = PayloadSpace{ .usable_pages = data_end - data_start, .reserved_pages = config.payload_reserve_pages, .free_pages = 0, .largest_run = 0 };
            var start: u64 = data_start;
            var run: u64 = 0;
            while (start < data_end) {
                const end = start + @min(self.occupancy.len * 8, data_end - start);
                try self.markWindow(start, end);
                for (0..@intCast(end - start)) |offset| {
                    if (self.occupied(offset)) {
                        run = 0;
                    } else {
                        run += 1;
                        result.free_pages += 1;
                        result.largest_run = @max(result.largest_run, run);
                    }
                }
                start = end;
            }
            return result;
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
                const pages = dataPages(length) + checksumPages(length);
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

        fn preflight(self: *Self) Error!void {
            if (self.availableIndex() == null) return error.NoSpace;
        }
        fn replace(self: *Self, key: u32, value: ?Value, existed: bool) Error!void {
            const page = self.availableIndex() orelse return error.NoSpace;
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
            try self.writePage(page, &self.cache);
            self.staged.refs[leafIndex(key)] = .{ .page = page, .checksum = checksum };
            self.staged.index_next = @max(self.staged.index_next, page + 1);
            if (value != null and !existed) self.staged.count += 1;
            if (value == null and existed) self.staged.count -= 1;
        }

        pub fn put(self: *Self, key: u32, data: []const u8) Error!void {
            try self.transaction();
            try validKey(key);
            const pages = dataPages(data.len);
            const tables = checksumPages(data.len);
            try self.preflight();
            const first = try self.findPayload(pages + tables);
            const existed = try self.checkedLookup(&self.staged, key) != null;
            var position: usize = 0;
            for (0..@intCast(tables)) |table| {
                self.cache = @splat(0);
                std.mem.writeInt(u32, self.cache[0..4], checksum_magic, .little);
                std.mem.writeInt(u32, self.cache[4..8], version, .little);
                std.mem.writeInt(u64, self.cache[8..16], first, .little);
                std.mem.writeInt(u64, self.cache[16..24], data.len, .little);
                std.mem.writeInt(u64, self.cache[24..32], table, .little);
                const count: usize = @intCast(@min(checksums_per_page, pages - table * checksums_per_page));
                for (0..count) |entry| {
                    var bytes: [page_bytes]u8 = @splat(0);
                    const n = @min(page_bytes, data.len - position);
                    @memcpy(bytes[0..n], data[position..][0..n]);
                    try self.writePage(first + table * checksums_per_page + entry, &bytes);
                    std.mem.writeInt(u32, self.cache[32 + entry * 4 ..][0..4], std.hash.Crc32.hash(&bytes), .little);
                    position += n;
                }
                _ = finishPage(&self.cache);
                try self.writePage(first + pages + table, &self.cache);
            }
            // The checksum table used the leaf scratch. Reload the staged leaf
            // before replacing one entry, preserving other keys in that leaf.
            if (tables != 0) _ = try self.checkedLookup(&self.staged, key);
            const value = Value{ .first = if (data.len == 0) 0 else first, .length = data.len, .checksum = std.hash.Crc32.hash(data) };
            if (pages != 0) self.staged.payload_next = @max(self.staged.payload_next, first + pages + tables);
            try self.replace(key, value, existed);
        }
        pub fn remove(self: *Self, key: u32) Error!void {
            try self.transaction();
            try validKey(key);
            try self.preflight();
            if (try self.checkedLookup(&self.staged, key) == null) return error.NotFound;
            try self.replace(key, null, true);
        }
        pub fn commit(self: *Self) Error!void {
            try self.transaction();
            self.device.sync() catch return self.ioFailure();
            try self.publish(&self.staged);
            self.retained = self.current;
            self.current = self.staged;
            self.in_transaction = false;
        }

        pub fn read(self: *Self, key: u32, offset: u64, destination: []u8) Error!usize {
            const value = try self.get(key);
            return self.readValue(value, offset, destination);
        }
        pub fn readPinned(self: *Self, reader: Reader, key: u32, offset: u64, destination: []u8) Error!usize {
            try self.usable();
            const root = try self.readerRoot(reader);
            const value = try self.checkedLookup(root, key) orelse return error.NotFound;
            return self.readValue(value, offset, destination);
        }
        fn readValue(self: *Self, value: Value, offset: u64, destination: []u8) Error!usize {
            if (offset >= value.length or destination.len == 0) return 0;
            const n: usize = @intCast(@min(destination.len, value.length - offset));
            var position: usize = 0;
            var loaded_table: ?u64 = null;
            var buffer: [page_bytes]u8 = undefined;
            while (position < n) {
                const logical = offset + position;
                const page = logical / page_bytes;
                try self.checkedPage(value, page, &loaded_table, &buffer);
                const within: usize = @intCast(logical % page_bytes);
                const count = @min(page_bytes - within, n - position);
                @memcpy(destination[position..][0..count], buffer[within..][0..count]);
                position += count;
            }
            return n;
        }

        fn checkedPage(self: *Self, value: Value, page: u64, loaded_table: *?u64, buffer: *[page_bytes]u8) Error!void {
            const table = page / checksums_per_page;
            if (loaded_table.* != table) {
                try self.readPage(value.first + dataPages(value.length) + table, &self.cache);
                if (!pageValid(&self.cache) or std.mem.readInt(u32, self.cache[0..4], .little) != checksum_magic or
                    std.mem.readInt(u32, self.cache[4..8], .little) != version or
                    std.mem.readInt(u64, self.cache[8..16], .little) != value.first or
                    std.mem.readInt(u64, self.cache[16..24], .little) != value.length or
                    std.mem.readInt(u64, self.cache[24..32], .little) != table) return self.corruption();
                loaded_table.* = table;
            }
            try self.readPage(value.first + page, buffer);
            const entry: usize = @intCast(page % checksums_per_page);
            if (std.hash.Crc32.hash(buffer) != std.mem.readInt(u32, self.cache[32 + entry * 4 ..][0..4], .little)) return self.corruption();
        }

        fn corruption(self: *Self) Error {
            self.faulted = true;
            self.in_transaction = false;
            return error.Corrupt;
        }

        /// Explicit full-object scrub. Ordinary partial reads verify only the
        /// pages they touch; callers can request this pass for cold corruption.
        pub fn verify(self: *Self, key: u32) Error!void {
            const value = try self.get(key);
            var crc = std.hash.Crc32.init();
            var buffer: [page_bytes]u8 = undefined;
            var position: u64 = 0;
            var loaded_table: ?u64 = null;
            while (position < value.length) {
                const n: usize = @intCast(@min(buffer.len, value.length - position));
                try self.checkedPage(value, position / page_bytes, &loaded_table, &buffer);
                crc.update(buffer[0..n]);
                position += n;
            }
            if (crc.final() != value.checksum) return self.corruption();
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
            std.mem.writeInt(u32, bytes[60..64], config.payload_reserve_pages, .little);
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
                std.mem.readInt(u32, bytes[60..64], .little) != config.payload_reserve_pages) return error.Corrupt;
            var root = Root{ .generation = std.mem.readInt(u64, bytes[8..16], .little), .index_next = std.mem.readInt(u64, bytes[24..32], .little), .payload_next = std.mem.readInt(u64, bytes[32..40], .little), .count = std.mem.readInt(u32, bytes[56..60], .little) };
            if (root.generation == 0 or root.generation & 1 != slot or root.index_next < 2 or root.index_next > 2 + @as(u64, config.index_pages) or
                root.payload_next < data_start or root.payload_next > data_end or root.count > max_objects) return error.Corrupt;
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
