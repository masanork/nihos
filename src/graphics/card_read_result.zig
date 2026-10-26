//! Ephemeral card overview and legacy page renderer. No strings leave the device.
const std = @import("std");
const screen = @import("card_pin.zig");
const input = @import("../card/input_support.zig");
fn Store(comptime section: ?[]const u8) type {
    return if (section) |name| struct {
        const data: [@embedFile("card_read_font.bin").len]u8 align(64) linksection(name) = @embedFile("card_read_font.bin").*;
    } else struct {
        const data: [@embedFile("card_read_font.bin").len]u8 align(64) = @embedFile("card_read_font.bin").*;
    };
}
fn code(bytes: []const u8) u32 {
    return std.mem.readInt(u32, bytes[0..4], .little);
}
fn glyph(comptime section: ?[]const u8, value: u21) ?[]const u8 {
    const data = &Store(section).data;
    var low: usize = 0;
    var high: usize = data.len / 36;
    while (low < high) {
        const mid = low + (high - low) / 2;
        const found = code(data[mid * 36 ..]);
        if (found < value) low = mid + 1 else high = mid;
    }
    if (low == data.len / 36 or code(data[low * 36 ..]) != value) return null;
    return data[low * 36 + 4 ..][0..32];
}
const Canvas = struct {
    frame: []u8,
    fn character(self: Canvas, comptime section: ?[]const u8, value: u21, x: usize, y: usize) bool {
        return self.sized(section, value, x, y, 32);
    }
    fn sized(self: Canvas, comptime section: ?[]const u8, value: u21, x: usize, y: usize, size: usize) bool {
        const selected = glyph(section, value);
        const bits = selected orelse glyph(section, 0x25a1).?;
        for (0..size) |row| for (0..size) |column| {
            const original_y = row * 16 / size;
            const original_x = column * 16 / size;
            if (bits[original_y * 2 + original_x / 8] & (@as(u8, 128) >> @as(u3, @intCast(original_x % 8))) == 0) continue;
            if (x + column >= 720 or y + row >= 1280) continue;
            const offset = ((y + row) * 720 + x + column) * 2;
            std.mem.writeInt(u16, self.frame[offset..][0..2], 0x2125, .little);
        };
        return selected != null;
    }
    inline fn wrapped(self: Canvas, comptime section: ?[]const u8, value: []const u8, x: usize, y: usize, size: usize, columns: usize, lines: usize) !Paint {
        var iterator = (try std.unicode.Utf8View.init(value)).iterator();
        var report = Paint{};
        while (iterator.nextCodepoint()) |item| {
            if (report.shown == columns * lines) {
                report.truncated = true;
                break;
            }
            if (!self.sized(section, item, x + report.shown % columns * size, y + report.shown / columns * (size + 8), size)) report.missing += 1;
            report.shown += 1;
        }
        if (report.truncated) _ = self.sized(section, 0x2026, x + (columns - 1) * size, y + (lines - 1) * (size + 8), size);
        return report;
    }
    fn text(self: Canvas, comptime section: ?[]const u8, value: []const u8, x: usize, y: usize) void {
        var iterator = (std.unicode.Utf8View.init(value) catch return).iterator();
        var column: usize = 0;
        while (iterator.nextCodepoint()) |item| : (column += 1) _ = self.character(section, item, x + column * 32, y);
    }
};
pub const Pager = struct {
    field: u8 = 0,
    offset: usize = 0,
    next_offset: usize = 0,
    more: bool = false,
    pub fn next(self: *Pager) bool {
        if (self.more) self.offset = self.next_offset else {
            self.offset = 0;
            self.field += 1;
        }
        return self.field < 4;
    }
};
pub const Paint = struct { missing: u32 = 0, shown: u32 = 0, truncated: bool = false };
pub fn result(comptime section: ?[]const u8, frame: []u8, attributes: input.Attributes, pager: *Pager) !Paint {
    if (frame.len != 720 * 1280 * 2 or pager.field >= 4) return error.Invalid;
    for (0..frame.len / 2) |i| std.mem.writeInt(u16, frame[i * 2 ..][0..2], screen.paper_color, .little);
    const canvas = Canvas{ .frame = frame };
    canvas.text(section, "券面情報の読取結果", 24, 110);
    canvas.text(section, "署名検証は未実施", 24, 170);
    const labels = [_][]const u8{ "氏名", "住所", "生年月日", "性別（記録値）" };
    const values = [_][]const u8{ attributes.name, attributes.address, attributes.birth_date, attributes.gender };
    canvas.text(section, labels[pager.field], 24, 300);
    const value = values[pager.field];
    if (pager.offset > value.len or !std.unicode.utf8ValidateSlice(value[pager.offset..])) return error.Invalid;
    var iterator = (try std.unicode.Utf8View.init(value[pager.offset..])).iterator();
    var report = Paint{};
    while (report.shown < 84) {
        const item = iterator.nextCodepoint() orelse break;
        if (!canvas.character(section, item, 24 + report.shown % 21 * 32, 400 + report.shown / 21 * 48)) report.missing += 1;
        report.shown += 1;
    }
    pager.next_offset = pager.offset + iterator.i;
    pager.more = pager.next_offset < value.len;
    canvas.text(section, if (pager.more) "タップで続きを表示" else if (pager.field == 3) "タップで閉じて消去" else "タップで次の項目", 24, 850);
    return report;
}
pub const portrait_width = 96;
pub const portrait_height = 128;
pub const portrait_bytes = portrait_width * portrait_height * 2;
/// All four fields and portrait on one screen; unusually long fields are
/// explicitly marked with an ellipsis and reported as truncated.
pub inline fn overview(comptime section: ?[]const u8, frame: []u8, attributes: input.Attributes, portrait: ?[]const u8) !Paint {
    if (frame.len != 720 * 1280 * 2 or (portrait != null and portrait.?.len != portrait_bytes)) return error.Invalid;
    for (0..frame.len / 2) |i| std.mem.writeInt(u16, frame[i * 2 ..][0..2], screen.paper_color, .little);
    const canvas = Canvas{ .frame = frame };
    _ = try canvas.wrapped(section, "マイナンバーカード", 24, 64, 24, 28, 1);
    _ = try canvas.wrapped(section, "読取結果・署名検証は未実施", 24, 104, 16, 42, 1);
    const labels = [_][]const u8{ "氏名", "生年月日", "性別（記録値）", "住所" };
    const positions = [_]usize{ 164, 324, 416, 528 };
    for (labels, positions) |label, y| _ = try canvas.wrapped(section, label, 24, y, 16, 28, 1);
    var report = Paint{ .shown = 15 };
    const values = [_][]const u8{ attributes.name, attributes.birth_date, attributes.gender, attributes.address };
    const ys = [_]usize{ 192, 352, 444, 560 };
    const sizes = [_]usize{ 32, 32, 24, 24 };
    const columns = [_]usize{ 13, 13, 18, 28 };
    const rows = [_]usize{ 2, 1, 1, 6 };
    for (values, ys, sizes, columns, rows) |value, y, size, count, lines| {
        const part = try canvas.wrapped(section, value, 24, y, size, count, lines);
        report.missing += part.missing;
        report.truncated = report.truncated or part.truncated;
    }
    if (portrait) |pixels| {
        for (0..portrait_height * 2) |y| for (0..portrait_width * 2) |x| {
            const source = ((y / 2) * portrait_width + x / 2) * 2;
            const target = ((192 + y) * 720 + 480 + x) * 2;
            frame[target] = pixels[source];
            frame[target + 1] = pixels[source + 1];
        };
    } else _ = try canvas.wrapped(section, "顔写真 未表示", 480, 280, 16, 12, 2);
    _ = try canvas.wrapped(section, if (report.truncated) "長い項目は省略しています" else "タップで閉じて消去", 24, 1120, 16, 42, 1);
    return report;
}
pub inline fn preview(comptime section: ?[]const u8, frame: []u8, portrait: []const u8) !void {
    var name: [26 * 3]u8 = undefined;
    var address: [168 * 3]u8 = undefined;
    for (0..26) |i| @memcpy(name[i * 3 ..][0..3], "例");
    for (0..168) |i| @memcpy(address[i * 3 ..][0..3], "試");
    _ = try overview(section, frame, .{ .name = &name, .address = &address, .birth_date = "00000000", .gender = "0" }, portrait);
    for (0..150 * 720) |i| std.mem.writeInt(u16, frame[i * 2 ..][0..2], screen.paper_color, .little);
    for (1080 * 720..1200 * 720) |i| std.mem.writeInt(u16, frame[i * 2 ..][0..2], screen.paper_color, .little);
    const canvas = Canvas{ .frame = frame };
    _ = try canvas.wrapped(section, "表示の動作確認", 24, 64, 24, 28, 1);
    _ = try canvas.wrapped(section, "テスト画像・架空データ", 24, 104, 16, 42, 1);
    _ = try canvas.wrapped(section, "タップしてPIN入力へ", 24, 1120, 16, 42, 1);
}
pub fn message(comptime section: ?[]const u8, frame: []u8, success: bool) void {
    endMessage(section, frame, if (success) .cleared else .cancelled);
}
pub const End = enum { cleared, cancelled, timeout, wrong_pin, blocked, last_attempt, counter_changed, transport, unknown, malformed, photo_failed, cleanup_failed };
const EndLabels = struct {
    const text = "読取結果を消去しました\x00" ++ "読み取りを中止しました\x00" ++
        "待ち時間を過ぎたため中止しました\x00" ++ "暗証番号が一致しませんでした\x00" ++
        "暗証番号がロックされています\x00" ++ "残り回数が少ないため中止しました\x00" ++
        "残り回数が変わったため中止しました\x00" ++ "カードとの通信が途切れました\x00" ++
        "暗証番号の送信結果を確認できません\x00" ++ "カードデータを解析できませんでした\x00" ++
        "４情報を表示しました・顔写真は未表示\x00" ++ "後片付けを確認できませんでした\x00" ++
        "再試行は自動では行いません\x00" ++ "再入力せず状態を確認してください\x00";
    const placement = if (@import("builtin").os.tag == .freestanding) ".flash.rodata.card_pin" else if (@import("builtin").os.tag == .macos) "__TEXT,__const" else ".rodata";
    const data: [text.len]u8 align(4) linksection(placement) = text.*;
    inline fn get(index: usize) []const u8 {
        const live: [*]const volatile u8 = @ptrCast(&data);
        var offset: usize = 0;
        for (0..index) |_| {
            while (live[offset] != 0) : (offset += 1) {}
            offset += 1;
        }
        var end = offset;
        while (live[end] != 0) : (end += 1) {}
        return data[offset..end];
    }
};
pub inline fn endMessage(comptime section: ?[]const u8, frame: []u8, reason: End) void {
    for (0..frame.len / 2) |i| std.mem.writeInt(u16, frame[i * 2 ..][0..2], screen.paper_color, .little);
    const canvas = Canvas{ .frame = frame };
    const title = EndLabels.get(@backingInt(reason));
    _ = canvas.wrapped(section, title, 24, 300, 24, 28, 2) catch return;
    _ = canvas.wrapped(section, EndLabels.get(12), 24, 400, 24, 28, 2) catch return;
    if (reason == .unknown) _ = canvas.wrapped(section, EndLabels.get(13), 24, 480, 24, 28, 2) catch return;
}
test "result pages retain UTF8 boundaries and show Japanese without leaving values in metadata" {
    const frame = try std.testing.allocator.alloc(u8, 720 * 1280 * 2);
    defer std.testing.allocator.free(frame);
    var pager = Pager{};
    var name: [360]u8 = undefined;
    for (0..40) |i| @memcpy(name[i * 9 ..][0..9], "テスト");
    const attributes = input.Attributes{ .name = &name, .address = "東京都", .birth_date = "19900101", .gender = "1" };
    const painted = try result(null, frame, attributes, &pager);
    try std.testing.expectEqual(@as(u32, 0), painted.missing);
    try std.testing.expectEqual(@as(u32, 84), painted.shown);
    try std.testing.expect(pager.more);
    try std.testing.expect(pager.next());
    _ = try result(null, frame, attributes, &pager);
    try std.testing.expect(!pager.more);
    try std.testing.expect(pager.next());
    try std.testing.expectEqual(@as(u8, 1), pager.field);
    try std.testing.expect(glyph(null, '東') != null);
    try std.testing.expect(glyph(null, 0x10ffff) == null);
}

