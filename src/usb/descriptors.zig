//! Bounded USB 2.0 / CCID descriptor parsing. No pointers into device memory.
const std = @import("std");
pub const Error = error{ Malformed, Unsupported };
pub fn le16(bytes: []const u8) u16 {
    return @as(u16, bytes[0]) | (@as(u16, bytes[1]) << 8);
}
pub const Device = struct { vid: u16, pid: u16, packet: u16 };
pub fn device(bytes: []const u8) Error!Device {
    if (bytes.len != 18 or bytes[0] != 18 or bytes[1] != 1 or bytes[17] == 0) return error.Malformed;
    const packet = bytes[7];
    if (packet != 8 and packet != 16 and packet != 32 and packet != 64) return error.Unsupported;
    return .{ .vid = le16(bytes[8..10]), .pid = le16(bytes[10..12]), .packet = packet };
}
pub const Configuration = struct {
    value: u8 = 0,
    interfaces: u8 = 0,
    ccid: bool = false,
    interface: u8 = 0,
    bulk_in: u8 = 0,
    bulk_out: u8 = 0,
    interrupt_in: u8 = 0,
    in_packet: u16 = 0,
    out_packet: u16 = 0,
    max_message: u32 = 0,
};
pub fn configuration(bytes: []const u8) Error!Configuration {
    if (bytes.len < 9 or bytes[0] != 9 or bytes[1] != 2 or
        le16(bytes[2..4]) != bytes.len or bytes[4] == 0 or bytes[5] == 0) return error.Malformed;
    var result = Configuration{ .value = bytes[5], .interfaces = bytes[4] };
    var offset: usize = 9;
    var selected = false;
    var ccid_descriptor = false;
    while (offset < bytes.len) {
        if (bytes.len - offset < 2) return error.Malformed;
        const length = bytes[offset];
        if (length < 2 or length > bytes.len - offset) return error.Malformed;
        const desc = bytes[offset..][0..length];
        switch (desc[1]) {
            4 => {
                if (length < 9) return error.Malformed;
                selected = desc[3] == 0 and desc[5] == 0x0b;
                if (selected) {
                    if (result.ccid or desc[6] != 0 or desc[7] != 0) return error.Unsupported;
                    result.ccid = true;
                    result.interface = desc[2];
                }
            },
            0x21 => if (selected) {
                if (length != 54 or desc[4] != 0) return error.Unsupported; // one slot only
                ccid_descriptor = true;
                result.max_message = @as(u32, le16(desc[44..46])) | (@as(u32, le16(desc[46..48])) << 16);
                if (result.max_message < 10 or result.max_message > 4096) return error.Unsupported;
            },
            5 => {
                if (length < 7 or desc[2] & 0x0f == 0 or desc[2] & 0x70 != 0) return error.Malformed;
                if (selected) {
                    const packet = le16(desc[4..6]);
                    if (desc[3] & 3 == 2) {
                        if (packet != 8 and packet != 16 and packet != 32 and packet != 64 and packet != 512) return error.Unsupported;
                        if (desc[2] & 0x80 != 0) {
                            if (result.bulk_in != 0) return error.Malformed;
                            result.bulk_in = desc[2];
                            result.in_packet = packet;
                        } else {
                            if (result.bulk_out != 0) return error.Malformed;
                            result.bulk_out = desc[2];
                            result.out_packet = packet;
                        }
                    } else if (desc[3] & 3 == 3 and desc[2] & 0x80 != 0) {
                        if (packet == 0 or packet > 512) return error.Unsupported;
                        result.interrupt_in = desc[2];
                    }
                }
            },
            else => {},
        }
        offset += length;
    }
    if (result.ccid and (!ccid_descriptor or result.bulk_in == 0 or result.bulk_out == 0)) return error.Malformed;
    return result;
}
pub fn slotRequest(sequence: u8) [10]u8 {
    return .{ 0x65, 0, 0, 0, 0, 0, sequence, 0, 0, 0 };
}
pub fn slotStatus(bytes: []const u8, sequence: u8) Error!u2 {
    if (bytes.len != 10 or bytes[0] != 0x81 or le16(bytes[1..3]) != 0 or
        le16(bytes[3..5]) != 0 or bytes[5] != 0 or bytes[6] != sequence or
        bytes[7] & 0xfc != 0 or bytes[7] & 3 == 3 or bytes[8] != 0 or bytes[9] > 3) return error.Malformed;
    return @intCast(bytes[7] & 3); // 0 active, 1 inactive, 2 absent
}

test "slot response is correlated and rejects failure, extensions and invalid lengths" {
    const good = [_]u8{ 0x81, 0, 0, 0, 0, 0, 7, 2, 0, 0 };
    try std.testing.expectEqual(@as(u2, 2), try slotStatus(&good, 7));
    for (0..4) |clock| {
        var response = good;
        response[9] = @intCast(clock);
        try std.testing.expectEqual(@as(u2, 2), try slotStatus(&response, 7));
    }
    try std.testing.expectError(error.Malformed, slotStatus(&good, 8));
    try std.testing.expectError(error.Malformed, slotStatus(good[0..9], 7));
    for ([_]usize{ 0, 1, 4, 5, 7, 8, 9 }) |index| {
        var bad = good;
        bad[index] = 0xff;
        try std.testing.expectError(error.Malformed, slotStatus(&bad, 7));
    }
}

test "physical PaSoRi configuration selects CCID and keeps vendor interface separate" {
    const hex = "09027400020100806409040000030b00000036211001000702000000a00f0000a00f00000000c2010000100e0000fe00000000000000000000007e0004000a0200000000000000010705810240000407050102400004070583034000ff0904010002ff0000000705820240000407050202400004";
    var bytes: [116]u8 = @splat(0);
    _ = try std.fmt.hexToBytes(&bytes, hex);
    const result = try configuration(&bytes);
    try std.testing.expect(result.ccid);
    try std.testing.expectEqual(@as(u8, 0), result.interface);
    try std.testing.expectEqual(@as(u8, 0x81), result.bulk_in);
    try std.testing.expectEqual(@as(u8, 0x01), result.bulk_out);
    try std.testing.expectEqual(@as(u16, 64), result.in_packet);
    try std.testing.expectEqual(@as(u32, 522), result.max_message);
    // Every truncation and zero-length descriptor must fail without walking
    // beyond supplied bytes, including class-specific descriptors.
    for (0..bytes.len) |length|
        try std.testing.expectError(error.Malformed, configuration(bytes[0..length]));
    var broken = bytes;
    broken[18] = 0;
    try std.testing.expectError(error.Malformed, configuration(&broken));
    broken = bytes;
    broken[81] = 0x81; // duplicate Bulk IN instead of Bulk OUT
    try std.testing.expectError(error.Malformed, configuration(&broken));
    broken = bytes;
    broken[65] = 1; // oversized CCID message
    try std.testing.expectError(error.Unsupported, configuration(&broken));
}
