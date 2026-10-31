//! Foreground publication policy. Background logs never invalidate a frozen xy view.
const std = @import("std");
const section = if (@import("builtin").os.tag == .freestanding) ".flash.xytext" else if (@import("builtin").object_format == .macho) "__TEXT,__text" else ".text";
pub const Reasons = struct { content: bool, view: bool, overwritten: bool, background: bool };
pub inline fn needed(reasons: Reasons) bool {
    return reasons.content or reasons.view or reasons.overwritten;
}
pub const Stats = struct { bytes: usize = 0, chunks: usize = 0 };
pub const Error = error{InvalidFrame};
/// Publish only a completed frame. Unchanged cache lines remain untouched; no
/// intermediate background clear reaches scanout. This is not a VSYNC swap.
pub noinline fn publish(completed: []const u8, visible: []u8) linksection(section) Error!Stats {
    if (completed.len == 0 or completed.len != visible.len or completed.len % 2 != 0) return error.InvalidFrame;
    var stats = Stats{};
    var start: usize = 0;
    while (start < completed.len) {
        const end = @min(start + 64, completed.len);
        if (!std.mem.eql(u8, completed[start..end], visible[start..end])) {
            @memcpy(visible[start..end], completed[start..end]);
            stats.bytes += end - start;
            stats.chunks += 1;
        }
        start = end;
    }
    return stats;
}
test "idle background logs do not invalidate xy; edits views and overwritten frames do" {
    try std.testing.expect(!needed(.{ .content = false, .view = false, .overwritten = false, .background = true }));
    try std.testing.expect(needed(.{ .content = true, .view = false, .overwritten = false, .background = false }));
    try std.testing.expect(needed(.{ .content = false, .view = true, .overwritten = false, .background = false }));
    try std.testing.expect(needed(.{ .content = false, .view = false, .overwritten = true, .background = false }));
}
test "completed-frame publication changes only differing chunks and leaves guards intact" {
    var visible: [144]u8 = @splat(0xa5);
    var completed: [128]u8 = @splat(0xa5);
    const idle = try publish(&completed, visible[0..128]);
    try std.testing.expectEqual(@as(usize, 0), idle.bytes);
    completed[67] = 0x11;
    completed[68] = 0x22;
    const changed = try publish(&completed, visible[0..128]);
    try std.testing.expectEqual(@as(usize, 64), changed.bytes);
    try std.testing.expectEqual(@as(usize, 1), changed.chunks);
    try std.testing.expectEqualSlices(u8, &completed, visible[0..128]);
    try std.testing.expectEqualSlices(u8, &(@as([16]u8, @splat(0xa5))), visible[128..]);
    const before = visible;
    try std.testing.expectError(error.InvalidFrame, publish(completed[0..127], visible[0..128]));
    try std.testing.expectEqualSlices(u8, &before, &visible);
}
