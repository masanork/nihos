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
    leaf_cache_pages: u16 = 0,
};
pub const SearchBudget = struct { leaf_visits: u16 = 8, bitmap_pages: u32 = 1024 };
pub const SearchResult = union(enum) { pending, found: u64, no_space, space: PayloadSpace };
pub const Value = struct { first: u64, length: u64, checksum: u32 };
pub const Reader = struct { slot: u8, token: u64 };
pub const Stream = struct { token: u64 };
pub const PatchProgress = struct { consumed: usize = 0, done: bool = false, need_input: bool = false };
pub const IndexSpace = struct { capacity_pages: u32, protected_pages: u32, available_pages: u32 };
pub const PayloadSpace = struct { usable_pages: u64, reserved_pages: u32, free_pages: u64, largest_run: u64 };
pub const Error = error{ Io, Corrupt, Unformatted, Faulted, NotReady, Busy, NoTransaction, NoSpace, NotFound, InvalidArgument, GenerationExhausted, ReaderLimit, InvalidReader, InvalidSearch, SearchRequired, InvalidStream, IncompleteStream };

pub fn Store(comptime Device: type, comptime config: Config) type {
    const data_start = config.payload_start_page orelse (2 + @as(u64, config.index_pages));
    const capacity_pages = Device.capacity / page_bytes;
    if (config.leaf_pages == 0 or config.leaf_pages > 128 or config.index_pages < config.leaf_pages or
        Device.capacity % page_bytes != 0 or data_start < 2 + @as(u64, config.index_pages) or
        config.payload_reserve_pages >= capacity_pages or data_start >= capacity_pages - config.payload_reserve_pages or
        config.payload_window_bytes == 0 or config.payload_window_bytes > 16384 or
        config.leaf_cache_pages > config.leaf_pages) @compileError("invalid experimental checkpoint geometry");
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
        const CachedLeaf = struct { ref: Ref = .{}, bytes: [page_bytes]u8 = @splat(0) };
        const Patch = struct { source: Value, offset: u64, length: u64 };
        const Writer = struct {
            token: u64 = 0,
            key: u32 = 0,
            first: u64 = 0,
            length: u64 = 0,
            received: u64 = 0,
            page_index: u64 = 0,
            table_index: u64 = 0,
            fill: usize = 0,
            table_entries: usize = 0,
            crc: std.hash.Crc32 = std.hash.Crc32.init(),
            patch: ?Patch = null,
            data: [page_bytes]u8 = @splat(0),
            table: [page_bytes]u8 = @splat(0),
        };
        const Search = struct {
            phase: enum { idle, mark, scan, done } = .idle,
            wanted: ?u64 = null,
            result: SearchResult = .pending,
            start: u64 = data_start,
            end: u64 = data_start,
            root: u16 = 0,
            leaf: u16 = 0,
            bit: u32 = 0,
            run: u64 = 0,
            space: PayloadSpace = .{ .usable_pages = data_end - data_start, .reserved_pages = config.payload_reserve_pages, .free_pages = 0, .largest_run = 0 },
        };
        pub const max_objects = config.leaf_pages * leaf_entries;
        pub const reader_limit = config.reader_slots;
        pub const metadata_cache_pages = config.leaf_cache_pages;
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
        leaf_cache: [config.leaf_cache_pages]CachedLeaf = @splat(.{}),
        search: Search = .{},
        writer: Writer = .{},
        next_stream: u64 = 1,
        metadata_reads: u64 = 0,
        metadata_hits: u64 = 0,
        step_leaf_visits: u16 = 0,
        step_bitmap_pages: u32 = 0,
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
            // Physical pages can be recycled for another logical leaf. Drop
            // every matching cached page before attempting any write to it.
            for (&self.leaf_cache) |*entry| if (entry.ref.page == page) {
                entry.ref = .{};
            };
            self.device.write(page * page_bytes, bytes) catch return self.ioFailure();
        }
        fn ioFailure(self: *Self) Error {
            self.faulted = true;
            self.in_transaction = false;
            self.invalidateSearch();
            self.writer.token = 0;
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
            self.invalidateSearch();
            self.staged = self.current;
            self.staged.generation += 1;
            self.in_transaction = true;
        }
        pub fn rollback(self: *Self) Error!void {
            try self.transaction();
            self.invalidateSearch();
            self.writer.token = 0;
            self.in_transaction = false;
        }

        /// Instance-scoped host handle, not an isolated public capability ABI.
        pub fn pin(self: *Self) Error!Reader {
            try self.usable();
            if (self.next_reader == std.math.maxInt(u64)) return error.GenerationExhausted;
            for (&self.readers, 0..) |*reader, i| if (reader.token == 0) {
                self.invalidateSearch();
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
            self.invalidateSearch();
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
        fn markLeaf(self: *Self, root: *const Root, index: usize) Error!void {
            const before = self.metadata_reads;
            self.loadLeaf(root, index) catch |err| {
                if (err == error.Corrupt) return self.corruption();
                return err;
            };
            self.search_leaf_reads +|= @intCast(self.metadata_reads - before);
            for (0..leaf_entries) |entry| {
                const value = try decodeEntry(root, self.cache[32 + entry * 32 ..][0..32]) orelse continue;
                if (value.length == 0) continue;
                const last = value.first + dataPages(value.length) + checksumPages(value.length);
                const first_overlap = @max(self.search.start, value.first);
                const last_overlap = @min(self.search.end, last);
                if (first_overlap < last_overlap) self.markRange(@intCast(first_overlap - self.search.start), @intCast(last_overlap - self.search.start));
            }
        }
        fn occupied(self: *const Self, offset: usize) bool {
            return self.occupancy[offset / 8] & (@as(u8, 1) << @as(u3, @intCast(offset % 8))) != 0;
        }
        fn invalidateSearch(self: *Self) void {
            self.search.phase = .idle;
        }
        pub fn cancelPayloadSearch(self: *Self) void {
            self.invalidateSearch();
        }
        /// Drop cached immutable metadata, e.g. before a forced cold integrity
        /// check. Cache hits are still CRC/identity/bounds checked in RAM.
        pub fn dropMetadataCache(self: *Self) void {
            for (&self.leaf_cache) |*entry| entry.ref = .{};
        }
        fn startWindow(self: *Self) void {
            self.search_windows +|= 1;
            self.search.end = self.search.start + @min(self.occupancy.len * 8, data_end - self.search.start);
            self.search.root = 0;
            self.search.leaf = 0;
            self.search.bit = 0;
            self.search.phase = .mark;
            @memset(&self.occupancy, 0);
        }
        fn startSearch(self: *Self, wanted: ?u64) void {
            self.search = .{ .wanted = wanted };
            self.search_windows = 0;
            self.search_leaf_reads = 0;
            if (wanted) |pages| {
                if (pages == 0) {
                    self.search.phase = .done;
                    self.search.result = .{ .found = 0 };
                    return;
                }
                if (pages > data_end - data_start) {
                    self.search.phase = .done;
                    self.search.result = .no_space;
                    return;
                }
                var tail = @max(self.current.payload_next, self.retained.payload_next);
                if (self.in_transaction) tail = @max(tail, self.staged.payload_next);
                for (&self.readers) |*reader| if (reader.token != 0) {
                    tail = @max(tail, reader.root.payload_next);
                };
                if (pages <= data_end - tail) {
                    self.search.phase = .done;
                    self.search.result = .{ .found = tail };
                    return;
                }
            }
            self.startWindow();
        }
        pub fn beginPayloadSearch(self: *Self, pages: u64) Error!void {
            try self.transaction();
            if (self.writer.token != 0) return error.Busy;
            self.startSearch(pages);
        }
        pub fn beginPayloadSpace(self: *Self) Error!void {
            try self.usable();
            if (self.writer.token != 0) return error.Busy;
            self.startSearch(null);
        }
        fn searchRoot(self: *Self, index: u16) ?*const Root {
            return switch (index) {
                0 => &self.current,
                1 => &self.retained,
                2 => if (self.in_transaction) &self.staged else null,
                else => if (self.readers[index - 3].token != 0) &self.readers[index - 3].root else null,
            };
        }
        /// Work-unit limits, not a wall-clock guarantee. Every root/leaf slot
        /// costs one visit, including cache hits and absent references.
        pub fn stepPayloadSearch(self: *Self, budget: SearchBudget) Error!SearchResult {
            try self.usable();
            if (self.writer.token != 0) return error.Busy;
            if (budget.leaf_visits == 0 or budget.leaf_visits > 64 or budget.bitmap_pages == 0 or budget.bitmap_pages > 4096) return error.InvalidArgument;
            if (self.search.phase == .idle) return error.InvalidSearch;
            self.step_leaf_visits = 0;
            self.step_bitmap_pages = 0;
            while (true) switch (self.search.phase) {
                .idle => unreachable,
                .done => return self.search.result,
                .mark => {
                    if (self.search.root == 3 + @as(u16, config.reader_slots)) {
                        self.search.phase = .scan;
                        continue;
                    }
                    if (self.step_leaf_visits == budget.leaf_visits) return .pending;
                    self.step_leaf_visits += 1;
                    const index = self.search.leaf;
                    const root = self.searchRoot(self.search.root);
                    self.search.leaf += 1;
                    if (self.search.leaf == config.leaf_pages) {
                        self.search.leaf = 0;
                        self.search.root += 1;
                    }
                    if (root) |view| if (view.refs[index].page != 0) try self.markLeaf(view, index);
                },
                .scan => {
                    if (self.search.bit == self.search.end - self.search.start) {
                        if (self.search.end == data_end) {
                            self.search.result = if (self.search.wanted != null) .no_space else .{ .space = self.search.space };
                            self.search.phase = .done;
                        } else {
                            self.search.start = self.search.end;
                            self.startWindow();
                        }
                        continue;
                    }
                    if (self.step_bitmap_pages == budget.bitmap_pages) return .pending;
                    self.step_bitmap_pages += 1;
                    const offset = self.search.bit;
                    self.search.bit += 1;
                    if (self.occupied(offset)) {
                        self.search.run = 0;
                    } else {
                        self.search.run += 1;
                        self.search.space.free_pages += 1;
                        self.search.space.largest_run = @max(self.search.space.largest_run, self.search.run);
                        if (self.search.wanted) |pages| if (self.search.run == pages) {
                            self.search.result = .{ .found = self.search.start + offset + 1 - pages };
                            self.search.phase = .done;
                        };
                    }
                },
            };
        }
        fn findPayload(self: *Self, pages: u64) Error!u64 {
            if (self.search.phase != .done or self.search.wanted != pages) self.startSearch(pages);
            while (true) switch (try self.stepPayloadSearch(.{})) {
                .pending => {},
                .found => |first| return first,
                .no_space => return error.NoSpace,
                .space => unreachable,
            };
        }
        /// Blocking compatibility wrapper. Services should begin/step the scan
        /// themselves and yield between steps before using putPrepared.
        pub fn payloadSpace(self: *Self) Error!PayloadSpace {
            try self.beginPayloadSpace();
            while (true) switch (try self.stepPayloadSearch(.{})) {
                .pending => {},
                .space => |space| return space,
                else => unreachable,
            };
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
            var hit = false;
            if (index < config.leaf_cache_pages) {
                const entry = &self.leaf_cache[index];
                if (entry.ref.page == ref.page and entry.ref.checksum == ref.checksum) {
                    self.cache = entry.bytes;
                    self.metadata_hits +|= 1;
                    hit = true;
                }
            }
            if (!hit) {
                self.metadata_reads +|= 1;
                try self.readPage(ref.page, &self.cache);
            }
            if (!pageValid(&self.cache) or std.mem.readInt(u32, self.cache[crc_offset..][0..4], .little) != ref.checksum or
                std.mem.readInt(u32, self.cache[0..4], .little) != leaf_magic or
                std.mem.readInt(u32, self.cache[4..8], .little) != version or
                std.mem.readInt(u32, self.cache[8..12], .little) != index or
                std.mem.readInt(u32, self.cache[12..16], .little) != 0) return error.Corrupt;
            const leaf_epoch = std.mem.readInt(u64, self.cache[16..24], .little);
            if (leaf_epoch == 0 or leaf_epoch > root.generation) return error.Corrupt;
            for (0..leaf_entries) |i| _ = try decodeEntry(root, self.cache[32 + i * 32 ..][0..32]);
            // Retained/staged variants never evict the current logical leaf.
            // Every hit still passed the CRC, identity and root-bound checks.
            if (!hit and index < config.leaf_cache_pages and self.current.refs[index].page == ref.page and self.current.refs[index].checksum == ref.checksum) {
                self.leaf_cache[index] = .{ .ref = ref, .bytes = self.cache };
            }
        }

        fn lookup(self: *Self, root: *const Root, key: u32) Error!?Value {
            try validKey(key);
            try self.loadLeaf(root, leafIndex(key));
            return decodeEntry(root, self.cache[entryOffset(key)..][0..32]);
        }
        fn checkedLookup(self: *Self, root: *const Root, key: u32) Error!?Value {
            return self.lookup(root, key) catch |err| {
                if (err == error.Corrupt) return self.corruption();
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
            if (self.writer.token != 0) return error.Busy;
            try validKey(key);
            const pages = dataPages(data.len);
            const tables = checksumPages(data.len);
            try self.preflight();
            const first = try self.findPayload(pages + tables);
            return self.putAt(key, data, first);
        }
        /// Consume a completed allocation search without silently doing more
        /// search work. Payload writing itself is still synchronous.
        pub fn putPrepared(self: *Self, key: u32, data: []const u8) Error!void {
            try self.transaction();
            if (self.writer.token != 0) return error.Busy;
            try validKey(key);
            try self.preflight();
            if (self.search.phase != .done or self.search.wanted != dataPages(data.len) + checksumPages(data.len)) return error.SearchRequired;
            const first = switch (self.search.result) {
                .found => |first| first,
                else => return error.SearchRequired,
            };
            return self.putAt(key, data, first);
        }
        fn putAt(self: *Self, key: u32, data: []const u8, first: u64) Error!void {
            self.invalidateSearch();
            const pages = dataPages(data.len);
            const tables = checksumPages(data.len);
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
        fn streamReady(self: *Self, stream: Stream) Error!void {
            try self.transaction();
            if (stream.token == 0 or self.writer.token != stream.token) return error.InvalidStream;
        }
        fn initializeStreamTable(self: *Self) void {
            self.writer.table = @splat(0);
            std.mem.writeInt(u32, self.writer.table[0..4], checksum_magic, .little);
            std.mem.writeInt(u32, self.writer.table[4..8], version, .little);
            std.mem.writeInt(u64, self.writer.table[8..16], self.writer.first, .little);
            std.mem.writeInt(u64, self.writer.table[16..24], self.writer.length, .little);
            std.mem.writeInt(u64, self.writer.table[24..32], self.writer.table_index, .little);
        }
        fn beginStreamAt(self: *Self, key: u32, length: u64, first: u64) Error!Stream {
            if (self.next_stream == std.math.maxInt(u64)) return error.GenerationExhausted;
            _ = try self.checkedLookup(&self.staged, key);
            self.invalidateSearch();
            self.writer = .{ .token = self.next_stream, .key = key, .length = length, .first = first };
            self.next_stream += 1;
            if (length != 0) self.initializeStreamTable();
            return .{ .token = self.writer.token };
        }
        /// Blocking allocation convenience. Only a declaration and reservation;
        /// no caller buffer or pointer is retained.
        pub fn beginStream(self: *Self, key: u32, length: u64) Error!Stream {
            try self.transaction();
            if (self.writer.token != 0) return error.Busy;
            try validKey(key);
            try self.preflight();
            const first = try self.findPayload(dataPages(length) + checksumPages(length));
            return self.beginStreamAt(key, length, first);
        }
        pub fn beginStreamPrepared(self: *Self, key: u32, length: u64) Error!Stream {
            try self.transaction();
            if (self.writer.token != 0) return error.Busy;
            try validKey(key);
            try self.preflight();
            if (self.search.phase != .done or self.search.wanted != dataPages(length) + checksumPages(length)) return error.SearchRequired;
            const first = switch (self.search.result) {
                .found => |first| first,
                else => return error.SearchRequired,
            };
            return self.beginStreamAt(key, length, first);
        }
        fn flushStreamPage(self: *Self) Error!void {
            try self.writePage(self.writer.first + self.writer.page_index, &self.writer.data);
            std.mem.writeInt(u32, self.writer.table[32 + self.writer.table_entries * 4 ..][0..4], std.hash.Crc32.hash(&self.writer.data), .little);
            self.writer.page_index += 1;
            self.writer.table_entries += 1;
            self.writer.fill = 0;
            self.writer.data = @splat(0);
            if (self.writer.table_entries == checksums_per_page or self.writer.page_index == dataPages(self.writer.length)) {
                _ = finishPage(&self.writer.table);
                try self.writePage(self.writer.first + dataPages(self.writer.length) + self.writer.table_index, &self.writer.table);
                self.writer.table_index += 1;
                self.writer.table_entries = 0;
                if (self.writer.page_index < dataPages(self.writer.length)) self.initializeStreamTable();
            }
        }
        fn appendStream(self: *Self, bytes: []const u8) Error!usize {
            if (bytes.len > self.writer.length - self.writer.received) return error.InvalidArgument;
            const n = @min(bytes.len, page_bytes - self.writer.fill);
            const start = self.writer.fill;
            @memcpy(self.writer.data[start..][0..n], bytes[0..n]);
            self.writer.crc.update(self.writer.data[start..][0..n]);
            self.writer.fill += n;
            self.writer.received += n;
            if (self.writer.fill == page_bytes or (self.writer.fill != 0 and self.writer.received == self.writer.length)) try self.flushStreamPage();
            return n;
        }
        /// Accept at most the remainder of one 4 KiB data page. A call issues
        /// at most one payload and one checksum-table write, and performs no sync.
        pub fn writeStream(self: *Self, stream: Stream, bytes: []const u8) Error!usize {
            try self.streamReady(stream);
            if (self.writer.patch != null) return error.InvalidArgument;
            return self.appendStream(bytes);
        }
        pub fn finishStream(self: *Self, stream: Stream) Error!void {
            try self.streamReady(stream);
            if (self.writer.received != self.writer.length) return error.IncompleteStream;
            const existed = try self.checkedLookup(&self.staged, self.writer.key) != null;
            const value = Value{ .first = if (self.writer.length == 0) 0 else self.writer.first, .length = self.writer.length, .checksum = self.writer.crc.final() };
            if (self.writer.length != 0) self.staged.payload_next = @max(self.staged.payload_next, self.writer.first + dataPages(self.writer.length) + checksumPages(self.writer.length));
            try self.replace(self.writer.key, value, existed);
            self.writer.token = 0;
        }
        pub fn abortStream(self: *Self, stream: Stream) Error!void {
            try self.streamReady(stream);
            self.writer.token = 0;
            self.invalidateSearch();
        }
        fn patchSource(self: *Self, key: u32, offset: u64, length: u64) Error!Value {
            try self.transaction();
            if (self.writer.token != 0) return error.Busy;
            const source = try self.checkedLookup(&self.staged, key) orelse return error.NotFound;
            if (offset > source.length or length > source.length - offset) return error.InvalidArgument;
            return source;
        }
        /// Fixed-length byte-range replacement. Current contiguous extents
        /// require copying the complete object; this is not range sharing.
        pub fn beginPatch(self: *Self, key: u32, offset: u64, length: u64) Error!Stream {
            const source = try self.patchSource(key, offset, length);
            const stream = try self.beginStream(key, source.length);
            self.writer.patch = .{ .source = source, .offset = offset, .length = length };
            return stream;
        }
        pub fn beginPatchPrepared(self: *Self, key: u32, offset: u64, length: u64) Error!Stream {
            const source = try self.patchSource(key, offset, length);
            const stream = try self.beginStreamPrepared(key, source.length);
            self.writer.patch = .{ .source = source, .offset = offset, .length = length };
            return stream;
        }
        /// Copy one source-page fragment or accept one replacement fragment.
        /// Prefix/suffix copying may return consumed=0 without needing input.
        pub fn stepPatch(self: *Self, stream: Stream, replacement: []const u8) Error!PatchProgress {
            try self.streamReady(stream);
            const patch = self.writer.patch orelse return error.InvalidArgument;
            const position = self.writer.received;
            if (position == self.writer.length) return .{ .done = true };
            const room = page_bytes - self.writer.fill;
            const patch_end = patch.offset + patch.length;
            if (position >= patch.offset and position < patch_end) {
                if (replacement.len == 0) return .{ .need_input = true };
                const n: usize = @intCast(@min(@min(replacement.len, room), patch_end - position));
                const consumed = try self.appendStream(replacement[0..n]);
                return .{ .consumed = consumed, .done = self.writer.received == self.writer.length };
            }
            const until = if (position < patch.offset) patch.offset else self.writer.length;
            const n: usize = @intCast(@min(room, until - position));
            var bytes: [page_bytes]u8 = undefined;
            if (try self.readValue(patch.source, position, bytes[0..n]) != n) return self.corruption();
            _ = try self.appendStream(bytes[0..n]);
            return .{ .done = self.writer.received == self.writer.length };
        }
        pub fn remove(self: *Self, key: u32) Error!void {
            try self.transaction();
            if (self.writer.token != 0) return error.Busy;
            try validKey(key);
            try self.preflight();
            self.invalidateSearch();
            if (try self.checkedLookup(&self.staged, key) == null) return error.NotFound;
            try self.replace(key, null, true);
        }
        pub fn commit(self: *Self) Error!void {
            try self.transaction();
            if (self.writer.token != 0) return error.Busy;
            self.invalidateSearch();
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
            self.invalidateSearch();
            self.writer.token = 0;
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
