//! Panel policy and packed, licensed BSP command tables; no hardware access.
const std = @import("std");
pub const Timing = extern struct { lane_mbps: u32, dpi_mhz: u32, hbp: u32, hsw: u32, hfp: u32, vbp: u32, vsw: u32, vfp: u32 };
pub fn timing(panel: u32) ?Timing {
    return switch (panel) {
        1 => .{ .lane_mbps = 1000, .dpi_mhz = 10, .hbp = 140, .hsw = 40, .hfp = 40, .vbp = 20, .vsw = 4, .vfp = 20 },
        2 => .{ .lane_mbps = 1000, .dpi_mhz = 10, .hbp = 40, .hsw = 2, .hfp = 40, .vbp = 8, .vsw = 2, .vfp = 220 },
        3 => .{ .lane_mbps = 960, .dpi_mhz = 10, .hbp = 40, .hsw = 2, .hfp = 40, .vbp = 24, .vsw = 20, .vfp = 200 },
        else => null,
    };
}

/// Keep the qualified 80 MHz pixel clock and vendor horizontal porches.
/// Add vertical blanking for approximately 60 complete frames per second.
pub fn sixtyHertz(panel: u32) ?Timing {
    if (panel != 2 and panel != 3) return null;
    var result = timing(panel).?;
    result.dpi_mhz = 80;
    const horizontal = 720 + result.hbp + result.hsw + result.hfp;
    const vertical = (80_000_000 + horizontal * 30) / (horizontal * 60);
    result.vfp = vertical - 1280 - result.vbp - result.vsw;
    return result;
}

/// 65 selects the vendor porch comparison (~65.45 Hz), not a rated maximum.
pub fn refreshProfile(panel: u32, target_hz: u32) ?Timing {
    if (target_hz == 60) return sixtyHertz(panel);
    if (target_hz != 65 or (panel != 2 and panel != 3)) return null;
    var result = timing(panel).?;
    result.dpi_mhz = 80;
    return result;
}

pub fn refreshMilliHz(selected: Timing) u32 {
    const pixels = @as(u64, 720 + selected.hbp + selected.hsw + selected.hfp) *
        (1280 + selected.vbp + selected.vsw + selected.vfp);
    return @intCast(@as(u64, selected.dpi_mhz) * 1_000_000_000 / pixels);
}

test "60 Hz target keeps 80 MHz pixel clock and changes vertical blanking" {
    const original = timing(3).?;
    var nominal = original;
    nominal.dpi_mhz = 80;
    try std.testing.expectEqual(@as(u32, 65_453), refreshMilliHz(nominal));
    const selected = sixtyHertz(3).?;
    try std.testing.expectEqual(@as(u32, 80), selected.dpi_mhz);
    try std.testing.expectEqual(@as(u32, 339), selected.vfp);
    try std.testing.expectEqual(@as(u32, 59_982), refreshMilliHz(selected));
    try std.testing.expectEqual(original.hfp, selected.hfp);
    try std.testing.expectEqual(original.hbp, selected.hbp);
    try std.testing.expectEqual(original.hsw, selected.hsw);
    try std.testing.expectEqual(@as(u32, 59_982), refreshMilliHz(sixtyHertz(2).?));
    try std.testing.expect(sixtyHertz(1) == null);
    try std.testing.expectEqual(@as(u32, 65_453), refreshMilliHz(refreshProfile(3, 65).?));
    try std.testing.expect(refreshProfile(3, 61) == null);
}
pub fn table(comptime section: ?[]const u8, panel: u32) ?[]const u8 {
    const Store = if (section) |name| struct {
        const ili linksection(name) = @embedFile("panel_data/ili9881c.bin").*;
        const st3 linksection(name) = @embedFile("panel_data/st7123.bin").*;
        const st1 linksection(name) = @embedFile("panel_data/st7121.bin").*;
    } else struct {
        const ili = @embedFile("panel_data/ili9881c.bin").*;
        const st3 = @embedFile("panel_data/st7123.bin").*;
        const st1 = @embedFile("panel_data/st7121.bin").*;
    };
    return switch (panel) {
        1 => &Store.ili,
        2 => &Store.st3,
        3 => &Store.st1,
        else => null,
    };
}
pub const Command = struct { opcode: u8, payload: []const u8, delay_ms: u16 };
pub fn next(bytes: []const u8, position: *usize) error{Truncated}!?Command {
    if (position.* == bytes.len) return null;
    if (position.* > bytes.len or bytes.len - position.* < 4) return error.Truncated;
    const header = bytes[position.*..][0..4];
    const size: usize = header[1];
    if (bytes.len - position.* - 4 < size) return error.Truncated;
    const result = Command{ .opcode = header[0], .payload = bytes[position.* + 4 ..][0..size], .delay_ms = @as(u16, header[2]) | (@as(u16, header[3]) << 8) };
    position.* += 4 + size;
    return result;
}

test "all three complete command tables include display-on and fit bounded packets" {
    for (1..4) |panel| {
        const bytes = table(null, @intCast(panel)).?;
        var position: usize = 0;
        var commands: usize = 0;
        var display_on = false;
        while (try next(bytes, &position)) |command| {
            try std.testing.expect(command.payload.len <= 128 and command.delay_ms <= 1000);
            display_on = display_on or command.opcode == 0x29;
            commands += 1;
        }
        try std.testing.expect(commands > 20 and display_on);
        try std.testing.expectEqual(bytes.len, position);
        const selected = timing(@intCast(panel)).?;
        try std.testing.expectEqual(@as(u32, 10), selected.dpi_mhz);
        try std.testing.expect(selected.lane_mbps == 960 or selected.lane_mbps == 1000);
    }
    var position: usize = 0;
    try std.testing.expectError(error.Truncated, next(&.{ 1, 2, 0, 0, 1 }, &position));
    try std.testing.expectEqual(@as(usize, 0), position);
    try std.testing.expect(timing(0) == null and table(null, 4) == null);
}
