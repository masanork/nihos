//! Host-only bridge from the workspace IME to a serialized pinned checkpoint
//! reader. Queue slots contain copies; caller must ensure cross-core memory,
//! cache and device/DMA lifetime before using this design on native hardware.
const std = @import("std");
const ring = @import("../kernel/spsc_ring.zig");
const model = @import("../storage/checkpoint_model.zig");
const pages = @import("../storage/async_page.zig");
const Runtime = @import("async_ime_session.zig").Runtime;

pub const Response = struct {
    request: pages.Request = .{ .generation = 0, .serial = 0, .offset = 0, .length = 0 },
    ok: bool = false,
    length: usize = 0,
    bytes: [pages.page_bytes]u8 = @splat(0),
};
pub const Queues = struct {
    requests: ring.SpscRing(pages.Request, 2) = .init(),
    responses: ring.SpscRing(Response, 2) = .init(),
};

extern fn nih_store_pin_object(*anyopaque, u32, *u32, *u64) callconv(.c) c_int;
extern fn nih_store_read_object(*anyopaque, u32, u64, [*]u8, usize) callconv(.c) c_int;
extern fn nih_store_release(*anyopaque, u32) callconv(.c) c_int;

/// Adapter for the serialized store-owner ABI. All methods must run on the
/// store owner, on the same mount, and never concurrently with other store use.
/// A Reader here is an internal wrapper for a mount-local ABI token, not a
/// client capability. Keep this adapter alive until Owner.close has drained.
pub const AbiStore = struct {
    raw: *anyopaque,
    token: u32 = 0,
    key: u32 = 0,
    length: u64 = 0,

    pub fn pinObject(self: *AbiStore, key: u32) !model.Reader {
        if (self.token != 0 or key == 0) return error.Busy;
        var token: u32 = 0;
        var length: u64 = 0;
        if (nih_store_pin_object(self.raw, key, &token, &length) != 0) return error.Io;
        self.token = token;
        self.key = key;
        self.length = length;
        return .{ .slot = 0, .token = token };
    }
    fn valid(self: *const AbiStore, reader: model.Reader, key: u32) bool {
        return self.token != 0 and reader.slot == 0 and reader.token == self.token and key == self.key;
    }
    pub fn getPinned(self: *AbiStore, reader: model.Reader, key: u32) !model.Value {
        if (!self.valid(reader, key)) return error.InvalidReader;
        return .{ .first = 0, .length = self.length, .checksum = 0 };
    }
    pub fn readPinnedWithScratch(self: *AbiStore, reader: model.Reader, key: u32, offset: u64, out: []u8, _: *[pages.page_bytes]u8) !usize {
        if (!self.valid(reader, key)) return error.InvalidReader;
        const result = nih_store_read_object(self.raw, self.token, offset, out.ptr, out.len);
        if (result < 0) return error.Io;
        return @intCast(result);
    }
    pub fn release(self: *AbiStore, reader: model.Reader) !void {
        if (!self.valid(reader, self.key)) return error.InvalidReader;
        if (nih_store_release(self.raw, self.token) != 0) return error.Io;
        self.token = 0;
        self.key = 0;
        self.length = 0;
    }
};

