const std = @import("std");
const p = @import("hosted_c6_time_policy.zig");
test "valid C6 clock becomes a bounded P4 sample" {
    const result = p.decide(.{ .seconds = 1_793_533_453, .age_seconds = p.max_sync_age }, 17);
    try std.testing.expectEqual(@as(u64, 1_793_533_453_000_000), result.sample.?.unix_us);
    try std.testing.expectEqual(@as(u64, 17), result.sample.?.received);
    try std.testing.expectEqual(@import("sntp.zig").resync, result.delay);
}
test "unavailable, stale and invalid samples cannot be applied" {
    try std.testing.expect(p.decide(null, 0).sample == null);
    for ([_]@import("hosted_c6_time.zig").Sample{
        .{ .seconds = 946_684_799, .age_seconds = 0 },
        .{ .seconds = 4_102_444_800, .age_seconds = 0 },
        .{ .seconds = 1_793_533_453, .age_seconds = p.max_sync_age + 1 },
    }) |value| {
        const result = p.decide(value, 0);
        try std.testing.expect(result.sample == null and result.rejected);
        try std.testing.expectEqual(p.retry_rejected, result.delay);
    }
}
test "clock reset, address change, and stale delivery retire the sample" {
    const value = p.decide(.{ .seconds = 1_793_533_453, .age_seconds = 0 }, 10).sample;
    for ([_]struct { now: u64, current: bool }{ .{ .now = 9, .current = true }, .{ .now = 11, .current = false }, .{ .now = 5_000_011, .current = true } }) |case| {
        var slot = value;
        try std.testing.expect(p.take(&slot, case.now, case.current) == null);
        try std.testing.expect(slot == null);
    }
    var slot = value;
    try std.testing.expect(p.take(&slot, 5_000_010, true) != null);
    try std.testing.expect(slot == null);
}
