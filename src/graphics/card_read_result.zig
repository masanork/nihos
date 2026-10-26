//! Ephemeral, paginated card results. No strings leave the device.
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
        const selected = glyph(section, value);
        const bits = selected orelse glyph(section, 0x25a1).?;
        for (0..16) |row| for (0..16) |column| {
            if (bits[row * 2 + column / 8] & (@as(u8, 128) >> @as(u3, @intCast(column % 8))) == 0) continue;
            for (0..2) |dy| for (0..2) |dx| {
                const left = x + column * 2 + dx;
                const top = y + row * 2 + dy;
                if (left >= 720 or top >= 1280) continue;
                const offset = (top * 720 + left) * 2;
                std.mem.writeInt(u16, self.frame[offset..][0..2], 0x2125, .little);
            };
        };
        return selected != null;
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
pub const Paint = struct { missing: u32 = 0, shown: u32 = 0 };
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
pub fn message(comptime section: ?[]const u8, frame: []u8, success: bool) void {
    for (0..frame.len / 2) |i| std.mem.writeInt(u16, frame[i * 2 ..][0..2], screen.paper_color, .little);
    const canvas = Canvas{ .frame = frame };
    canvas.text(section, if (success) "読取結果を消去しました" else "読取を終了しました", 24, 300);
    canvas.text(section, "再試行は自動では行いません", 24, 400);
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
