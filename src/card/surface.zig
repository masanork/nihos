//! Strict bounded Surface AP identifiers/TLV extraction. No logging or storage.
const std = @import("std");
pub const select_number = [_]u8{ 0, 0xa4, 2, 0x0c, 2, 0, 1 };
pub const select_ap = [_]u8{ 0, 0xa4, 4, 0x0c, 10, 0xd3, 0x92, 0x10, 0, 0x31, 0, 1, 1, 4, 2 };
pub const select_pin = [_]u8{ 0, 0xa4, 2, 0x0c, 2, 0, 0x13 };
pub const select_photo = [_]u8{ 0, 0xa4, 2, 0x0c, 2, 0, 2 };
pub const capacity = 32768;
pub const Error = error{ Malformed, Missing, Duplicate, TooLarge };
fn defaultSection() []const u8 {
    return if (@import("builtin").os.tag == .macos) "__TEXT,__text" else ".text";
}
pub fn Parser(comptime section: ?[]const u8) type {
    return struct {
        fn find(bytes: []const u8, for_number: bool, depth: u8, found: *?[]const u8) linksection(section orelse defaultSection()) Error!void {
            if (depth > 4) return error.Malformed;
            var offset: usize = 0;
            while (offset < bytes.len) {
                if (bytes[offset] == 0 or (bytes[offset] == 0xff and (offset + 1 == bytes.len or bytes[offset + 1] == 0xff))) {
                    offset += 1;
                    continue;
                }
                var tag: u32 = bytes[offset];
                offset += 1;
                if (tag & 31 == 31) {
                    var count: u8 = 0;
                    while (true) {
                        if (offset == bytes.len or count == 2) return error.Malformed;
                        const value = bytes[offset];
                        offset += 1;
                        count += 1;
                        tag = tag << 8 | value;
                        if (value & 128 == 0) break;
                    }
                }
                if (offset == bytes.len) return error.Malformed;
                const first = bytes[offset];
                offset += 1;
                var length: usize = first;
                if (first >= 128) {
                    const count = first & 127;
                    if (count == 0 or count > 3 or count > bytes.len - offset) return error.Malformed;
                    length = 0;
                    for (bytes[offset..][0..count]) |value| length = length << 8 | value;
                    offset += count;
                }
                if (length > bytes.len - offset) return error.Malformed;
                const value = bytes[offset..][0..length];
                offset += length;
                if ((for_number and (tag == 0xff10 or tag == 1 or tag == 0xdf01)) or (!for_number and tag == 0xdf27)) {
                    if (found.* != null) return error.Duplicate;
                    found.* = value;
                } else if (tag == 0x30 or tag == 0xdf20 or tag == 0xff20 or tag == 0xff21) try find(value, for_number, depth + 1, found);
                if (!for_number and depth == 0 and found.* != null and (tag == 0xdf20 or tag == 0xff20 or tag == 0xff21)) return;
            }
        }
        pub noinline fn number(bytes: []const u8) linksection(section orelse defaultSection()) Error![]const u8 {
            if (bytes.len > 256) return error.TooLarge;
            var value: ?[]const u8 = null;
            if (bytes.len == 12) value = bytes else try find(bytes, true, 0, &value);
            const selected = value orelse return error.Missing;
            if (selected.len != 12) return error.Malformed;
            for (selected) |digit| if (digit < '0' or digit > '9') return error.Malformed;
            var sum: u16 = 0;
            for (0..11) |i| sum += @as(u16, selected[10 - i] - '0') * @as(u16, @intCast(i % 6 + 2));
            const remainder = sum % 11;
            const check: u16 = if (remainder <= 1) 0 else 11 - remainder;
            if (check != selected[11] - '0') return error.Malformed;
            return selected;
        }
        pub noinline fn portrait(bytes: []const u8) linksection(section orelse defaultSection()) Error![]const u8 {
            if (bytes.len > capacity) return error.TooLarge;
            var value: ?[]const u8 = null;
            try find(bytes, false, 0, &value);
            const selected = value orelse return error.Missing;
            const j2k = std.mem.startsWith(u8, selected, &.{ 0xff, 0x4f });
            const jp2 = std.mem.startsWith(u8, selected, &.{ 0, 0, 0, 12, 0x6a, 0x50, 0x20, 0x20, 13, 10, 0x87, 10 });
            if ((!j2k and !jp2) or selected.len < 16) return error.Malformed;
            return selected;
        }
    };
}
pub const number = Parser(null).number;
pub const portrait = Parser(null).portrait;
test "number and photo TLVs reject unrelated digits, duplicate values and malformed frames" {
    // Synthetic valid number; FF10 is a primitive EF0001 value, not a container.
    try std.testing.expectEqualStrings("123456789018", try number("\xff\x10\x0c123456789018\xff\xff"));
    try std.testing.expectError(error.Duplicate, number("\xff\x10\x0c123456789018\x01\x0c123456789018"));
    try std.testing.expectError(error.Malformed, number("\xff\x10\x0c123456789019"));
    try std.testing.expectEqualStrings("123456789018", (try number("\xdf\x01\x0c123456789018")));
    try std.testing.expectError(error.Malformed, number("junk123456789018"));
    try std.testing.expectError(error.Duplicate, number("\x01\x0c123456789018\x01\x0c123456789018"));
    const photo = "\xdf\x27\x10\xff\x4f" ++ "0123456789abcd";
    try std.testing.expectEqual(@as(usize, 16), (try portrait(photo)).len);
    for (0..photo.len) |length| {
        if (portrait(photo[0..length])) |_| return error.TestUnexpectedResult else |_| {}
    }
}
