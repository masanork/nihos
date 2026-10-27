//! Input Support AP identifiers and bounded four-attribute TLV decoding.
//! Wire reference: civ 54a843e, crates/civ-card and src/jpki.rs.
const std = @import("std");
pub const select_ap = [_]u8{ 0, 0xa4, 4, 0x0c, 10, 0xd3, 0x92, 0x10, 0, 0x31, 0, 1, 1, 4, 8 };
pub const select_pin = [_]u8{ 0, 0xa4, 2, 0x0c, 2, 0, 0x11 };
pub const select_attributes = [_]u8{ 0, 0xa4, 2, 0x0c, 2, 0, 2 };
pub const query_retries = [_]u8{ 0, 0x20, 0, 0x80 };
pub const capacity = 2048;
pub const Error = error{ Malformed, Duplicate, Missing, Encoding, TooLarge };
pub const Attributes = struct {
    name: []const u8 = &.{},
    address: []const u8 = &.{},
    birth_date: []const u8 = &.{},
    gender: []const u8 = &.{},
};

fn collect(bytes: []const u8, depth: u8, result: *Attributes, seen: *u4) Error!void {
    if (depth > 3) return error.Malformed;
    var offset: usize = 0;
    while (offset < bytes.len) {
        if (bytes[offset] == 0 or bytes[offset] == 0xff and
            (offset + 1 == bytes.len or bytes[offset + 1] == 0xff))
        {
            offset += 1;
            continue;
        }
        var tag: u32 = bytes[offset];
        offset += 1;
        if (tag & 31 == 31) {
            var count: usize = 0;
            while (true) {
                if (offset == bytes.len or count == 2) return error.Malformed;
                const byte = bytes[offset];
                offset += 1;
                tag = tag << 8 | byte;
                count += 1;
                if (byte & 128 == 0) break;
            }
        }
        if (offset == bytes.len) return error.Malformed;
        const first = bytes[offset];
        offset += 1;
        var length: usize = first;
        if (first >= 128) {
            const count: usize = first & 127;
            if (count == 0 or count > 2 or count > bytes.len - offset) return error.Malformed;
            length = 0;
            for (bytes[offset..][0..count]) |byte| length = length << 8 | byte;
            offset += count;
        }
        if (length > bytes.len - offset) return error.Malformed;
        const value = bytes[offset..][0..length];
        offset += length;
        if (tag == 0x30 or tag == 0xdf20 or tag == 0xff20) {
            try collect(value, depth + 1, result, seen);
        } else if (tag >= 0xdf22 and tag <= 0xdf25) {
            const bit = @as(u4, 1) << @as(u2, @intCast(tag - 0xdf22));
            if (seen.* & bit != 0) return error.Duplicate;
            if (value.len == 0) return error.Missing;
            if (!std.unicode.utf8ValidateSlice(value) or std.mem.indexOfScalar(u8, value, 0) != null) return error.Encoding;
            seen.* |= bit;
            switch (tag) {
                0xdf22 => result.name = value,
                0xdf23 => result.address = value,
                0xdf24 => result.birth_date = value,
                0xdf25 => result.gender = value,
                else => unreachable,
            }
        }
    }
}

/// Returned slices borrow bytes. Dates and gender retain the card's encoding;
/// parsing these fields does not verify an issuer signature.
pub fn parse(bytes: []const u8) Error!Attributes {
    if (bytes.len > capacity) return error.TooLarge;
    var result = Attributes{};
    var seen: u4 = 0;
    try collect(bytes, 0, &result, &seen);
    if (seen != 15) return error.Missing;
    return result;
}

pub const fixture = "\xdf\x22\x04Test\xdf\x23\x05Tokyo\xdf\x24\x0819900101\xdf\x25\x011";
test "strict attributes reject truncation, duplicates, missing and invalid UTF8" {
    const attributes = try parse(fixture);
    try std.testing.expectEqualStrings("Test", attributes.name);
    try std.testing.expectEqualStrings("Tokyo", attributes.address);
    try std.testing.expectEqualStrings("19900101", attributes.birth_date);
    for (0..fixture.len) |length| {
        if (parse(fixture[0..length])) |_| return error.TestUnexpectedResult else |_| {}
    }
    try std.testing.expectError(error.Duplicate, parse(fixture ++ "\xdf\x22\x01X"));
    try std.testing.expectError(error.Encoding, parse("\xdf\x22\x01\xff"));
    try std.testing.expectError(error.Malformed, parse("\xdf\x20\x80"));
    try std.testing.expectError(error.Malformed, parse("\xdf\x22\x82\xff\xffX"));
    const nested = "\xdf\x20\x1e" ++ fixture;
    try std.testing.expectEqualStrings("Test", (try parse(nested)).name);
}