/// One owner serializes every access to Store. readPinned is synchronous on
/// this owner; step is not a time bound and is not an SD or DMA driver.
pub fn Owner(comptime Store: type) type {
    return struct {
        const Self = @This();
        store: *Store,
        pin: model.Reader,
        key: u32,
        length: u64,
        epoch: u64,
        next_serial: u64 = 1,
        running: bool = true,
        in_step: bool = false,
        response: Response = .{},
        scratch: [pages.page_bytes]u8 = @splat(0),

        /// Trusted caller admits an immutable committed object and binds one
        /// coordinator generation. No client-supplied object key is accepted.
        pub fn init(store: *Store, key: u32, epoch: u64) !Self {
            if (key == 0 or epoch == 0) return error.InvalidArgument;
            const pin = try store.pinObject(key);
            const value = store.getPinned(pin, key) catch |err| {
                try store.release(pin);
                return err;
            };
            return .{ .store = store, .pin = pin, .key = key, .length = value.length, .epoch = epoch };
        }
        pub fn step(self: *Self, queues: *Queues) bool {
            if (!self.running or self.in_step or queues.responses.countApprox() == 2) return false;
            const req = queues.requests.tryPop() orelse return false;
            self.in_step = true;
            defer self.in_step = false;
            self.response = .{ .request = req };
            if (req.generation == self.epoch and req.serial != 0 and req.serial == self.next_serial and
                req.offset % pages.page_bytes == 0 and req.offset < self.length and
                req.length == @min(pages.page_bytes, self.length - req.offset))
            {
                self.next_serial +%= 1;
                const n = self.store.readPinnedWithScratch(self.pin, self.key, req.offset, self.response.bytes[0..req.length], &self.scratch) catch 0;
                if (n == req.length) {
                    self.response.ok = true;
                    self.response.length = n;
                }
            }
            if (!queues.responses.tryPushFrom(&self.response)) unreachable;
            return true;
        }
        /// Trusted caller must first stop the sole client and drain both queues.
        /// Backend return is assumed to mean its buffer use has ended.
        pub fn close(self: *Self, queues: *const Queues, client_stopped: bool) !void {
            if (!client_stopped or !self.running or self.in_step or queues.requests.countApprox() != 0 or queues.responses.countApprox() != 0) return error.Busy;
            try self.store.release(self.pin);
            self.running = false;
        }
    };
}

/// Single workspace owner; only the exact outstanding response may reach the
/// page coordinator. Duplicate and stale replies are discarded as copies.
pub const Client = struct {
    inflight: ?pages.Request = null,
    response: Response = .{},
    discarded: usize = 0,
    pub fn submit(self: *Client, runtime: *const Runtime, queues: *Queues) bool {
        if (self.inflight != null) return false;
        const req = runtime.request() orelse return false;
        if (!queues.requests.tryPush(req)) return false;
        self.inflight = req;
        return true;
    }
    pub fn poll(self: *Client, runtime: *Runtime, queues: *Queues) !bool {
        if (!queues.responses.tryPopInto(&self.response)) return false;
        const req = self.inflight orelse {
            self.discarded += 1;
            return true;
        };
        if (!std.meta.eql(req, self.response.request)) {
            self.discarded += 1;
            return true;
        }
        self.inflight = null;
        const bytes: ?[]const u8 = if (self.response.ok and self.response.length == req.length) self.response.bytes[0..req.length] else null;
        try runtime.supply(req, bytes);
        return true;
    }
    pub fn drained(self: *const Client) bool {
        return self.inflight == null;
    }
};

test "pinned queue reads the original object and drains before close" {
    const Media = @import("../storage/model_media.zig").Media(1024 * 1024);
    const Store = model.Store(Media, .{ .leaf_pages = 2, .index_pages = 8 });
    var media: Media = .{};
    var store: Store = .{};
    try store.format(&media);
    try store.begin();
    try store.put(1, "old");
    try store.commit();
    var owner = try Owner(Store).init(&store, 1, 7);
    try store.begin();
    try store.put(1, "new");
    try store.commit();
    var queues: Queues = .{};
    const req: pages.Request = .{ .generation = 7, .serial = 1, .offset = 0, .length = 3 };
    try std.testing.expect(queues.requests.tryPush(req));
    try std.testing.expectError(error.Busy, owner.close(&queues, true));
    try std.testing.expect(owner.step(&queues));
    try std.testing.expectError(error.Busy, owner.close(&queues, true));
    var reply: Response = .{};
    try std.testing.expect(queues.responses.tryPopInto(&reply));
    try std.testing.expect(reply.ok);
    try std.testing.expectEqualStrings("old", reply.bytes[0..reply.length]);
    try std.testing.expectError(error.Busy, owner.close(&queues, false));
    try owner.close(&queues, true);
    try std.testing.expectError(error.InvalidReader, store.getPinned(owner.pin, 1));
}

