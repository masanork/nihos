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
