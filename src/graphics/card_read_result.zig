//! Ephemeral card overview and legacy page renderer. No strings leave the device.
const std = @import("std");
const surface = @import("surface");
const screen = @import("card_pin.zig");
const input = @import("../card/input_support.zig");
fn Store(comptime section: ?[]const u8) type {
    return if (isCompressed(section)) struct {
        const data: [@embedFile("card_auto_font.bin").len]u8 align(64) linksection(section.?) = @embedFile("card_auto_font.bin").*;
    } else if (section) |name| struct {
        const data: [@embedFile("card_read_font.bin").len]u8 align(64) linksection(name) = @embedFile("card_read_font.bin").*;
    } else struct {
        const data: [@embedFile("card_read_font.bin").len]u8 align(64) = @embedFile("card_read_font.bin").*;
    };
}
fn code(bytes: []const u8) u32 {
    return std.mem.readInt(u32, bytes[0..4], .little);
}
fn isCompressed(comptime section: ?[]const u8) bool {
    return section != null and std.mem.endsWith(u8, section.?, "auto_font");
}
fn three(bytes: []const u8) u32 {
    return @as(u32, bytes[0]) | @as(u32, bytes[1]) << 8 | @as(u32, bytes[2]) << 16;
}
fn readBits(data: []const u8, pos: *usize, count: u5) linksection(if (@import("builtin").os.tag == .freestanding) ".flash.photo" else if (@import("builtin").os.tag == .macos) "__TEXT,__text" else ".text") ?u16 {
    if (pos.* + count > data.len * 8) return null;
    var value: u16 = 0;
    for (0..count) |i| {
        value |= @as(u16, (data[(pos.* + i) / 8] >> @as(u3, @intCast((pos.* + i) % 8))) & 1) << @as(u4, @intCast(i));
    }
    pos.* += count;
    return value;
}
fn Glyph(comptime section: ?[]const u8) type {
    return struct {
        pub fn find(value: u21) linksection(if (isCompressed(section) and @import("builtin").os.tag == .freestanding) ".flash.photo" else if (@import("builtin").os.tag == .macos) "__TEXT,__text" else ".text") ?[32]u8 {
            const data = &Store(section).data;
            if (comptime isCompressed(section)) {
                const count = std.mem.readInt(u32, data[4..8], .little);
                const table: usize = 12 + 4095 * 2;
                const payload = table + count * 6;
                var low: usize = 0;
                var high: usize = count;
                while (low < high) {
                    const mid = low + (high - low) / 2;
                    if (three(data[table + mid * 6 ..]) < value) low = mid + 1 else high = mid;
                }
                if (low == count or three(data[table + low * 6 ..]) != value) return null;
                var bit = (payload + three(data[table + low * 6 + 3 ..])) * 8;
                var decoded_glyph: [32]u8 = undefined;
                for (0..16) |row| {
                    const index = readBits(data, &bit, 12) orelse return null;
                    const pattern = if (index == 4095) readBits(data, &bit, 16) orelse return null else std.mem.readInt(u16, data[12 + @as(usize, index) * 2 ..][0..2], .little);
                    std.mem.writeInt(u16, decoded_glyph[row * 2 ..][0..2], pattern, .little);
                }
                return decoded_glyph;
            }
            unreachable;
        }
    };
}
fn GlyphResult(comptime section: ?[]const u8) type {
    return if (isCompressed(section)) [32]u8 else []const u8;
}
inline fn glyph(comptime section: ?[]const u8, value: u21) ?GlyphResult(section) {
    if (comptime isCompressed(section)) return Glyph(section).find(value) else return rawGlyph(section, value);
}
fn rawGlyph(comptime section: ?[]const u8, value: u21) ?[]const u8 {
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
fn clearRows(frame: []u8, top: u32, bottom: u32) void {
    const target = surface.Surface.init(frame, 720, 1280, 1440) orelse return;
    _ = target.fillRect(0, @intCast(top), 720, bottom - top, screen.paper_color);
}
const Canvas = struct {
    frame: []u8,
    fn character(self: Canvas, comptime section: ?[]const u8, value: u21, x: usize, y: usize) bool {
        return self.sized(section, value, x, y, 32);
    }
    // Compressed automatic text is drawn from the photo extent. The uncompressed
    // scaler stays on the boot Flash page so the SRAM heap stays at or above 48 KiB.
    inline fn sized(self: Canvas, comptime section: ?[]const u8, value: u21, x: usize, y: usize, size: usize) bool {
        if (comptime isCompressed(section)) return AutoPainter(section).draw(self, value, x, y, size);
        return self.sizedFlash(section, value, x, y, size);
    }
    noinline fn sizedFlash(self: Canvas, comptime section: ?[]const u8, value: u21, x: usize, y: usize, size: usize) linksection(if (@import("builtin").os.tag == .freestanding) ".flash.text.card" else if (@import("builtin").os.tag == .macos) "__TEXT,__text" else ".text") bool {
        return self.sizedInline(section, value, x, y, size);
    }
    inline fn sizedInline(self: Canvas, comptime section: ?[]const u8, value: u21, x: usize, y: usize, size: usize) bool {
        const selected = glyph(section, value);
        const bits = selected orelse glyph(section, 0x25a1).?;
        if (size > 32) return false;
        const target = surface.Surface.init(self.frame, 720, 1280, 1440) orelse return false;
        var coverage: [32]u8 = undefined;
        for (0..size) |row| {
            for (0..size) |column| {
                const original_y = row * 16 / size;
                const original_x = column * 16 / size;
                // The source font is one-bit coverage, so its A8 endpoints
                // are 0 and 255. Shared Surface handles blending and clipping.
                coverage[column] = if (bits[original_y * 2 + original_x / 8] & (@as(u8, 128) >> @as(u3, @intCast(original_x % 8))) == 0) 0 else 255;
            }
            if (!target.blit(.{ .bytes = coverage[0..size], .width = size, .height = 1, .stride = size }, @intCast(x), @intCast(y + row), 0x2125)) return false;
        }
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
fn AutoPainter(comptime section: ?[]const u8) type {
    return struct {
        pub noinline fn draw(canvas: Canvas, value: u21, x: usize, y: usize, size: usize) linksection(if (@import("builtin").os.tag == .freestanding) ".flash.photo" else if (@import("builtin").os.tag == .macos) "__TEXT,__text" else ".text") bool {
            return canvas.sizedInline(section, value, x, y, size);
        }
    };
}
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
test "automatic font decoding preserves every original glyph pixel" {
    const raw = &Store(null).data;
    for (0..raw.len / 36) |i| {
        const at = i * 36;
        const actual = glyph("__TEXT,__auto_font", @intCast(code(raw[at..]))) orelse return error.Missing;
        try std.testing.expectEqualSlices(u8, raw[at + 4 ..][0..32], &actual);
    }
}
pub const Paint = struct { missing: u32 = 0, shown: u32 = 0, truncated: bool = false };
pub fn result(comptime section: ?[]const u8, frame: []u8, attributes: input.Attributes, pager: *Pager) !Paint {
    if (frame.len != 720 * 1280 * 2 or pager.field >= 4) return error.Invalid;
    clearRows(frame, 0, 1280);
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
    return overviewDocument(section, frame, .{ .name = attributes.name, .address = attributes.address, .birth_date = attributes.birth_date, .detail = attributes.gender }, portrait);
}
pub inline fn licenseOverview(comptime section: ?[]const u8, frame: []u8, info: @import("../card/license.zig").Info, portrait: ?[]const u8) !Paint {
    return overviewDocument(section, frame, .{ .name = info.name, .address = info.address, .birth_date = info.birth_date, .detail = info.number, .expiration = info.expiration, .external_missing = info.missing }, portrait);
}
pub const Document = struct { name: []const u8, address: []const u8, birth_date: []const u8, detail: []const u8, expiration: ?[]const u8 = null, external_missing: u32 = 0 };
inline fn overviewDocument(comptime section: ?[]const u8, frame: []u8, attributes: Document, portrait: ?[]const u8) !Paint {
    if (frame.len != 720 * 1280 * 2 or (portrait != null and portrait.?.len != portrait_bytes)) return error.Invalid;
    clearRows(frame, 0, 1280);
    const canvas = Canvas{ .frame = frame };
    _ = try canvas.wrapped(section, if (attributes.expiration != null) "運転免許証" else "マイナンバーカード", 24, 64, 24, 28, 1);
    _ = try canvas.wrapped(section, if (attributes.expiration != null) "交付時の記録・署名検証は未実施" else "読取結果・署名検証は未実施", 24, 104, 16, 42, 1);
    const labels = [_][]const u8{ "氏名", "生年月日", if (attributes.expiration != null) "免許証番号" else "性別（記録値）", "住所" };
    const positions = [_]usize{ 164, 324, 416, if (attributes.expiration != null) 552 else 528 };
    for (labels, positions) |label, y| _ = try canvas.wrapped(section, label, 24, y, 16, 28, 1);
    var report = Paint{ .shown = if (attributes.expiration != null) 31 else 15, .missing = attributes.external_missing };
    const values = [_][]const u8{ attributes.name, attributes.birth_date, attributes.detail, attributes.address };
    const ys = [_]usize{ 192, 352, 444, if (attributes.expiration != null) 584 else 560 };
    const sizes = [_]usize{ 32, 32, 24, 24 };
    const columns = [_]usize{ 13, 13, 18, 28 };
    const rows = [_]usize{ if (attributes.expiration != null) 3 else 2, 1, 1, 6 };
    for (values, ys, sizes, columns, rows) |value, y, size, count, lines| {
        const part = try canvas.wrapped(section, value, 24, y, size, count, lines);
        report.missing += part.missing;
        report.truncated = report.truncated or part.truncated;
    }
    if (attributes.expiration) |value| {
        _ = try canvas.wrapped(section, "有効期限", 24, 492, 16, 6, 1);
        const part = try canvas.wrapped(section, value, 136, 486, 24, 12, 1);
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
    _ = try canvas.wrapped(section, if (report.truncated) "長い項目は省略しています" else if (attributes.external_missing != 0) "外字は□で表示・タップで消去" else "タップで閉じて消去", 24, 1120, 16, 42, 1);
    return report;
}
pub inline fn notice(comptime section: ?[]const u8, frame: []u8, title: []const u8, detail: []const u8) !void {
    if (frame.len != 720 * 1280 * 2) return error.Invalid;
    clearRows(frame, 0, 1280);
    const canvas = Canvas{ .frame = frame };
    _ = try canvas.wrapped(section, title, 24, 240, 24, 28, 3);
    _ = try canvas.wrapped(section, detail, 24, 420, 24, 28, 6);
}
pub inline fn licensePinHeader(comptime section: ?[]const u8, frame: []u8, index: u8) !void {
    if (frame.len != 720 * 1280 * 2 or index < 1 or index > 3) return error.Invalid;
    clearRows(frame, 0, 280);
    const canvas = Canvas{ .frame = frame };
    _ = try canvas.wrapped(section, if (index == 3) "マイナ免許証" else "IC運転免許証", 84, 106, 24, 24, 1);
    _ = try canvas.wrapped(section, if (index == 3) "免許情報の暗証番号" else if (index == 1) "免許証の暗証番号１" else "写真・署名確認の暗証番号２", 84, 190, 24, 24, 1);
    _ = try canvas.wrapped(section, if (index == 2) "署名確認のため本籍も端末内で読みます" else if (index == 3) "マイナンバーカード用とは別の暗証番号です" else "暗証番号は保存しません", 84, 245, 16, 32, 1);
}
pub inline fn licenseNote(comptime section: ?[]const u8, frame: []u8, verification: @import("../card/license_record.zig").Verification, myna: bool, changed: u2) !void {
    clearRows(frame, 92, 156);
    const canvas = Canvas{ .frame = frame };
    _ = try automaticText(section, canvas, switch (verification) {
        .valid => AutoCaptions.get(0),
        .unknown_key => AutoCaptions.get(1),
        .invalid => AutoCaptions.get(2),
        .malformed => AutoCaptions.get(3),
        .not_checked => AutoCaptions.get(4),
    }, 24, 100, 16, 42, 1);
    _ = try automaticText(section, canvas, if (myna) AutoCaptions.get(5) else if (changed == 2) AutoCaptions.get(38) else if (changed == 1) AutoCaptions.get(6) else AutoCaptions.get(7), 24, 128, 16, 42, 1);
}
pub inline fn resultControls(comptime section: ?[]const u8, frame: []u8, myna: bool) !void {
    clearRows(frame, 1080, 1280);
    try paintResultControls(section, frame, myna);
}
inline fn paintResultControls(comptime section: ?[]const u8, frame: []u8, myna: bool) !void {
    const canvas = Canvas{ .frame = frame };
    _ = try automaticText(section, canvas, AutoCaptions.get(8), 24, 1140, 24, 8, 1);
    _ = try automaticText(section, canvas, if (myna) AutoCaptions.get(9) else AutoCaptions.get(10), 264, 1140, 24, 8, 1);
    _ = try automaticText(section, canvas, AutoCaptions.get(11), 504, 1140, 24, 8, 1);
}
pub inline fn chooseLicense(comptime section: ?[]const u8, frame: []u8) !void {
    try notice(section, frame, "", "");
    const canvas = Canvas{ .frame = frame };
    _ = try automaticText(section, canvas, AutoCaptions.get(12), 24, 240, 24, 28, 2);
    _ = try automaticText(section, canvas, AutoCaptions.get(13), 84, 460, 24, 24, 2);
    _ = try automaticText(section, canvas, AutoCaptions.get(14), 84, 760, 24, 24, 2);
}
pub inline fn mynaOverview(comptime section: ?[]const u8, frame: []u8, number: []const u8, expiry: []const u8, types: u16, portrait: ?[]const u8) !Paint {
    try notice(section, frame, "", "");
    const canvas = Canvas{ .frame = frame };
    _ = try automaticText(section, canvas, AutoCaptions.get(15), 24, 64, 24, 28, 1);
    _ = try automaticText(section, canvas, AutoCaptions.get(16), 24, 164, 16, 28, 1);
    _ = try automaticText(section, canvas, number, 24, 200, 24, 18, 1);
    _ = try automaticText(section, canvas, AutoCaptions.get(17), 24, 300, 16, 28, 1);
    _ = try automaticText(section, canvas, expiry, 24, 336, 32, 13, 1);
    _ = try automaticText(section, canvas, AutoCaptions.get(18), 24, 480, 16, 28, 1);
    const names = [_][]const u8{ AutoCaptions.get(19), AutoCaptions.get(20), AutoCaptions.get(21), AutoCaptions.get(22), AutoCaptions.get(23), AutoCaptions.get(24), AutoCaptions.get(25), AutoCaptions.get(26), AutoCaptions.get(27), AutoCaptions.get(28), AutoCaptions.get(29), AutoCaptions.get(30), AutoCaptions.get(31), AutoCaptions.get(32), AutoCaptions.get(33) };
    var at: usize = 0;
    for (names, 0..) |name, i| if (types & (@as(u16, 1) << @as(u4, @intCast(i))) != 0) {
        _ = try automaticText(section, canvas, name, 24 + (at % 4) * 168, 520 + (at / 4) * 40, 24, 6, 1);
        at += 1;
    };
    _ = try automaticText(section, canvas, AutoCaptions.get(34), 24, 760, 24, 28, 2);
    if (portrait) |pixels| {
        if (pixels.len != portrait_bytes) return error.Invalid;
        for (0..portrait_height * 2) |y| for (0..portrait_width * 2) |x| {
            const a = ((y / 2) * portrait_width + x / 2) * 2;
            const b = ((192 + y) * 720 + 480 + x) * 2;
            frame[b] = pixels[a];
            frame[b + 1] = pixels[a + 1];
        };
    }
    return .{ .shown = 7 };
}
pub const DetailRow = struct { label: []const u8, value: []const u8, date: []const u8 = &.{} };
pub inline fn licensePage(comptime section: ?[]const u8, frame: []u8, myna: bool, rows: []const DetailRow) !Paint {
    try notice(section, frame, "", "");
    const canvas = Canvas{ .frame = frame };
    var report = Paint{};
    _ = try automaticText(section, canvas, if (myna) AutoCaptions.get(35) else AutoCaptions.get(36), 24, 64, 24, 28, 1);
    if (rows.len == 0) _ = try automaticText(section, canvas, AutoCaptions.get(37), 24, 240, 24, 28, 1);
    if (rows.len > 3) return error.Invalid;
    for (rows, 0..) |row, i| {
        const y = 164 + i * 272;
        _ = try automaticText(section, canvas, row.label, 24, y, 16, 24, 1);
        _ = try automaticText(section, canvas, row.date, 440, y, 16, 16, 1);
        const part = try automaticText(section, canvas, row.value, 24, y + 40, 24, 28, 2);
        report.missing += part.missing;
        report.truncated = report.truncated or part.truncated;
    }
    try paintResultControls(section, frame, myna);
    return report;
}
pub inline fn preview(comptime section: ?[]const u8, frame: []u8, portrait: []const u8) !void {
    var name: [26 * 3]u8 = undefined;
    var address: [168 * 3]u8 = undefined;
    for (0..26) |i| @memcpy(name[i * 3 ..][0..3], "例");
    for (0..168) |i| @memcpy(address[i * 3 ..][0..3], "試");
    _ = try overview(section, frame, .{ .name = &name, .address = &address, .birth_date = "00000000", .gender = "0" }, portrait);
    clearRows(frame, 0, 150);
    clearRows(frame, 1080, 1200);
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
    clearRows(frame, 0, 1280);
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
    for (0..4) |kind| {
        if (kind == 0) {
            var pager = Pager{};
            _ = try result(null, frame, .{ .name = &dense, .address = "Tokyo", .birth_date = "19900101", .gender = "1" }, &pager);
        } else try std.testing.expect(screen.paintRead(null, frame, 1440, .{ .active = true, .masked_digits = 0, .remaining = if (kind == 1) 2 else if (kind == 2) 3 else 10, .can_submit = false }));
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

test "both card overviews fit SRAM with maximum fields and a synthetic portrait" {
    const sparse = @import("keypad_plan.zig");
    const frame = try std.testing.allocator.alloc(u8, sparse.frame_bytes);
    defer std.testing.allocator.free(frame);
    var name: [36 * 3]u8 = undefined;
    var address: [168 * 3]u8 = undefined;
    for (0..36) |i| @memcpy(name[i * 3 ..][0..3], "東");
    for (0..168) |i| @memcpy(address[i * 3 ..][0..3], "都");
    var portrait: [portrait_bytes]u8 = undefined;
    for (0..portrait_height) |y| for (0..portrait_width) |x| {
        std.mem.writeInt(u16, portrait[(y * portrait_width + x) * 2 ..][0..2], @intCast((x * 317 + y * 113) & 65535), .little);
    };
    const detailed_rows: [3]DetailRow = @splat(.{ .label = "住所の変更", .value = address[0 .. 40 * 3], .date = "20260101" });
    for (0..4) |scene| {
        const painted = if (scene == 1) try licenseOverview(null, frame, .{ .name = &name, .address = address[0 .. 40 * 3], .birth_date = "19900101", .number = "000000000000", .expiration = "20300101", .missing = 0 }, &portrait) else if (scene == 0) try overview(null, frame, .{ .name = name[0 .. 26 * 3], .address = &address, .birth_date = "19900101", .gender = "1" }, &portrait) else if (scene == 2) try mynaOverview("__TEXT,__auto_font", frame, "000000000000", "20300101", 0x7fff, &portrait) else try licensePage("__TEXT,__auto_font", frame, false, &detailed_rows);
        try std.testing.expect(!painted.truncated and painted.missing == 0);
        if (scene < 2) try std.testing.expectEqual(@as(u32, if (scene == 1) 31 else 15), painted.shown);
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
}

noinline fn automaticText(comptime section: ?[]const u8, canvas: Canvas, value: []const u8, x: usize, y: usize, size: usize, columns: usize, lines: usize) linksection(if (@import("builtin").os.tag == .freestanding) ".flash.photo" else if (@import("builtin").os.tag == .macos) "__TEXT,__text" else ".text") !Paint {
    return canvas.wrapped(section, value, x, y, size, columns, lines);
}

const AutoCaptions = struct {
    const text = "署名検証OK（登録された公開鍵）\x00" ++ "署名未検証：公開鍵が未登録です\x00" ++ "署名が一致しません\x00" ++ "署名データの形式を確認できません\x00" ++ "署名検証を完了していません\x00" ++ "氏名・住所・生年月日は別のAPに記録\x00" ++ "変更後の記録を表示・履歴は署名対象外\x00" ++ "署名の対象は発行時の記録です\x00" ++ "基本情報\x00" ++ "内容 次へ\x00" ++ "履歴 次へ\x00" ++ "閉じて消去\x00" ++ "読み取る情報を選んでください\x00" ++ "免許情報を読む\x00" ++ "マイナンバーカードの情報を読む\x00" ++ "マイナ免許証\x00" ++ "免許情報記録番号\x00" ++ "有効期限\x00" ++ "免許の種類\x00" ++ "大型\x00" ++ "普通\x00" ++ "大特\x00" ++ "大自二\x00" ++ "普自二\x00" ++ "小特\x00" ++ "原付\x00" ++ "け引\x00" ++ "大二\x00" ++ "普二\x00" ++ "大特二\x00" ++ "け引二\x00" ++ "中型\x00" ++ "中二\x00" ++ "準中型\x00" ++ "免許条件・備考は「内容」で確認\x00" ++ "免許条件・備考\x00" ++ "変更履歴（署名対象外）\x00" ++ "記録はありません\x00" ++ "追加記録あり・最新値は履歴で確認\x00";
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

pub noinline fn automaticOverview(comptime section: ?[]const u8, frame: []u8, attributes: Document, portrait: ?[]const u8) linksection(if (@import("builtin").os.tag == .freestanding) ".flash.photo" else if (@import("builtin").os.tag == .macos) "__TEXT,__text" else ".text") !Paint {
    return overviewDocument(section, frame, attributes, portrait);
}

pub const NoticeCaptions = struct {
    const text = "カードを置いてください\x00" ++ "マイナンバーカード・IC運転免許証\x00" ++ "本籍の変更\x00" ++ "公安委員会\x00" ++ "氏名の変更\x00" ++ "呼び名の変更\x00" ++ "住所の変更\x00" ++ "免許条件の追加\x00" ++ "免許条件の解除\x00" ++ "備考\x00" ++ "追加の記載事項\x00" ++ "免許の条件\x00" ++ "予備の記録\x00" ++ "読み取りを中止しました\x00" ++ "カードを取り外してください\x00" ++ "取り外し後、次のカードを検知します\x00" ++ "リーダーを確認してください\x00" ++ "USB-Aにカードリーダーを接続してください\x00" ++ "カードを取り外してから接続してください\x00" ++ "カードを確認しています\x00" ++ "しばらくお待ちください\x00" ++ "カードを判定できませんでした\x00" ++ "マイナンバーカードを検知しました\x00" ++ "IC運転免許証を検知しました\x00" ++ "免許情報対応カードを検知しました\x00" ++ "対応するカードではありません\x00" ++ "PINは送信しません・取り外して次へ\x00";
    const placement = if (@import("builtin").os.tag == .freestanding) ".flash.rodata.card_pin" else if (@import("builtin").os.tag == .macos) "__TEXT,__const" else ".rodata";
    const data: [text.len]u8 align(4) linksection(placement) = text.*;
    pub inline fn get(index: usize) []const u8 {
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

test "every public notice fits either SRAM bank and reconstructs the entire frame" {
    const sparse = @import("keypad_plan.zig");
    const frame = try std.testing.allocator.alloc(u8, sparse.frame_bytes);
    defer std.testing.allocator.free(frame);
    const replay = try std.testing.allocator.alloc(u8, sparse.frame_bytes);
    defer std.testing.allocator.free(replay);
    var spans: [1280]sparse.Segment = undefined;
    for (0..27) |index| {
        const caption = NoticeCaptions.get(index);
        try notice(null, frame, caption, caption);
        const selected = try sparse.buildStatic(frame, &spans);
        var used: usize = 64 + selected.len * 64;
        var offset: usize = 0;
        for (selected) |span| {
            const length = span.words * 8;
            if (span.kind == .paper) {
                for (0..length / 2) |i| std.mem.writeInt(u16, replay[offset + i * 2 ..][0..2], screen.paper_color, .little);
            } else {
                try std.testing.expectEqual(sparse.Kind.pixels, span.kind);
                @memcpy(replay[offset..][0..length], frame[span.offset..][0..length]);
                used += length;
            }
            offset += length;
        }
        try std.testing.expect(used <= 94 * 1024);
        try std.testing.expectEqual(frame.len, offset);
        try std.testing.expectEqualSlices(u8, frame, replay);
    }
}