test "pinned queue rejects old or forged page tickets without reading" {
    const Media = @import("../storage/model_media.zig").Media(1024 * 1024);
    const Store = model.Store(Media, .{ .leaf_pages = 2, .index_pages = 8 });
    var media: Media = .{};
    var store: Store = .{};
    try store.format(&media);
    try store.begin();
    try store.put(1, "abc");
    try store.commit();
    var owner = try Owner(Store).init(&store, 1, 7);
    var queues: Queues = .{};
    try std.testing.expect(queues.requests.tryPush(.{ .generation = 6, .serial = 1, .offset = 0, .length = 3 }));
    try std.testing.expect(owner.step(&queues));
    var reply: Response = .{};
    try std.testing.expect(queues.responses.tryPopInto(&reply));
    try std.testing.expect(!reply.ok);
    try std.testing.expectEqual(@as(usize, 0), reply.length);
    try std.testing.expect(queues.requests.tryPush(.{ .generation = 7, .serial = 1, .offset = 0, .length = 3 }));
    try std.testing.expect(owner.step(&queues));
    try std.testing.expect(queues.responses.tryPopInto(&reply));
    try std.testing.expect(reply.ok);
    try std.testing.expectEqualStrings("abc", reply.bytes[0..reply.length]);
    try owner.close(&queues, true);
}

