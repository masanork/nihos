const std = @import("std");
const wire = @import("hosted.zig");
const info = @import("hosted_c6_ota_info.zig");
const exchange = @import("hosted_c6_ota_info_exchange.zig");

const Fake = struct {
    pending: [512]u8 = @splat(0),
    used: usize = 0,
    version: [3]u32 = .{ 3, 0, 10 },
    reject: bool = false,
    silence: bool = false,
    ack_only: bool = false,
    no_credit: bool = false,
    partial: bool = false,
    custom_count: u32 = 0,
    bt_count: u32 = 0,
    fn enqueue(self: *Fake, id: u32, uid: u32, kind: u8, body: []const u8) !void {
        var b: [160]u8 = undefined;
        const msg = try wire.request(&b, id, uid, body);
        b[13] = kind;
        if (kind == 3) @memcpy(b[3..9], "RPCEvt");
        var frame: [200]u8 = undefined;
        const bytes = try wire.frame(&frame, 3, 0, msg);
        @memcpy(self.pending[self.used..][0..bytes.len], bytes);
        self.used += bytes.len;
    }
    pub fn send(self: *Fake, frame: []const u8) !usize {
        if (self.no_credit) {
            self.no_credit = false;
            return 0;
        }
        if (self.partial) return frame.len - 1;
        if (frame[0] == 5) return frame.len;
        var r: wire.Reader = .{ .bytes = frame[24..] };
        var id: u32 = 0;
        var uid: u32 = 0;
        var body: ?[]const u8 = null;
        while (try r.next()) |f| {
            if (f.number == 2) id = @intCast(f.value);
            if (f.number == 3) uid = @intCast(f.value);
            if (f.number >= 256) body = f.bytes;
        }
        var bytes: [100]u8 = undefined;
        var w: wire.Writer = .{ .out = &bytes };
        switch (id) {
            350 => {
                try w.uint(2, self.version[0]);
                try w.uint(3, self.version[1]);
                try w.uint(4, self.version[2]);
            },
            387 => {
                self.bt_count += 1;
                try w.uint(2, 1);
                try w.uint(3, if (self.bt_count == 1) 1 else 3);
            },
            388 => {
                self.custom_count += 1;
                try std.testing.expectEqual(info.request_id, try wire.integer(body.?, 1));
                if (self.silence) return frame.len;
                if (self.reject) try w.uint(1, 0x105);
            },
            else => return error.UnexpectedPersistentOrOtherRpc,
        }
        try self.enqueue(id + 256, uid, 2, w.slice());
        if (id == 388 and !self.reject and !self.ack_only) {
            w = .{ .out = &bytes };
            try w.uint(2, info.result_id);
            try w.data(3, @embedFile("fixtures/hosted-ota-info-v1.bin"));
            try self.enqueue(788, 1, 3, w.slice());
        }
        return frame.len;
    }
    pub fn receive(self: *Fake, destination: []u8) !usize {
        const count = self.used;
        @memcpy(destination[0..count], self.pending[0..count]);
        self.used = 0;
        return count;
    }
};
fn setup(f: *Fake, major3: bool) !exchange.Exchange {
    f.used = (try wire.frame(&f.pending, 5, 0, if (major3) @embedFile("fixtures/hosted-3.0.10-init.bin") else &.{ 0x22, 3, 0x12, 1, 13 })).len;
    return try exchange.Exchange.init(0x12345678, 0, 100);
}
test "handshake and query complete on 3.0.10 with a no-credit retry" {
    var f: Fake = .{ .no_credit = true };
    var x = try setup(&f, true);
    var guarded = exchange.ReadOnlyStream(Fake){ .inner = &f };
    var t: u64 = 1;
    while (x.state != .complete and t < 90) : (t += 1) try x.step(&guarded, t);
    try std.testing.expectEqual(exchange.State.complete, x.state);
    try std.testing.expectEqual(@as(u32, 1), f.custom_count);
    try std.testing.expectEqual(@as(u32, 0x190000), x.query.result.?.next.offset);
}
test "read-only physical stream rejects every OTA and other custom RPC" {
    const Sink = struct {
        sent: usize = 0,
        pub fn send(self: *@This(), b: []const u8) !usize {
            self.sent += 1;
            return b.len;
        }
        pub fn receive(_: *@This(), _: []u8) !usize {
            return 0;
        }
    };
    var sink: Sink = .{};
    var guarded = exchange.ReadOnlyStream(Sink){ .inner = &sink };
    var payload: [128]u8 = undefined;
    var frame: [160]u8 = undefined;
    for ([_]u32{ 266, 272, 273, 274, 256, 3500 }) |id| {
        const rpc = try wire.request(&payload, id, 1, &.{});
        try std.testing.expectError(error.Forbidden, guarded.send(try wire.frame(&frame, 3, 0, rpc)));
    }
    var body: [32]u8 = undefined;
    var w: wire.Writer = .{ .out = &body };
    try w.uint(1, 42);
    try w.data(2, &.{1});
    const rpc = try wire.request(&payload, 388, 1, w.slice());
    try std.testing.expectError(error.Forbidden, guarded.send(try wire.frame(&frame, 3, 0, rpc)));
    try std.testing.expectError(error.Forbidden, guarded.send(try wire.frame(&frame, 5, 0, &.{ 0x22, 3, 0x21, 1, 2 })));
    try std.testing.expectEqual(@as(usize, 0), sink.sent);
}
test "2.13.1 missing service rejects and never reports a snapshot" {
    var f: Fake = .{ .version = .{ 2, 13, 1 }, .reject = true };
    var x = try setup(&f, false);
    var result: ?anyerror = null;
    for (1..90) |t| x.step(&f, t) catch |err| {
        result = err;
        break;
    };
    try std.testing.expectEqual(error.Rejected, result.?);
    try std.testing.expectEqual(@as(?u32, 0x105), x.ack_status);
    try std.testing.expectEqual(exchange.State.failed, x.state);
    try std.testing.expect(x.query.result == null);
}
test "silent or partial transport fails without repeating the query" {
    var f: Fake = .{ .silence = true };
    var x = try setup(&f, true);
    var t: u64 = 1;
    while (x.state != .waiting and t < 90) : (t += 1) try x.step(&f, t);
    try std.testing.expectError(error.Timeout, x.step(&f, 100));
    try std.testing.expectEqual(@as(u32, 1), f.custom_count);
    f = .{};
    x = try setup(&f, true);
    f.partial = true;
    try std.testing.expectError(error.PartialPacket, x.step(&f, 1));
    try std.testing.expectEqual(exchange.State.failed, x.state);
}
test "successful acknowledgement without a result still times out" {
    var f: Fake = .{ .ack_only = true };
    var x = try setup(&f, true);
    var t: u64 = 1;
    while (x.state != .waiting and t < 90) : (t += 1) try x.step(&f, t);
    try x.step(&f, t);
    try std.testing.expectEqual(@as(?u32, 0), x.ack_status);
    try std.testing.expect(x.query.acknowledged);
    try std.testing.expectError(error.Timeout, x.step(&f, 100));
    try std.testing.expect(x.query.result == null);
    try std.testing.expectEqual(@as(u32, 1), f.custom_count);
}