test "dense result pages and the real PIN view fit dedicated SRAM with exact replay" {
    const plan = @import("keypad_plan.zig");
    const frame = try std.testing.allocator.alloc(u8, plan.frame_bytes);
    defer std.testing.allocator.free(frame);
    const replay = try std.testing.allocator.alloc(u8, plan.frame_bytes);
    defer std.testing.allocator.free(replay);
    var dense: [252]u8 = undefined;
    for (0..84) |i| @memcpy(dense[i * 3 ..][0..3], "東");
    var spans: [1024]plan.Segment = undefined;
    for (0..3) |kind| {
        if (kind == 0) {
            var pager = Pager{};
            _ = try result(null, frame, .{ .name = &dense, .address = "Tokyo", .birth_date = "19900101", .gender = "1" }, &pager);
        } else try std.testing.expect(screen.paintRead(null, frame, 1440, .{ .active = true, .masked_digits = 0, .remaining = if (kind == 1) 2 else 3, .can_submit = false }));
        const selected = if (kind == 0) try plan.buildStatic(frame, &spans) else try plan.build(frame, &spans);
        var lower: usize = 2 * plan.textureStride() + selected.len * 64;
        var upper: usize = 0;
        for (selected) |span| if (span.kind == .pixels) {
            const bytes = span.words * 8;
            if (bytes <= 188 * 1024 - upper) upper += bytes else lower += bytes;
        };
        try std.testing.expect(lower <= 128 * 1024);
        var offset: usize = 0;
        for (selected) |span| {
            const length = span.words * 8;
            const target = replay[offset..][0..length];
            const color = switch (span.kind) {
                .paper => screen.paper_color,
                .keys, .submit => screen.key_color,
                else => null,
            };
            if (color) |ink| {
                for (0..length / 2) |i| std.mem.writeInt(u16, target[i * 2 ..][0..2], ink, .little);
            } else @memcpy(target, frame[offset..][0..length]);
            offset += length;
        }
        try std.testing.expectEqual(frame.len, offset);
        try std.testing.expectEqualSlices(u8, frame, replay);
    }
}

