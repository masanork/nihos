//! Integer plot parameters shared by Scheme and Canvas, without allocation.
const std = @import("std");
pub const data_section = if (@import("builtin").os.tag == .freestanding) ".flash.xyrodata" else if (@import("builtin").object_format == .macho) "__TEXT,__const" else ".rodata";
pub const Config = struct {
    amplitude: u8 = 75, // Percentage of half the plot height.
    phase: u8 = 0,
    color1: u32 = 0x182cce,
    color2: u32 = 0xd66531,
};
pub const State = struct {
    enabled: bool = false,
    ticks: i32 = 0, // Fixed-step counter modulo 2^31 for the integer VM.
    paused: bool = false,
    speed: u8 = 2,
    plot: Config = .{},
};
pub const sine linksection(data_section) = table: {
    @setEvalBranchQuota(10_000);
    var result: [256]i16 = undefined;
    for (&result, 0..) |*value, n| value.* = @intFromFloat(@sin(@as(f64, @floatFromInt(n)) * 2 * std.math.pi / 256) * 30_000);
    break :table result;
};
