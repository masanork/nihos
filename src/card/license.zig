//! Conventional Japanese IC licence, NPA specification 010, read-only subset.
//! Wire facts were checked against NPA's 2024-07-19 specification and civ
//! 54a843e. No upstream implementation is copied. No issuer verification.
const std = @import("std");
const jis = @import("jis0208.zig");
pub const Error = @import("surface.zig").Error;
pub const select_mf = [_]u8{ 0, 0xa4, 0, 0 };
pub const select_pin_setting = [_]u8{ 0, 0xa4, 2, 0x0c, 2, 0, 0x0a };
pub const select_pin1 = [_]u8{ 0, 0xa4, 2, 0x0c, 2, 0, 1 };
pub const select_pin2 = [_]u8{ 0, 0xa4, 2, 0x0c, 2, 0, 2 };
pub const select_df1 = [_]u8{ 0, 0xa4, 4, 0x0c, 16, 0xa0, 0, 0, 2, 0x31, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
pub const select_df2 = [_]u8{ 0, 0xa4, 4, 0x0c, 16, 0xa0, 0, 0, 2, 0x31, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
pub const common_bytes = 880;
pub const photo_bytes = 2005;
pub const text_bytes = 512;
pub const Fields = struct { name: []const u8, address: []const u8, birth_date: []const u8, expiration: []const u8, number: []const u8 };
pub const Info = struct { name: []const u8, address: []const u8, birth_date: []const u8, expiration: []const u8, number: []const u8, missing: u32 };
pub const Tlv = struct { tag: u16, value: []const u8 };
pub const Iterator = struct {
    bytes: []const u8,
    offset: usize = 0,
    pub fn next(self: *Iterator) Error!?Tlv {
        if (self.offset == self.bytes.len) return null;
        const first = self.bytes[self.offset];
        self.offset += 1;
        if (first == 0 or first == 255) {
            for (self.bytes[self.offset..]) |byte| if (byte != 0 and byte != 255) return error.Malformed;
            self.offset = self.bytes.len;
            return null;
        }
        var tag: u16 = first;
        if (first == 0x5f) {
            if (self.offset == self.bytes.len or self.bytes[self.offset] != 0x40) return error.Malformed;
            tag = 0x5f40;
            self.offset += 1;
        }
        if (self.offset == self.bytes.len) return error.Malformed;
        const lead = self.bytes[self.offset];
        self.offset += 1;
        var length: usize = lead;
        if (lead >= 128) {
            if (lead != 0x82 or self.bytes.len - self.offset < 2) return error.Malformed;
            length = std.mem.readInt(u16, self.bytes[self.offset..][0..2], .big);
            self.offset += 2;
            if (length < 128) return error.Malformed;
        }
        if (length > self.bytes.len - self.offset) return error.Malformed;
        const value = self.bytes[self.offset..][0..length];
        self.offset += length;
        return .{ .tag = tag, .value = value };
    }
};
fn defaultSection() []const u8 {
    return if (@import("builtin").os.tag == .macos) "__TEXT,__text" else ".text";
}
pub fn Parser(comptime section: ?[]const u8) type {
    return struct {
        pub noinline fn fields(raw: []const u8) linksection(section orelse defaultSection()) Error!Fields {
            if (raw.len != common_bytes) return error.Malformed;
            var values: [5][]const u8 = @splat(&.{});
            var seen: u64 = 0;
            var iterator = Iterator{ .bytes = raw };
            while (try iterator.next()) |tlv| {
                if (tlv.tag < 0x11 or tlv.tag > 0x3f) return error.Malformed;
                const bit = @as(u64, 1) << @as(u6, @intCast(tlv.tag - 0x11));
                if (seen & bit != 0) return error.Duplicate;
                seen |= bit;
                const slot: ?usize = switch (tlv.tag) {
                    0x12 => 0,
                    0x17 => 1,
                    0x16 => 2,
                    0x1b => 3,
                    0x21 => 4,
                    else => null,
                };
                if (slot) |index| values[index] = tlv.value;
            }
            if (values[0].len == 0 or values[1].len == 0) return error.Missing;
            if (values[0].len > 72 or values[1].len > 80 or values[2].len != 7 or values[3].len != 7 or values[4].len != 12) return error.Malformed;
            for (values[4]) |digit| if (digit < '0' or digit > '9') return error.Malformed;
            return .{ .name = values[0], .address = values[1], .birth_date = values[2], .expiration = values[3], .number = values[4] };
        }
        pub noinline fn decode(raw: []const u8, output: []u8) linksection(section orelse defaultSection()) Error!Info {
            if (output.len != text_bytes) return error.TooLarge;
            const selected = try fields(raw);
            const D = jis.Decoder(if (section != null) ".flash.license.data" else null);
            const name = D.decode(selected.name, output[0..216]) catch return error.Malformed;
            const address = D.decode(selected.address, output[216..480]) catch return error.Malformed;
            try date(selected.birth_date, output[480..488]);
            try date(selected.expiration, output[488..496]);
            return .{ .name = name.text, .address = address.text, .birth_date = output[480..488], .expiration = output[488..496], .number = selected.number, .missing = name.missing + address.missing };
        }
        pub noinline fn validate(raw: []const u8) linksection(section orelse defaultSection()) Error!void {
            var scratch: [text_bytes]u8 = undefined;
            defer std.crypto.secureZero(u8, &scratch);
            _ = try decode(raw, &scratch);
        }
        pub noinline fn portrait(raw: []const u8) linksection(section orelse defaultSection()) Error![]const u8 {
            if (raw.len != photo_bytes) return error.Malformed;
            var iterator = Iterator{ .bytes = raw };
            const field = (try iterator.next()) orelse return error.Missing;
            if (field.tag != 0x5f40 or field.value.len < 16 or field.value.len > 2000) return error.Malformed;
            if (try iterator.next() != null) return error.Duplicate;
            const j2k = std.mem.startsWith(u8, field.value, &.{ 0xff, 0x4f });
            const jp2 = std.mem.startsWith(u8, field.value, &.{ 0, 0, 0, 12, 0x6a, 0x50, 0x20, 0x20, 13, 10, 0x87, 10 });
            if (!j2k and !jp2) return error.Malformed;
            return field.value;
        }
        fn date(raw: []const u8, output: *[8]u8) linksection(section orelse defaultSection()) Error!void {
            if (raw.len != 7) return error.Malformed;
            for (raw) |digit| if (digit < '0' or digit > '9') return error.Malformed;
            const bases = [_]u16{ 1867, 1911, 1925, 1988, 2018 };
            if (raw[0] < '1' or raw[0] > '5') return error.Malformed;
            const age = (raw[1] - '0') * 10 + raw[2] - '0';
            if (age == 0) return error.Malformed;
            const year = bases[raw[0] - '1'] + age;
            const month = (raw[3] - '0') * 10 + raw[4] - '0';
            const day = (raw[5] - '0') * 10 + raw[6] - '0';
            if (month == 0 or month > 12 or day == 0) return error.Malformed;
            const days = [_]u8{ 31, if (year % 4 == 0 and (year % 100 != 0 or year % 400 == 0)) 29 else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
            if (day > days[month - 1]) return error.Malformed;
            const value = @as(u32, year) * 10000 + @as(u32, month) * 100 + day;
            const first = [_]u32{ 18680125, 19120730, 19261225, 19890108, 20190501 };
            const last = [_]u32{ 19120729, 19261224, 19890107, 20190430, 99991231 };
            const era = raw[0] - '1';
            if (value < first[era] or value > last[era]) return error.Malformed;
            output.* = .{ @intCast('0' + year / 1000), @intCast('0' + year / 100 % 10), @intCast('0' + year / 10 % 10), @intCast('0' + year % 10), raw[3], raw[4], raw[5], raw[6] };
        }
    };
}
pub const fixture = "\x12\x0a\x3b\x33\x45\x44\x21\x21\x42\x40\x4f\x3a" ++ "\x16\x07" ++ "4010108" ++ "\x17\x04\x45\x6c\x35\x7e" ++ "\x1b\x07" ++ "5120101" ++ "\x21\x0c" ++ "123456789012";
test "NPA flat tags, strict dates, JIS and fixed-size photo envelopes" {
    var raw: [common_bytes]u8 = @splat(255);
    @memcpy(raw[0..fixture.len], fixture);
    var output: [text_bytes]u8 = undefined;
    const P = Parser(null);
    const info = try P.decode(&raw, &output);
    try std.testing.expectEqualStrings("山田　太郎", info.name);
    try std.testing.expectEqualStrings("19890108", info.birth_date);
    try std.testing.expectEqualStrings("20300101", info.expiration);
    raw[fixture.len] = 0x12;
    raw[fixture.len + 1] = 0;
    try std.testing.expectError(error.Duplicate, P.fields(&raw));
    try std.testing.expectError(error.Malformed, P.fields(raw[0..879]));
    var photo: [photo_bytes]u8 = @splat(255);
    const header = "\x5f\x40\x10\xff\x4f0123456789abcd";
    @memcpy(photo[0..header.len], header);
    try std.testing.expectEqual(@as(usize, 16), (try P.portrait(&photo)).len);
    try std.testing.expectError(error.Malformed, P.date("4310501", output[0..8]));
}