test "one-screen worst-case fields and synthetic portrait fit SRAM with repeated-row reuse" {
    const sparse = @import("keypad_plan.zig");
    const frame = try std.testing.allocator.alloc(u8, sparse.frame_bytes);
    defer std.testing.allocator.free(frame);
    var name: [26 * 3]u8 = undefined;
    var address: [168 * 3]u8 = undefined;
    for (0..26) |i| @memcpy(name[i * 3 ..][0..3], "東");
    for (0..168) |i| @memcpy(address[i * 3 ..][0..3], "都");
    var portrait: [portrait_bytes]u8 = undefined;
    for (0..portrait_height) |y| for (0..portrait_width) |x| {
        std.mem.writeInt(u16, portrait[(y * portrait_width + x) * 2 ..][0..2], @intCast((x * 317 + y * 113) & 65535), .little);
    };
    const painted = try overview(null, frame, .{ .name = &name, .address = &address, .birth_date = "19900101", .gender = "1" }, &portrait);
    try std.testing.expect(!painted.truncated and painted.missing == 0 and painted.shown == 15);
    var spans: [1600]sparse.Segment = undefined;
    const plan = try sparse.buildOverview(frame, &spans);
    var lower: usize = 2 * sparse.textureStride() + plan.len * 64;
    var upper: usize = 0;
    var previous: [2][]const u8 = .{ &.{}, &.{} };
    for (plan) |span| if (span.kind == .pixels) {
        const pixels = frame[span.offset..][0 .. span.words * 8];
        const group: usize = if (span.offset % 1440 >= 912 and span.offset / 1440 >= 192 and span.offset / 1440 < 448) 1 else 0;
        if (!std.mem.eql(u8, previous[group], pixels)) {
            if (pixels.len <= 188 * 1024 - upper) upper += pixels.len else lower += pixels.len;
        }
        previous[group] = pixels;
    };
    try std.testing.expect(plan.len <= 1280);
    try std.testing.expect(lower <= 128 * 1024);
}