test "ABI-backed queue retains an object across replacement and drains" {
    const store_abi = @import("../storage/store_abi.zig");
    const Media = struct {
        bytes: []u8,
        fail_reads: bool = false,
        fn read(ctx: ?*anyopaque, off: u64, out: [*]u8, n: usize) callconv(.c) c_int {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            if (self.fail_reads) return -1;
            if (off > self.bytes.len or n > self.bytes.len - @as(usize, @intCast(off))) return -1;
            @memcpy(out[0..n], self.bytes[@intCast(off)..][0..n]);
            return 0;
        }
        fn write(ctx: ?*anyopaque, off: u64, data: [*]const u8, n: usize) callconv(.c) c_int {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            if (off > self.bytes.len or n > self.bytes.len - @as(usize, @intCast(off))) return -1;
            @memcpy(self.bytes[@intCast(off)..][0..n], data[0..n]);
            return 0;
        }
        fn sync(_: ?*anyopaque) callconv(.c) c_int {
            return 0;
        }
    };
    const Callbacks = extern struct {
        context: ?*anyopaque,
        read: *const fn (?*anyopaque, u64, [*]u8, usize) callconv(.c) c_int,
        write: *const fn (?*anyopaque, u64, [*]const u8, usize) callconv(.c) c_int,
        sync: *const fn (?*anyopaque) callconv(.c) c_int,
    };
    const allocator = std.testing.allocator;
    const memory = try allocator.alloc(u8, 4 * 1024 * 1024);
    defer allocator.free(memory);
    @memset(memory, 0xff);
    var media = Media{ .bytes = memory };
    const storage = try allocator.alignedAlloc(u8, .@"16", store_abi.nih_store_size());
    defer allocator.free(storage);
    const raw: *anyopaque = @ptrCast(storage.ptr);
    const callbacks = Callbacks{ .context = &media, .read = Media.read, .write = Media.write, .sync = Media.sync };
    try std.testing.expectEqual(@as(c_int, 0), store_abi.nih_store_mount(raw, storage.len, @ptrCast(&callbacks), 1));
    try std.testing.expectEqual(@as(c_int, 0), store_abi.nih_store_create(raw, 17));
    try std.testing.expectEqual(@as(c_int, 0), store_abi.nih_store_write(raw, 17, 0, "old", 3));
    try std.testing.expectEqual(@as(c_int, 0), store_abi.nih_store_sync(raw));
    var adapter = AbiStore{ .raw = raw };
    var owner = try Owner(AbiStore).init(&adapter, 17, 9);
    try std.testing.expectEqual(@as(c_int, 0), store_abi.nih_store_write(raw, 17, 0, "new", 3));
    try std.testing.expectEqual(@as(c_int, 0), store_abi.nih_store_sync(raw));
    var queues: Queues = .{};
    try std.testing.expect(queues.requests.tryPush(.{ .generation = 9, .serial = 1, .offset = 0, .length = 3 }));
    try std.testing.expectError(error.Busy, owner.close(&queues, true));
    try std.testing.expect(owner.step(&queues));
    var result: Response = .{};
    try std.testing.expect(queues.responses.tryPopInto(&result));
    try std.testing.expect(result.ok);
    try std.testing.expectEqualStrings("old", result.bytes[0..result.length]);
    try std.testing.expect(queues.requests.tryPush(.{ .generation = 8, .serial = 2, .offset = 0, .length = 3 }));
    try std.testing.expect(owner.step(&queues));
    try std.testing.expect(queues.responses.tryPopInto(&result));
    try std.testing.expect(!result.ok);
    media.fail_reads = true;
    try std.testing.expect(queues.requests.tryPush(.{ .generation = 9, .serial = 2, .offset = 0, .length = 3 }));
    try std.testing.expect(owner.step(&queues));
    try std.testing.expect(queues.responses.tryPopInto(&result));
    try std.testing.expect(!result.ok and result.length == 0);
    media.fail_reads = false;
    const old_token = adapter.token;
    try owner.close(&queues, true);
    var byte: [1]u8 = undefined;
    try std.testing.expectEqual(@as(c_int, -22), store_abi.nih_store_read_object(raw, old_token, 0, &byte, 1));

    // Exercise the workspace through the real ABI with the small bundled NFST.
    // A failed read fences the store; recover it before starting another job.
    try std.testing.expectEqual(@as(c_int, 0), store_abi.nih_store_mount(raw, storage.len, @ptrCast(&callbacks), 0));
    const dict = @embedFile("fixtures/jisyo_s_nfst.bin");
    try std.testing.expectEqual(@as(c_int, 0), store_abi.nih_store_create(raw, 18));
    var offset: usize = 0;
    while (offset < dict.len) {
        const amount = @min(4096, dict.len - offset);
        try std.testing.expectEqual(@as(c_int, 0), store_abi.nih_store_write(raw, 18, offset, dict[offset..][0..amount].ptr, amount));
        offset += amount;
    }
    try std.testing.expectEqual(@as(c_int, 0), store_abi.nih_store_sync(raw));
    var page: pages.Coordinator = .{};
    try page.attach(1, dict.len);
    var dictionary_owner = try Owner(AbiStore).init(&adapter, 18, page.generation);
    var client: Client = .{};
    var converter = @import("async_conversion.zig").Adapter{ .coordinator = &page };
    var runtime = Runtime{ .adapter = &converter };
    const port = runtime.port();
    var workspace: @import("scratch.zig").Model = undefined;
    workspace.initInPlace();
    workspace.ime.mode = .hiragana;
    try std.testing.expect(workspace.attachAsyncIme(&port));
    for ("kanji") |ch| workspace.handle(.{ .text = ch });
    workspace.handle(.{ .text = ' ' });
    var steps: usize = 0;
    while (port.busy(port.context)) {
        steps += 1;
        try std.testing.expect(steps < 100000);
        workspace.pollAsyncIme(128);
        _ = client.submit(&runtime, &queues);
        _ = dictionary_owner.step(&queues);
        _ = try client.poll(&runtime, &queues);
    }
    try std.testing.expectEqualStrings("漢字", workspace.doc.preedit.slice());
    workspace.handle(.enter);
    try std.testing.expectEqualStrings("漢字", workspace.doc.slice());
    try std.testing.expect(workspace.detachAsyncIme());
    try page.detach();
    try dictionary_owner.close(&queues, client.drained());
}
