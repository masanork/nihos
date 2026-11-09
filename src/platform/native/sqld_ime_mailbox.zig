//! One copied request between the trusted foreground and the serialized sqld
//! owner. The caller must drain every submitted request before closing a pin.
const std = @import("std");
pub const page_bytes = 4096;
// Keys 1-3 are SQLite/namespace and 32-47 are named files. This key is
// reserved for a dictionary provisioned by a future explicit migration.
pub const dictionary_key: u32 = 64;
pub const Request = extern struct { operation: u32 = 0, sequence: u32 = 0, offset: u64 = 0, length: u32 = 0 };
pub const Response = extern struct {
    request: Request = .{},
    status: i32 = 0,
    size: u64 = 0,
    length: u32 = 0,
    bytes: [page_bytes]u8 = @splat(0),
};
pub const Mailbox = struct {
    // Only the producer writes request and consumes response; only the owner
    // uses the backend, pin and response until it publishes phase 2.
    phase: std.atomic.Value(u32) = .init(0),
    sequence: u32 = 0,
    request: Request = .{},
    response: Response = .{},
    pin: u32 = 0,
    size: u64 = 0,

    pub fn submit(self: *Mailbox, req: *Request) i32 {
        if (self.phase.load(.acquire) != 0) return -16;
        if (self.sequence == std.math.maxInt(u32)) return -7;
        if (req.operation < 1 or req.operation > 3) return -22;
        self.sequence += 1;
        req.sequence = self.sequence;
        self.request = req.*;
        self.phase.store(1, .release);
        return 0;
    }
    pub fn take(self: *Mailbox, out: *Response) i32 {
        if (self.phase.load(.acquire) != 2) return 0;
        out.* = self.response;
        self.phase.store(0, .release);
        return 1;
    }
    /// Called only by the sqld owner. Backend methods are synchronous and
    /// must finish using the response buffer before returning.
    pub fn service(self: *Mailbox, backend: anytype, available: bool) bool {
        if (self.phase.load(.acquire) != 1) return false;
        const q = self.request;
        self.response = .{ .request = q };
        if (!available) {
            self.response.status = -19;
        } else switch (q.operation) {
            1 => {
                if (self.pin != 0 or q.offset != 0 or q.length != 0) {
                    self.response.status = -16;
                } else {
                    var pin: u32 = 0;
                    var size: u64 = 0;
                    const rc = backend.pin(dictionary_key, &pin, &size);
                    self.response.status = rc;
                    if (rc == 0) {
                        self.pin = pin;
                        self.size = size;
                        self.response.size = size;
                    }
                }
            },
            2 => {
                if (self.pin == 0 or q.offset % page_bytes != 0 or q.offset >= self.size or
                    q.length != @min(page_bytes, self.size - q.offset))
                {
                    self.response.status = -22;
                } else {
                    const n = backend.read(self.pin, q.offset, self.response.bytes[0..q.length]);
                    if (n < 0) self.response.status = n else if (n != q.length) {
                        self.response.status = -5;
                    } else self.response.length = q.length;
                    if (self.response.status != 0) @memset(&self.response.bytes, 0);
                }
            },
            3 => {
                if (self.pin == 0 or q.offset != 0 or q.length != 0) {
                    self.response.status = -22;
                } else {
                    const rc = backend.release(self.pin);
                    self.response.status = rc;
                    if (rc == 0) {
                        self.pin = 0;
                        self.size = 0;
                    }
                }
            },
            else => unreachable,
        }
        self.phase.store(2, .release);
        return true;
    }
};

test "mailbox copies and serializes a dictionary pin, read and release" {
    const Backend = struct {
        fn pin(_: @This(), key: u32, token: *u32, size: *u64) i32 {
            if (key != dictionary_key) return -22;
            token.* = 7;
            size.* = 3;
            return 0;
        }
        fn read(_: @This(), token: u32, offset: u64, out: []u8) i32 {
            if (token != 7 or offset != 0) return -22;
            @memcpy(out, "old");
            return 3;
        }
        fn release(_: @This(), token: u32) i32 {
            return if (token == 7) 0 else -22;
        }
    };
    var box: Mailbox = .{};
    const backend = Backend{};
    var q = Request{ .operation = 1 };
    var r: Response = .{};
    try std.testing.expectEqual(@as(i32, 0), box.submit(&q));
    try std.testing.expectEqual(@as(i32, -16), box.submit(&q));
    try std.testing.expectEqual(@as(i32, 0), box.take(&r));
    q.operation = 3; // A later caller edit does not mutate the queued copy.
    try std.testing.expect(box.service(backend, true));
    try std.testing.expectEqual(@as(i32, 1), box.take(&r));
    try std.testing.expectEqual(@as(u32, 1), r.request.operation);
    try std.testing.expectEqual(@as(u64, 3), r.size);
    q = .{ .operation = 2, .length = 3 };
    try std.testing.expectEqual(@as(i32, 0), box.submit(&q));
    try std.testing.expect(box.service(backend, true));
    try std.testing.expectEqual(@as(i32, 1), box.take(&r));
    try std.testing.expectEqual(q.sequence, r.request.sequence);
    try std.testing.expectEqualStrings("old", r.bytes[0..r.length]);
    q = .{ .operation = 3 };
    try std.testing.expectEqual(@as(i32, 0), box.submit(&q));
    try std.testing.expect(box.service(backend, true));
    try std.testing.expectEqual(@as(i32, 1), box.take(&r));
    try std.testing.expectEqual(@as(i32, 0), r.status);
    try std.testing.expectEqual(@as(u32, 0), box.pin);
}

test "mailbox rejects invalid pages and completes unavailable requests" {
    const Backend = struct {
        fn pin(_: @This(), _: u32, token: *u32, size: *u64) i32 {
            token.* = 1;
            size.* = 5;
            return 0;
        }
        fn read(_: @This(), _: u32, _: u64, out: []u8) i32 {
            out[0] = 0xa5;
            return -5;
        }
        fn release(_: @This(), _: u32) i32 {
            return 0;
        }
    };
    var box: Mailbox = .{};
    var q = Request{ .operation = 1 };
    var r: Response = .{};
    try std.testing.expectEqual(@as(i32, 0), box.submit(&q));
    try std.testing.expect(box.service(Backend{}, true));
    _ = box.take(&r);
    q = .{ .operation = 2, .length = 4 };
    try std.testing.expectEqual(@as(i32, 0), box.submit(&q));
    try std.testing.expect(box.service(Backend{}, true));
    _ = box.take(&r);
    try std.testing.expectEqual(@as(i32, -22), r.status);
    q = .{ .operation = 2, .length = 5 };
    try std.testing.expectEqual(@as(i32, 0), box.submit(&q));
    try std.testing.expect(box.service(Backend{}, true));
    _ = box.take(&r);
    try std.testing.expectEqual(@as(i32, -5), r.status);
    try std.testing.expectEqual(@as(u32, 0), r.length);
    for (r.bytes) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    q = .{ .operation = 3 };
    try std.testing.expectEqual(@as(i32, 0), box.submit(&q));
    try std.testing.expect(box.service(Backend{}, false));
    _ = box.take(&r);
    try std.testing.expectEqual(@as(i32, -19), r.status);
    try std.testing.expectEqual(@as(u32, 1), box.pin);
}
