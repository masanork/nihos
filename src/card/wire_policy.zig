//! Last transport boundary for one Input Support transaction. No arbitrary APDU.
const std = @import("std");
const input = @import("input_support.zig");
pub const Policy = struct {
    verifies: u32 = 0,
    pub fn allow(self: *Policy, frame: []const u8) bool {
        if (frame.len < 10 or frame[5] != 0 or frame[7] != 0 or frame[8] != 0 or frame[9] != 0 or
            std.mem.readInt(u32, frame[1..5], .little) != frame.len - 10) return false;
        const apdu = frame[10..];
        if (frame[0] == 0x62 or frame[0] == 0x63) return apdu.len == 0;
        if (frame[0] != 0x6f) return false;
        for ([_][]const u8{ &input.select_ap, &input.select_pin, &input.query_retries, &input.select_attributes }) |permitted|
            if (std.mem.eql(u8, apdu, permitted)) return true;
        if (apdu.len == 5 and apdu[0] == 0 and apdu[1] == 0xb0 and apdu[2] < 8 and apdu[3] == 0 and apdu[4] == 0) return true;
        if (apdu.len != 9 or !std.mem.eql(u8, apdu[0..5], &.{ 0, 0x20, 0, 0x80, 4 }) or self.verifies != 0) return false;
        for (apdu[5..]) |digit| if (digit < '0' or digit > '9') return false;
        self.verifies = 1; // Consumed before attempting the wire; never retry.
        return true;
    }
};
test "wire policy denies My Number EF, signature AP, malformed lengths and repeat PIN" {
    const ccid = @import("ccid");
    var policy = Policy{};
    var buffer: [512]u8 = undefined;
    try std.testing.expect(!policy.allow(try ccid.request(&buffer, 0x6f, 0, &.{ 0, 0xa4, 2, 0x0c, 2, 0, 1 })));
    try std.testing.expect(policy.allow(try ccid.request(&buffer, 0x6f, 0, &input.select_ap)));
    const frame = try ccid.request(&buffer, 0x6f, 0, &.{ 0, 0x20, 0, 0x80, 4, '1', '2', '3', '4' });
    buffer[1] = 8;
    try std.testing.expect(!policy.allow(frame));
    buffer[1] = 9;
    try std.testing.expect(policy.allow(frame));
    try std.testing.expect(!policy.allow(frame));
}
