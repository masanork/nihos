//! Last transport boundary for one Input Support transaction. No arbitrary APDU.
const std = @import("std");
const input = @import("input_support.zig");
const surface = @import("surface.zig");
pub const Policy = struct {
    verifies: u32 = 0,
    photo_enabled: bool = false,
    probe_only: bool = false,
    surface_selected: bool = false,
    surface_verifies: u32 = 0,
    pub fn allow(self: *Policy, frame: []const u8) bool {
        if (frame.len < 10 or frame[5] != 0 or frame[7] != 0 or frame[8] != 0 or frame[9] != 0 or
            std.mem.readInt(u32, frame[1..5], .little) != frame.len - 10) return false;
        const apdu = frame[10..];
        if (frame[0] == 0x62 or frame[0] == 0x63) return apdu.len == 0;
        if (frame[0] != 0x6f) return false;
        if (self.photo_enabled and std.mem.eql(u8, apdu, &surface.select_number)) return !self.surface_selected and self.verifies == 1;
        if (self.photo_enabled and std.mem.eql(u8, apdu, &surface.select_ap)) {
            if ((!self.probe_only and self.verifies != 1) or self.surface_selected) return false;
            self.surface_selected = true;
            return true;
        }
        if (self.surface_selected) {
            if (std.mem.eql(u8, apdu, &surface.select_pin) or std.mem.eql(u8, apdu, &surface.select_photo) or std.mem.eql(u8, apdu, &input.query_retries)) return true;
            if (apdu.len == 5 and apdu[0] == 0 and apdu[1] == 0xb0 and apdu[2] < 128 and apdu[3] == 0 and apdu[4] == 0) return true;
            if (self.probe_only or self.surface_verifies != 0 or apdu.len != 17 or !std.mem.eql(u8, apdu[0..5], &.{ 0, 0x20, 0, 0x80, 12 })) return false;
            for (apdu[5..]) |digit| if (digit < '0' or digit > '9') return false;
            self.surface_verifies = 1;
            return true;
        }
        for ([_][]const u8{ &input.select_ap, &input.select_pin, &input.query_retries, &input.select_attributes }) |permitted|
            if (std.mem.eql(u8, apdu, permitted)) return true;
        if (apdu.len == 5 and apdu[0] == 0 and apdu[1] == 0xb0 and apdu[2] < 8 and apdu[3] == 0 and apdu[4] == 0) return true;
        if (self.probe_only or apdu.len != 9 or !std.mem.eql(u8, apdu[0..5], &.{ 0, 0x20, 0, 0x80, 4 }) or self.verifies != 0) return false;
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
test "photo opt-in has independent one-shot budgets and PIN-free probe cannot send credentials" {
    const ccid = @import("ccid");
    var buffer: [512]u8 = undefined;
    var legacy = Policy{};
    try std.testing.expect(!legacy.allow(try ccid.request(&buffer, 0x6f, 0, &surface.select_ap)));
    var policy = Policy{ .photo_enabled = true };
    try std.testing.expect(!policy.allow(try ccid.request(&buffer, 0x6f, 0, &surface.select_number)));
    try std.testing.expect(!policy.allow(try ccid.request(&buffer, 0x6f, 0, &surface.select_ap)));
    const pin4 = [_]u8{ 0, 0x20, 0, 0x80, 4, '1', '2', '3', '4' };
    const pin12 = [_]u8{ 0, 0x20, 0, 0x80, 12 } ++ "123456789018";
    try std.testing.expect(policy.allow(try ccid.request(&buffer, 0x6f, 0, &pin4)));
    try std.testing.expect(policy.allow(try ccid.request(&buffer, 0x6f, 0, &surface.select_number)));
    try std.testing.expect(policy.allow(try ccid.request(&buffer, 0x6f, 0, &surface.select_ap)));
    try std.testing.expect(policy.allow(try ccid.request(&buffer, 0x6f, 0, pin12)));
    try std.testing.expect(!policy.allow(try ccid.request(&buffer, 0x6f, 0, pin12)));
    try std.testing.expect(!policy.allow(try ccid.request(&buffer, 0x6f, 0, &pin4)));
    var probe = Policy{ .photo_enabled = true, .probe_only = true };
    try std.testing.expect(!probe.allow(try ccid.request(&buffer, 0x6f, 0, &pin4)));
    try std.testing.expect(probe.allow(try ccid.request(&buffer, 0x6f, 0, &surface.select_ap)));
    try std.testing.expect(probe.allow(try ccid.request(&buffer, 0x6f, 0, &input.query_retries)));
    try std.testing.expect(!probe.allow(try ccid.request(&buffer, 0x6f, 0, pin12)));
    try std.testing.expectEqual(@as(u32, 0), probe.verifies + probe.surface_verifies);
}
