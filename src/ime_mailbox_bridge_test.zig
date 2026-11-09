const std = @import("std");
const wire = @import("platform/native/sqld_ime_mailbox.zig");
const Bridge = @import("xy/ime_mailbox_bridge.zig").Bridge;
const Model = @import("xy/scratch.zig").Model;
const dictionary = @embedFile("xy/fixtures/jisyo_s_nfst.bin");
const Backend = struct {
    box: wire.Mailbox = .{},
    missing: bool = false,
    busy_read: bool = false,
    fail_read: bool = false,
    pub fn submit(self: *@This(), q: *wire.Request) i32 {
        if (self.busy_read and q.operation == 2) return -16;
        return self.box.submit(q);
    }
    pub fn take(self: *@This(), r: *wire.Response) i32 {
        return self.box.take(r);
    }
    pub fn pin(self: *@This(), key: u32, token: *u32, size: *u64) i32 {
        if (self.missing) return -2;
        if (key != wire.dictionary_key) return -22;
        token.* = 7;
        size.* = dictionary.len;
        return 0;
    }
    pub fn read(self: *@This(), token: u32, offset: u64, out: []u8) i32 {
        if (self.fail_read) return -5;
        if (token != 7 or offset > dictionary.len or out.len > dictionary.len - @as(usize, @intCast(offset))) return -22;
        @memcpy(out, dictionary[@intCast(offset)..][0..out.len]);
        return @intCast(out.len);
    }
    pub fn release(_: *@This(), token: u32) i32 {
        return if (token == 7) 0 else -22;
    }
    fn pump(self: *@This()) void {
        _ = self.box.service(self, true);
    }
};
fn tick(bridge: *Bridge, model: *Model, backend: *Backend) !void {
    try std.testing.expect(bridge.poll(model, backend, 128));
    backend.pump();
}
test "workspace converts through copied mailbox and drains cancellation" {
    var model: Model = undefined;
    model.initInPlace();
    model.ime.mode = .hiragana;
    var backend: Backend = .{};
    var bridge: Bridge = Bridge.init();
    try std.testing.expectEqual(@as(i32, 0), bridge.open(&backend));
    for (0..10) |_| {
        try tick(&bridge, &model, &backend);
        if (bridge.phase == .active) break;
    }
    try std.testing.expectEqual(Bridge.Phase.active, bridge.phase);
    for ("kanji") |ch| model.handle(.{ .text = ch });
    model.handle(.{ .text = ' ' });
    var steps: usize = 0;
    while (bridge.port.busy(bridge.port.context)) {
        steps += 1;
        try std.testing.expect(steps < 100000);
        try tick(&bridge, &model, &backend);
    }
    try std.testing.expectEqualStrings("漢字", model.doc.preedit.slice());
    model.handle(.enter);
    try std.testing.expectEqualStrings("漢字", model.doc.slice());
    for ("nihon") |ch| model.handle(.{ .text = ch });
    model.handle(.{ .text = ' ' });
    for (0..10000) |_| {
        try std.testing.expect(bridge.poll(&model, &backend, 128));
        if (bridge.phase == .reading) break;
        backend.pump();
    }
    try std.testing.expectEqual(Bridge.Phase.reading, bridge.phase);
    model.handle(.{ .text = 'a' });
    bridge.stop(&model);
    try std.testing.expectEqual(Bridge.Phase.reading, bridge.phase);
    backend.pump();
    for (0..20) |_| {
        try tick(&bridge, &model, &backend);
        if (bridge.phase == .closed) break;
    }
    try std.testing.expectEqual(Bridge.Phase.closed, bridge.phase);
    try std.testing.expect(model.async_ime == null);
    try std.testing.expectEqual(@as(u32, 0), backend.box.pin);
    try std.testing.expectEqualStrings("にほんあ", model.doc.preedit.slice());
}
test "missing dictionary preserves builtin input" {
    var model: Model = undefined;
    model.initInPlace();
    model.ime.mode = .hiragana;
    var backend = Backend{ .missing = true };
    var bridge: Bridge = Bridge.init();
    try std.testing.expectEqual(@as(i32, 0), bridge.open(&backend));
    for (0..10) |_| try tick(&bridge, &model, &backend);
    try std.testing.expectEqual(Bridge.Phase.closed, bridge.phase);
    try std.testing.expect(model.async_ime == null);
    for ("kanji ") |ch| model.handle(.{ .text = ch });
    try std.testing.expectEqualStrings("漢字", model.doc.preedit.slice());
}
test "cancelled unsent page and failed page both drain" {
    for ([_]bool{ false, true }) |fail_read| {
        var model: Model = undefined;
        model.initInPlace();
        model.ime.mode = .hiragana;
        var backend = Backend{ .busy_read = !fail_read, .fail_read = fail_read };
        var bridge: Bridge = Bridge.init();
        try std.testing.expectEqual(@as(i32, 0), bridge.open(&backend));
        for (0..10) |_| {
            try tick(&bridge, &model, &backend);
            if (bridge.phase == .active) break;
        }
        for ("kanji ") |ch| model.handle(.{ .text = ch });
        for (0..10000) |_| {
            try tick(&bridge, &model, &backend);
            if (fail_read and bridge.stopping) break;
            if (!fail_read and bridge.runtime.request() != null) {
                bridge.stop(&model);
                break;
            }
        }
        try std.testing.expect(bridge.stopping);
        for (0..20) |_| {
            try tick(&bridge, &model, &backend);
            if (bridge.phase == .closed) break;
        }
        try std.testing.expectEqual(Bridge.Phase.closed, bridge.phase);
        try std.testing.expect(model.async_ime == null);
        try std.testing.expectEqual(@as(u32, 0), backend.box.pin);
    }
}
test "shutdown during open releases the pin before touching the workspace" {
    var model: Model = undefined;
    model.initInPlace();
    var backend: Backend = .{};
    var bridge: Bridge = Bridge.init();
    try std.testing.expectEqual(@as(i32, 0), bridge.open(&backend));
    bridge.stop(&model);
    for (0..20) |_| {
        try tick(&bridge, &model, &backend);
        if (bridge.phase == .closed) break;
    }
    try std.testing.expectEqual(Bridge.Phase.closed, bridge.phase);
    try std.testing.expect(model.async_ime == null);
    try std.testing.expectEqual(@as(u32, 0), backend.box.pin);
}
test "mismatched completion fences the pin" {
    var model: Model = undefined;
    model.initInPlace();
    var backend: Backend = .{};
    var bridge: Bridge = Bridge.init();
    try std.testing.expectEqual(@as(i32, 0), bridge.open(&backend));
    backend.pump();
    backend.box.response.request.sequence += 1;
    try std.testing.expect(!bridge.poll(&model, &backend, 128));
    try std.testing.expectEqual(Bridge.Phase.fenced, bridge.phase);
    try std.testing.expectEqual(@as(u32, 7), backend.box.pin);
    try std.testing.expect(model.async_ime == null);
}
