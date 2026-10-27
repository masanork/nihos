//! Host-only paged-index experiment. Every transaction publishes a checkpoint;
//! Index and payload pages are reclaimed by reachability without relocation.
//! There is no replay log. Payload checksums are verified on demand.
const std = @import("std");
pub const extent_map = @import("extent_map.zig");
pub const page_bytes = 4096;
pub const crc_offset = page_bytes - 4;
pub const leaf_entries = (crc_offset - 32) / 32;
pub const root_magic: u32 = 0x4e494332;
pub const leaf_magic: u32 = 0x4e494c32;
pub const version: u32 = extent_map.version;
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
pub const Kind = enum(u32) { blob, mapped };
pub const Value = struct { first: u64, length: u64, checksum: u32, kind: Kind = .blob, high_water: u64 = 0 };
pub const Reader = struct { slot: u8, token: u64 };
pub const Stream = struct { token: u64 };
pub const MapScratch = struct { nodes: [extent_map.max_height + 1][page_bytes]u8 = @splat(@splat(0)) };
pub const ResizeScratch = MapScratch;
pub const max_mapped_batch_pages = 16;
pub const MappedPatch = struct { offset: u64, bytes: []const u8 };
pub const PatchProgress = struct { consumed: usize = 0, done: bool = false, need_input: bool = false };
pub const IndexSpace = struct { capacity_pages: u32, protected_pages: u32, available_pages: u32 };
pub const PayloadSpace = struct { usable_pages: u64, reserved_pages: u32, free_pages: u64, largest_run: u64 };
pub const Error = error{ Io, Corrupt, Unformatted, Faulted, NotReady, Busy, NoTransaction, NoSpace, NotFound, InvalidArgument, GenerationExhausted, ReaderLimit, InvalidReader, InvalidSearch, SearchRequired, InvalidStream, IncompleteStream, NotMapped };

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
        const MapFrame = struct { ref: extent_map.Ref, base: u64, level: u8, next: u16 = 0 };
        const MapCache = struct { valid: bool = false, root: u64 = 0, checksum: u32 = 0, length: u64 = 0, base: u64 = 0, ref: extent_map.Ref = .{} };
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
            phase: enum { idle, mark, objects, tree, scan, done } = .idle,
            wanted: ?u64 = null,
            result: SearchResult = .pending,
            start: u64 = data_start,
            end: u64 = data_start,
            root: u16 = 0,
            leaf: u16 = 0,
            bit: u32 = 0,
            run: u64 = 0,
            view_root: u16 = 0,
            entry: u16 = 0,
            mapped: Value = .{ .first = 0, .length = 0, .checksum = 0 },
            frames: [extent_map.max_height + 1]MapFrame = @splat(.{ .ref = .{}, .base = 0, .level = 0 }),
            depth: u8 = 0,
            space: PayloadSpace = .{ .usable_pages = data_end - data_start, .reserved_pages = config.payload_reserve_pages, .free_pages = 0, .largest_run = 0 },
        };
        pub const capacity_bytes = Device.capacity;
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
        map_buffer: [page_bytes]u8 = @splat(0),
        map_cache: MapCache = .{},
        map_reads: u64 = 0,
        map_hits: u64 = 0,
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
            if (self.map_cache.ref.page == page) self.map_cache.valid = false;
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
            // Searches exclude an active stream. Hold this immutable object
            // leaf across tree steps; ordinary reads never use writer.table.
            self.writer.table = self.cache;
            self.search.entry = 0;
            self.search.phase = .objects;
        }
        fn markObjects(self: *Self) Error!void {
            const root = self.searchRoot(self.search.view_root) orelse return self.corruption();
            while (self.search.entry < leaf_entries) {
                const entry = self.search.entry;
                self.search.entry += 1;
                const value = try decodeEntry(root, self.writer.table[32 + entry * 32 ..][0..32]) orelse continue;
                if (value.length == 0) continue;
                if (value.kind == .mapped) {
                    self.search.mapped = value;
                    self.search.depth = 1;
                    self.search.frames[0] = .{ .ref = .{ .page = value.first, .checksum = value.checksum }, .base = 0, .level = try extent_map.height(value.length) };
                    self.search.phase = .tree;
                    return;
                }
                const last = value.first + dataPages(value.length) + checksumPages(value.length);
                const first_overlap = @max(self.search.start, value.first);
                const last_overlap = @min(self.search.end, last);
                if (first_overlap < last_overlap) self.markRange(@intCast(first_overlap - self.search.start), @intCast(last_overlap - self.search.start));
            }
            self.search.phase = .mark;
        }
        fn markPhysicalPage(self: *Self, page: u64) void {
            if (page >= self.search.start and page < self.search.end) self.markRange(@intCast(page - self.search.start), @intCast(page + 1 - self.search.start));
        }
        fn markTreeStep(self: *Self) Error!void {
            const frame = &self.search.frames[self.search.depth - 1];
            const ref = try self.loadMap(frame.ref, frame.level, frame.base, self.search.mapped);
            self.markPhysicalPage(ref.page);
            const count = try extent_map.count(frame.level, frame.base, self.search.mapped.length);
            if (frame.level == 0) {
                for (0..count) |i| self.markPhysicalPage(extent_map.data(&self.map_buffer, i).page);
                self.search.depth -= 1;
            } else {
                while (frame.next < count) {
                    const index = frame.next;
                    frame.next += 1;
                    const child = extent_map.child(&self.map_buffer, index);
                    if (!child.data.intersects(self.search.start, self.search.end) and !child.nodes.intersects(self.search.start, self.search.end)) continue;
                    self.search.frames[self.search.depth] = .{ .ref = child, .level = frame.level - 1, .base = frame.base + index * extent_map.capacity(frame.level - 1) };
                    self.search.depth += 1;
                    return;
                }
                self.search.depth -= 1;
            }
            if (self.search.depth == 0) self.search.phase = .objects;
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
            self.map_cache.valid = false;
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
                    self.search.view_root = self.search.root;
                    const root = self.searchRoot(self.search.root);
                    self.search.leaf += 1;
                    if (self.search.leaf == config.leaf_pages) {
                        self.search.leaf = 0;
                        self.search.root += 1;
                    }
                    if (root) |view| if (view.refs[index].page != 0) try self.markLeaf(view, index);
                },
                .objects => try self.markObjects(),
                .tree => {
                    if (self.step_leaf_visits == budget.leaf_visits) return .pending;
                    self.step_leaf_visits += 1;
                    try self.markTreeStep();
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
            const kind_number = std.mem.readInt(u32, bytes[28..32], .little);
            if (std.mem.readInt(u32, bytes[4..8], .little) != 0 or kind_number > 1) return error.Corrupt;
            const kind: Kind = @fromBackingInt(@intCast(kind_number));
            if (state == 0) {
                if (first != 0 or length != 0 or checksum != 0 or kind != .blob) return error.Corrupt;
                return null;
            }
            if (state != 1) return error.Corrupt;
            if (length == 0) {
                if (first != 0 or checksum != 0 or kind != .blob) return error.Corrupt;
            } else if (kind == .mapped) {
                _ = try extent_map.height(length);
                if (root.payload_next > std.math.maxInt(u32) or first < data_start or first >= root.payload_next) return error.Corrupt;
            } else {
                const pages = dataPages(length) + checksumPages(length);
                if (first < data_start or first > root.payload_next or pages > root.payload_next - first) return error.Corrupt;
            }
            return .{ .first = first, .length = length, .checksum = checksum, .kind = kind, .high_water = root.payload_next };
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
                std.mem.writeInt(u32, self.cache[offset + 28 ..][0..4], @backingInt(item.kind), .little);
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
        fn loadMap(self: *Self, ref: extent_map.Ref, level: u8, base: u64, value: Value) Error!extent_map.Ref {
            self.map_cache.valid = false;
            self.map_reads +|= 1;
            try self.readPage(ref.page, &self.map_buffer);
            return extent_map.validate(&self.map_buffer, ref, level, base, value.length, .{ .start = data_start, .end = value.high_water }) catch return self.corruption();
        }
        fn mapPath(self: *Self, value: Value, logical: u64, path: *[extent_map.max_height + 1]extent_map.Ref) Error!extent_map.Data {
            path.* = @splat(.{});
            var level = extent_map.height(value.length) catch return self.corruption();
            var base: u64 = 0;
            var ref = extent_map.Ref{ .page = value.first, .checksum = value.checksum };
            while (true) {
                if (ref.page == 0) return .{ .page = 0, .checksum = 0 };
                ref = try self.loadMap(ref, level, base, value);
                path[level] = ref;
                if (level == 0) {
                    self.map_cache = .{ .valid = true, .root = value.first, .checksum = value.checksum, .length = value.length, .base = base, .ref = ref };
                    return extent_map.data(&self.map_buffer, @intCast(logical - base));
                }
                const index = (logical - base) / extent_map.capacity(level - 1);
                ref = extent_map.child(&self.map_buffer, @intCast(index));
                base += index * extent_map.capacity(level - 1);
                level -= 1;
            }
        }
        fn mappedData(self: *Self, value: Value, logical: u64) Error!extent_map.Data {
            if (self.map_cache.valid and self.map_cache.root == value.first and self.map_cache.checksum == value.checksum and self.map_cache.length == value.length and
                logical >= self.map_cache.base and logical - self.map_cache.base < extent_map.leaf_entries)
            {
                _ = extent_map.validate(&self.map_buffer, self.map_cache.ref, 0, self.map_cache.base, value.length, .{ .start = data_start, .end = value.high_water }) catch return self.corruption();
                self.map_hits +|= 1;
                return extent_map.data(&self.map_buffer, @intCast(logical - self.map_cache.base));
            }
            var path: [extent_map.max_height + 1]extent_map.Ref = undefined;
            return self.mapPath(value, logical, &path);
        }
        fn readMapped(self: *Self, value: Value, offset: u64, destination: []u8) Error!usize {
            if (offset >= value.length or destination.len == 0) return 0;
            const n: usize = @intCast(@min(destination.len, value.length - offset));
            var position: usize = 0;
            var buffer: [page_bytes]u8 = undefined;
            while (position < n) {
                const logical = offset + position;
                const ref = try self.mappedData(value, logical / page_bytes);
                if (ref.page == 0) buffer = @splat(0) else {
                    try self.readPage(ref.page, &buffer);
                    if (std.hash.Crc32.hash(&buffer) != ref.checksum) return self.corruption();
                }
                const within: usize = @intCast(logical % page_bytes);
                const count = @min(page_bytes - within, n - position);
                @memcpy(destination[position..][0..count], buffer[within..][0..count]);
                position += count;
            }
            return n;
        }
        pub fn mapMetadataPages(length: u64) Error!u64 {
            if (length == 0) return 0;
            const height = extent_map.height(length) catch return error.InvalidArgument;
            var total: u64 = 0;
            for (0..@as(usize, height) + 1) |level| {
                const capacity = extent_map.capacity(@intCast(level));
                const count = dataPages(length) / capacity + @intFromBool(dataPages(length) % capacity != 0);
                total += count;
            }
            return total;
        }
        pub fn promoteMapped(self: *Self, key: u32) Error!void {
            try self.transaction();
            if (self.writer.token != 0) return error.Busy;
            const source = try self.checkedLookup(&self.staged, key) orelse return error.NotFound;
            if (source.kind == .mapped or source.length == 0) return;
            if (data_end > std.math.maxInt(u32)) return error.InvalidArgument;
            try self.preflight();
            const total = try mapMetadataPages(source.length);
            const first = try self.findPayload(total);
            self.invalidateSearch();
            self.map_cache.valid = false;
            const height = try extent_map.height(source.length);
            const bound = @max(self.staged.payload_next, first + total);
            const limits = extent_map.Limits{ .start = data_start, .end = bound };
            var offsets: [extent_map.max_height + 1]u64 = @splat(0);
            var cursor: u64 = 0;
            var root = extent_map.Ref{};
            var loaded_table: ?u64 = null;
            for (0..@as(usize, height) + 1) |level_index| {
                const level: u8 = @intCast(level_index);
                offsets[level] = cursor;
                const capacity = extent_map.capacity(level);
                const nodes = dataPages(source.length) / capacity + @intFromBool(dataPages(source.length) % capacity != 0);
                for (0..@intCast(nodes)) |node| {
                    const base = node * capacity;
                    try extent_map.init(&self.map_buffer, level, base, source.length);
                    const used = try extent_map.count(level, base, source.length);
                    for (0..used) |i| {
                        if (level == 0) {
                            const logical = base + i;
                            const table = logical / checksums_per_page;
                            if (loaded_table != table) {
                                try self.readPage(source.first + dataPages(source.length) + table, &self.writer.table);
                                if (!pageValid(&self.writer.table) or std.mem.readInt(u32, self.writer.table[0..4], .little) != checksum_magic or
                                    std.mem.readInt(u32, self.writer.table[4..8], .little) != version or
                                    std.mem.readInt(u64, self.writer.table[8..16], .little) != source.first or
                                    std.mem.readInt(u64, self.writer.table[16..24], .little) != source.length or
                                    std.mem.readInt(u64, self.writer.table[24..32], .little) != table) return self.corruption();
                                loaded_table = table;
                            }
                            const entry: usize = @intCast(logical % checksums_per_page);
                            extent_map.setData(&self.map_buffer, i, .{ .page = source.first + logical, .checksum = std.mem.readInt(u32, self.writer.table[32 + entry * 4 ..][0..4], .little) });
                        } else {
                            const physical = first + offsets[level - 1] + node * extent_map.children + i;
                            try self.readPage(physical, &self.writer.table);
                            const expected = extent_map.Ref{ .page = physical, .checksum = std.mem.readInt(u32, self.writer.table[crc_offset..][0..4], .little) };
                            const child_base = base + i * extent_map.capacity(level - 1);
                            const ref = extent_map.validate(&self.writer.table, expected, level - 1, child_base, source.length, limits) catch return self.corruption();
                            extent_map.setChild(&self.map_buffer, i, ref);
                        }
                    }
                    const physical = first + cursor;
                    root = extent_map.seal(&self.map_buffer, physical, level, base, source.length, limits) catch return self.corruption();
                    try self.writePage(physical, &self.map_buffer);
                    cursor += 1;
                }
            }
            self.staged.payload_next = bound;
            _ = try self.checkedLookup(&self.staged, key);
            try self.replace(key, .{ .first = root.page, .length = source.length, .checksum = root.checksum, .kind = .mapped }, true);
        }
        pub fn mappedPatchPages(length: u64) Error!u64 {
            return 2 + @as(u64, extent_map.height(length) catch return error.InvalidArgument);
        }
        fn mappedSource(self: *Self, key: u32, offset: u64, bytes: []const u8) Error!Value {
            try self.transaction();
            if (self.writer.token != 0) return error.Busy;
            const value = try self.checkedLookup(&self.staged, key) orelse return error.NotFound;
            if (value.kind != .mapped) return error.NotMapped;
            if (bytes.len == 0 or offset >= value.length or bytes.len > value.length - offset or bytes.len > page_bytes - offset % page_bytes) return error.InvalidArgument;
            try self.preflight();
            return value;
        }
        pub fn patchMappedPage(self: *Self, key: u32, offset: u64, bytes: []const u8) Error!void {
            const value = try self.mappedSource(key, offset, bytes);
            const first = try self.findPayload(try mappedPatchPages(value.length));
            return self.patchMappedAt(key, offset, bytes, value, first);
        }
        pub fn patchMappedPagePrepared(self: *Self, key: u32, offset: u64, bytes: []const u8) Error!void {
            const value = try self.mappedSource(key, offset, bytes);
            if (self.search.phase != .done or self.search.wanted != try mappedPatchPages(value.length)) return error.SearchRequired;
            const first = switch (self.search.result) {
                .found => |first| first,
                else => return error.SearchRequired,
            };
            return self.patchMappedAt(key, offset, bytes, value, first);
        }
        fn patchMappedAt(self: *Self, key: u32, offset: u64, bytes: []const u8, value: Value, first: u64) Error!void {
            self.invalidateSearch();
            var path: [extent_map.max_height + 1]extent_map.Ref = undefined;
            const logical = offset / page_bytes;
            const original = try self.mapPath(value, logical, &path);
            if (original.page == 0) self.writer.data = @splat(0) else {
                try self.readPage(original.page, &self.writer.data);
                if (std.hash.Crc32.hash(&self.writer.data) != original.checksum) return self.corruption();
            }
            const within: usize = @intCast(offset % page_bytes);
            @memcpy(self.writer.data[within..][0..bytes.len], bytes);
            const data_crc = std.hash.Crc32.hash(&self.writer.data);
            try self.writePage(first, &self.writer.data);
            const height = try extent_map.height(value.length);
            const bound = @max(self.staged.payload_next, first + try mappedPatchPages(value.length));
            var updated = extent_map.Ref{};
            for (0..@as(usize, height) + 1) |level_index| {
                const level: u8 = @intCast(level_index);
                const base = logical / extent_map.capacity(level) * extent_map.capacity(level);
                if (path[level].page == 0) {
                    self.map_cache.valid = false;
                    try extent_map.init(&self.map_buffer, level, base, value.length);
                } else _ = try self.loadMap(path[level], level, base, value);
                if (level == 0) extent_map.setData(&self.map_buffer, @intCast(logical - base), .{ .page = first, .checksum = data_crc }) else {
                    const index = (logical - base) / extent_map.capacity(level - 1);
                    extent_map.setChild(&self.map_buffer, @intCast(index), updated);
                }
                updated = extent_map.seal(&self.map_buffer, first + 1 + level, level, base, value.length, .{ .start = data_start, .end = bound }) catch return self.corruption();
                try self.writePage(updated.page, &self.map_buffer);
            }
            self.staged.payload_next = bound;
            _ = try self.checkedLookup(&self.staged, key);
            try self.replace(key, .{ .first = updated.page, .length = value.length, .checksum = updated.checksum, .kind = .mapped }, true);
        }
        /// Patches are nonempty, ordered by logical page, with at most one
        /// patch per page. The caller owns the slices until this call returns.
        pub fn mappedBatchPages(length: u64, patches: []const MappedPatch) Error!u64 {
            if (patches.len == 0 or patches.len > max_mapped_batch_pages) return error.InvalidArgument;
            const height = extent_map.height(length) catch return error.InvalidArgument;
            var previous: ?u64 = null;
            for (patches) |patch| {
                if (patch.bytes.len == 0 or patch.offset >= length or patch.bytes.len > length - patch.offset or
                    patch.bytes.len > page_bytes - patch.offset % page_bytes) return error.InvalidArgument;
                const logical = patch.offset / page_bytes;
                if (previous) |prior| if (logical <= prior) return error.InvalidArgument;
                previous = logical;
            }
            var pages: u64 = patches.len;
            for (0..@as(usize, height) + 1) |level| {
                previous = null;
                for (patches) |patch| {
                    const node = patch.offset / page_bytes / extent_map.capacity(@intCast(level));
                    if (previous == null or previous.? != node) pages += 1;
                    previous = node;
                }
            }
            return pages;
        }
        fn mappedBatchSource(self: *Self, key: u32, patches: []const MappedPatch) Error!Value {
            try self.transaction();
            if (self.writer.token != 0) return error.Busy;
            const value = try self.checkedLookup(&self.staged, key) orelse return error.NotFound;
            if (value.kind != .mapped) return error.NotMapped;
            _ = try mappedBatchPages(value.length, patches);
            try self.preflight();
            return value;
        }
        pub fn patchMappedBatch(self: *Self, key: u32, patches: []const MappedPatch, scratch: *MapScratch) Error!void {
            const value = try self.mappedBatchSource(key, patches);
            const first = try self.findPayload(try mappedBatchPages(value.length, patches));
            return self.patchBatchAt(key, patches, scratch, value, first);
        }
        pub fn patchMappedBatchPrepared(self: *Self, key: u32, patches: []const MappedPatch, scratch: *MapScratch) Error!void {
            const value = try self.mappedBatchSource(key, patches);
            if (self.search.phase != .done or self.search.wanted != try mappedBatchPages(value.length, patches)) return error.SearchRequired;
            const first = switch (self.search.result) {
                .found => |first| first,
                else => return error.SearchRequired,
            };
            return self.patchBatchAt(key, patches, scratch, value, first);
        }
        fn patchBatchNode(self: *Self, value: Value, patches: []const MappedPatch, checksums: *const [max_mapped_batch_pages]u32, start: usize, end: usize, level: u8, base: u64, original: extent_map.Ref, first: u64, cursor: *u64, bound: u64, scratch: *MapScratch) Error!extent_map.Ref {
            const node = &scratch.nodes[level];
            if (original.page == 0) try extent_map.init(node, level, base, value.length) else {
                _ = try self.loadMap(original, level, base, value);
                node.* = self.map_buffer;
            }
            if (level == 0) {
                for (start..end) |i| extent_map.setData(node, @intCast(patches[i].offset / page_bytes - base), .{ .page = first + i, .checksum = checksums[i] });
            } else {
                var i = start;
                while (i < end) {
                    const index = (patches[i].offset / page_bytes - base) / extent_map.capacity(level - 1);
                    var next = i + 1;
                    while (next < end and (patches[next].offset / page_bytes - base) / extent_map.capacity(level - 1) == index) next += 1;
                    const old_child = extent_map.child(node, @intCast(index));
                    const updated = try self.patchBatchNode(value, patches, checksums, i, next, level - 1, base + index * extent_map.capacity(level - 1), old_child, first, cursor, bound, scratch);
                    extent_map.setChild(node, @intCast(index), updated);
                    i = next;
                }
            }
            self.map_cache.valid = false;
            const updated = extent_map.seal(node, first + cursor.*, level, base, value.length, .{ .start = data_start, .end = bound }) catch return self.corruption();
            try self.writePage(updated.page, node);
            cursor.* += 1;
            return updated;
        }
        fn patchBatchAt(self: *Self, key: u32, patches: []const MappedPatch, scratch: *MapScratch, value: Value, first: u64) Error!void {
            self.invalidateSearch();
            const pages = try mappedBatchPages(value.length, patches);
            const bound = @max(self.staged.payload_next, first + pages);
            var checksums: [max_mapped_batch_pages]u32 = undefined;
            for (patches, 0..) |patch, i| {
                const original = try self.mappedData(value, patch.offset / page_bytes);
                if (original.page == 0) self.writer.data = @splat(0) else {
                    try self.readPage(original.page, &self.writer.data);
                    if (std.hash.Crc32.hash(&self.writer.data) != original.checksum) return self.corruption();
                }
                const within: usize = @intCast(patch.offset % page_bytes);
                @memcpy(self.writer.data[within..][0..patch.bytes.len], patch.bytes);
                checksums[i] = std.hash.Crc32.hash(&self.writer.data);
                try self.writePage(first + i, &self.writer.data);
            }
            var cursor: u64 = patches.len;
            const updated = try self.patchBatchNode(value, patches, &checksums, 0, patches.len, try extent_map.height(value.length), 0, .{ .page = value.first, .checksum = value.checksum }, first, &cursor, bound, scratch);
            if (cursor != pages) return self.corruption();
            self.staged.payload_next = bound;
            _ = try self.checkedLookup(&self.staged, key);
            try self.replace(key, .{ .first = updated.page, .length = value.length, .checksum = updated.checksum, .kind = .mapped }, true);
        }
        const ResizePlan = struct {
            source: Value,
            length: u64,
            height: u8 = 0,
            old_level: u8 = 0,
            old_ref: extent_map.Ref = .{},
            tail: ?u64 = null,
            original_tail: extent_map.Data = .{ .page = 0, .checksum = 0 },
            pages: u64 = 0,
        };
        fn subtree(self: *Self, value: Value, target: u8) Error!extent_map.Ref {
            var level = try extent_map.height(value.length);
            var ref = extent_map.Ref{ .page = value.first, .checksum = value.checksum };
            while (level > target and ref.page != 0) {
                _ = try self.loadMap(ref, level, 0, value);
                ref = extent_map.child(&self.map_buffer, 0);
                level -= 1;
            }
            return ref;
        }
        fn reshapeNode(self: *Self, comptime write: bool, plan: *const ResizePlan, old_ref: extent_map.Ref, old_level: u8, level: u8, base: u64, force_root: bool, tail_ref: extent_map.Data, first: u64, cursor: *u64, bound: u64, scratch: *ResizeScratch) Error!extent_map.Ref {
            const tail_inside = if (plan.tail) |logical| logical >= base and logical - base < extent_map.capacity(level) else false;
            if (old_ref.page == 0 and !tail_inside and !force_root) return .{};
            const new_coverage = @min(extent_map.capacity(level), dataPages(plan.length) - base);
            const old_coverage = if (base < dataPages(plan.source.length)) @min(extent_map.capacity(level), dataPages(plan.source.length) - base) else 0;
            if (old_ref.page != 0 and old_level == level and old_coverage == new_coverage and !tail_inside) return old_ref;
            const node = &scratch.nodes[level];
            var old_count: usize = 0;
            if (old_ref.page != 0 and old_level == level) {
                _ = try self.loadMap(old_ref, level, base, plan.source);
                node.* = self.map_buffer;
                old_count = try extent_map.count(level, base, plan.source.length);
            } else try extent_map.init(node, level, base, plan.length);
            const new_count = try extent_map.count(level, base, plan.length);
            if (level == 0) {
                if (write and tail_inside) extent_map.setData(node, @intCast(plan.tail.? - base), tail_ref);
            } else {
                for (0..new_count) |i| {
                    const child_ref = if (old_ref.page != 0 and old_level == level and i < old_count) extent_map.child(node, i) else if (old_level < level and i == 0) old_ref else extent_map.Ref{};
                    const child_level = if (old_level < level and i == 0) old_level else level - 1;
                    const child_base = base + i * extent_map.capacity(level - 1);
                    const updated = try self.reshapeNode(write, plan, child_ref, child_level, level - 1, child_base, false, tail_ref, first, cursor, bound, scratch);
                    if (write) extent_map.setChild(node, i, updated);
                }
            }
            var result = extent_map.Ref{};
            if (write) {
                const stride: usize = if (level == 0) 16 else 32;
                @memset(node[extent_map.header_bytes + new_count * stride .. crc_offset], 0);
                try extent_map.setHeader(node, level, base, plan.length);
                result = extent_map.seal(node, first + cursor.*, level, base, plan.length, .{ .start = data_start, .end = bound }) catch return self.corruption();
                try self.writePage(result.page, node);
            }
            cursor.* += 1;
            return result;
        }
        fn resizePlan(self: *Self, key: u32, length: u64, scratch: *ResizeScratch) Error!ResizePlan {
            try self.transaction();
            if (self.writer.token != 0) return error.Busy;
            const source = try self.checkedLookup(&self.staged, key) orelse return error.NotFound;
            if (length > Device.capacity or data_end > std.math.maxInt(u32)) return error.InvalidArgument;
            var plan = ResizePlan{ .source = source, .length = length };
            if (length == source.length or length == 0) return plan;
            if (source.kind != .mapped and source.length != 0) return error.NotMapped;
            plan.height = extent_map.height(length) catch return error.InvalidArgument;
            if (source.length != 0) {
                const old_height = try extent_map.height(source.length);
                plan.old_level = @min(old_height, plan.height);
                plan.old_ref = if (old_height > plan.height) try self.subtree(source, plan.height) else .{ .page = source.first, .checksum = source.checksum };
                if (plan.old_ref.page != 0) plan.old_ref = try self.loadMap(plan.old_ref, plan.old_level, 0, source);
                const edge = @min(length, source.length);
                if (edge % page_bytes != 0) {
                    const logical = edge / page_bytes;
                    const original = try self.mappedData(source, logical);
                    if (original.page != 0) {
                        plan.tail = logical;
                        plan.original_tail = original;
                    }
                }
            }
            var count: u64 = 0;
            _ = try self.reshapeNode(false, &plan, plan.old_ref, plan.old_level, plan.height, 0, true, .{ .page = 0, .checksum = 0 }, 0, &count, 0, scratch);
            plan.pages = count + @intFromBool(plan.tail != null);
            return plan;
        }
        /// Caller owns a fixed 16 KiB metadata workspace. This planning pass
        /// reads only boundary paths, and performs no writes or allocation scan.
        pub fn mappedResizePages(self: *Self, key: u32, length: u64, scratch: *ResizeScratch) Error!u64 {
            return (try self.resizePlan(key, length, scratch)).pages;
        }
        pub fn resizeMapped(self: *Self, key: u32, length: u64, scratch: *ResizeScratch) Error!void {
            const plan = try self.resizePlan(key, length, scratch);
            if (length == plan.source.length) return;
            try self.preflight();
            const first = try self.findPayload(plan.pages);
            return self.applyResize(key, &plan, first, scratch);
        }
        pub fn resizeMappedPrepared(self: *Self, key: u32, length: u64, scratch: *ResizeScratch) Error!void {
            const plan = try self.resizePlan(key, length, scratch);
            if (length == plan.source.length) return;
            try self.preflight();
            if (self.search.phase != .done or self.search.wanted != plan.pages) return error.SearchRequired;
            const first = switch (self.search.result) {
                .found => |first| first,
                else => return error.SearchRequired,
            };
            return self.applyResize(key, &plan, first, scratch);
        }
        fn applyResize(self: *Self, key: u32, plan: *const ResizePlan, first: u64, scratch: *ResizeScratch) Error!void {
            self.invalidateSearch();
            self.map_cache.valid = false;
            if (plan.length == 0) {
                _ = try self.checkedLookup(&self.staged, key);
                return self.replace(key, .{ .first = 0, .length = 0, .checksum = 0 }, true);
            }
            const bound = @max(self.staged.payload_next, first + plan.pages);
            var cursor: u64 = 0;
            var tail = extent_map.Data{ .page = 0, .checksum = 0 };
            if (plan.tail != null) {
                try self.readPage(plan.original_tail.page, &self.writer.data);
                if (std.hash.Crc32.hash(&self.writer.data) != plan.original_tail.checksum) return self.corruption();
                const edge: usize = @intCast(@min(plan.length, plan.source.length) % page_bytes);
                @memset(self.writer.data[edge..], 0);
                tail = .{ .page = first, .checksum = std.hash.Crc32.hash(&self.writer.data) };
                try self.writePage(first, &self.writer.data);
                cursor += 1;
            }
            const root = try self.reshapeNode(true, plan, plan.old_ref, plan.old_level, plan.height, 0, true, tail, first, &cursor, bound, scratch);
            if (cursor != plan.pages or root.page == 0) return self.corruption();
            self.staged.payload_next = bound;
            _ = try self.checkedLookup(&self.staged, key);
            try self.replace(key, .{ .first = root.page, .length = plan.length, .checksum = root.checksum, .kind = .mapped }, true);
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

        /// Exclusive-owner view of unpublished mutations; not a public reader
        /// capability and never an assertion of durability.
        pub fn getStaged(self: *Self, key: u32) Error!Value {
            try self.transaction();
            return try self.checkedLookup(&self.staged, key) orelse error.NotFound;
        }
        pub fn readStaged(self: *Self, key: u32, offset: u64, destination: []u8) Error!usize {
            return self.readValue(try self.getStaged(key), offset, destination);
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
            if (value.kind == .mapped) return self.readMapped(value, offset, destination);
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
            if (value.kind == .mapped) {
                var buffer: [page_bytes]u8 = undefined;
                var position: u64 = 0;
                while (position < value.length) position += try self.readMapped(value, position, &buffer);
                return;
            }
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
