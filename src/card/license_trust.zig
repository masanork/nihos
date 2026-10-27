//! Build-time pinned public keys only. Card-supplied keys are never trusted.
const std = @import("std");
pub const record_bytes = 293;
pub const Key = struct { modulus: *const [256]u8, exponent: u32 };
pub noinline fn lookup(bytes: []const u8, id: []const u8) linksection(if (@import("builtin").os.tag == .freestanding) ".flash.photo" else if (@import("builtin").os.tag == .macos) "__TEXT,__text" else ".text") ?Key {
    if (bytes.len % record_bytes != 0 or bytes.len > 64 * record_bytes or id.len == 0 or id.len > 32) return null;
    var found: ?Key = null;
    var at: usize = 0;
    while (at < bytes.len) : (at += record_bytes) {
        const row = bytes[at..][0..record_bytes];
        if (row[0] == 0 or row[0] > 32) return null;
        if (row[0] == id.len and std.mem.eql(u8, row[1..][0..id.len], id)) {
            if (found != null) return null;
            found = .{ .modulus = row[33..289], .exponent = std.mem.readInt(u32, row[289..293], .big) };
        }
    }
    return found;
}
pub fn Store(comptime section: ?[]const u8) type {
    return struct {
        const data: [@embedFile("license_trust.bin").len]u8 align(4) linksection(section orelse if (@import("builtin").os.tag == .macos) "__TEXT,__const" else ".rodata") = @embedFile("license_trust.bin").*;
        pub fn find(id: []const u8) ?Key {
            return lookup(&data, id);
        }
    };
}
test "only pinned unique key identifiers can select a verifier key" {
    var rows: [record_bytes * 2]u8 = @splat(0);
    rows[0] = 1;
    rows[1] = 7;
    rows[289] = 0;
    rows[290] = 1;
    rows[291] = 0;
    rows[292] = 1;
    try std.testing.expect(lookup(rows[0..record_bytes], &.{7}) != null);
    try std.testing.expect(lookup(rows[0..record_bytes], &.{8}) == null);
    @memcpy(rows[record_bytes..], rows[0..record_bytes]);
    try std.testing.expect(lookup(&rows, &.{7}) == null);
    try std.testing.expect(Store(null).find(&.{7}) == null);
}
