//! Last transport boundary for one Input Support transaction. No arbitrary APDU.
const std = @import("std");
const input = @import("input_support.zig");
const surface = @import("surface.zig");
const license = @import("license.zig");
pub const Profile = enum { mynumber, detection, license };
pub fn PolicyType(comptime extended: bool) type {
    return struct {
        const Self = @This();
        fn placement() []const u8 {
            return if (extended and @import("builtin").os.tag == .freestanding) ".flash.photo" else if (@import("builtin").os.tag == .macos) "__TEXT,__text" else ".text";
        }
        profile: Profile = .mynumber,
        license_context: enum { none, mf, common, photo } = .none,
        license_pin: u8 = 0,
        license_file: usize = 0,
        license_offset: usize = 0,
        verifies: u32 = 0,
        photo_enabled: bool = false,
        probe_only: bool = false,
        surface_selected: bool = false,
        surface_verifies: u32 = 0,
        pub fn allow(self: *Self, frame: []const u8) linksection(placement()) bool {
            if (frame.len < 10 or frame[5] != 0 or frame[7] != 0 or frame[8] != 0 or frame[9] != 0 or
                std.mem.readInt(u32, frame[1..5], .little) != frame.len - 10) return false;
            const apdu = frame[10..];
            if (frame[0] == 0x62 or frame[0] == 0x63) return apdu.len == 0;
            if (frame[0] == 0x65) return extended and apdu.len == 0;
            if (frame[0] != 0x6f) return false;
            if (extended and self.profile == .detection) return std.mem.eql(u8, apdu, &input.select_ap) or std.mem.eql(u8, apdu, &license.select_df1);
            if (extended and self.profile == .license) return self.allowLicense(apdu);
            if (self.profile != .mynumber) return false;
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
        fn allowLicense(self: *Self, apdu: []const u8) linksection(placement()) bool {
            if (std.mem.eql(u8, apdu, &license.select_mf)) {
                self.license_context = .mf;
                self.license_pin = 0;
                self.license_file = 0;
                return true;
            }
            if (std.mem.eql(u8, apdu, &license.select_df1) or std.mem.eql(u8, apdu, &license.select_df2)) {
                const photo = std.mem.eql(u8, apdu, &license.select_df2);
                if (self.verifies != 1 or (photo and self.surface_verifies != 1)) return false;
                self.license_context = if (photo) .photo else .common;
                self.license_pin = 0;
                self.license_file = 0;
                return true;
            }
            if (self.license_context == .mf) {
                if (std.mem.eql(u8, apdu, &license.select_pin_setting)) {
                    if (self.verifies != 0 or self.surface_verifies != 0) return false;
                    self.license_file = 3;
                    self.license_pin = 0;
                    return true;
                }
                if (self.license_file == 3 and std.mem.eql(u8, apdu, &.{ 0, 0xb0, 0, 0, 3 })) {
                    self.license_file = 0;
                    return true;
                }
                if (std.mem.eql(u8, apdu, &license.select_pin1) or std.mem.eql(u8, apdu, &license.select_pin2)) {
                    self.license_file = 0;
                    self.license_pin = if (std.mem.eql(u8, apdu, &license.select_pin1)) 1 else 2;
                    return true;
                }
                if (self.license_pin == 0) return false;
                if (std.mem.eql(u8, apdu, &input.query_retries)) return true;
                if (self.probe_only or apdu.len != 9 or !std.mem.eql(u8, apdu[0..5], &.{ 0, 0x20, 0, 0x80, 4 })) return false;
                for (apdu[5..]) |digit| if (digit < '0' or digit > '9') return false;
                if (self.license_pin == 1) {
                    if (self.verifies != 0) return false;
                    self.verifies = 1;
                } else {
                    if (self.verifies != 1 or self.surface_verifies != 0) return false;
                    self.surface_verifies = 1;
                }
                return true;
            }
            if (self.license_context == .none) return false;
            if (std.mem.eql(u8, apdu, &license.select_pin1)) {
                self.license_file = if (self.license_context == .common) license.common_bytes else license.photo_bytes;
                self.license_offset = 0;
                return true;
            }
            if (apdu.len != 5 or self.license_file == 0 or self.license_offset >= self.license_file or apdu[0] != 0 or apdu[1] != 0xb0) return false;
            const offset = @as(usize, apdu[2]) << 8 | apdu[3];
            const count = if (apdu[4] == 0) @as(usize, 256) else apdu[4];
            if (offset != self.license_offset or count != @min(256, self.license_file - offset)) return false;
            self.license_offset += count;
            return true;
        }
    };
}
pub const Policy = PolicyType(false);
pub const ExtendedPolicy = PolicyType(true);

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
