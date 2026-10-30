//! Finite, offscreen native integration fixture, run once by CPU0 at boot.
const adapter = @import("rust_app_probe.zig");
extern fn nih_rust_app_frame(selected: u32) callconv(.c) i32;
extern fn nih_app_probe_attach(bytes: [*]u8, len: u32, width: u32, height: u32, stride: u32) callconv(.c) i32;
extern fn nih_app_probe_detach() callconv(.c) void;
var frame: [64 * 16 * 2]u8 = undefined;

export fn nih_rust_native_fixture() callconv(.c) u32 {
    _ = adapter;
    if (nih_app_probe_attach(&frame, frame.len, 64, 16, 128) != 0) return 1;
    defer nih_app_probe_detach();
    if (nih_rust_app_frame(0) != 0 or frame[0] != 0x82 or frame[1] != 0x10) return 2;
    var ink: u32 = 0;
    for (8..16) |y| for (8..48) |x| {
        const offset = y * 128 + x * 2;
        if (frame[offset] == 0xff and frame[offset + 1] == 0xff) ink += 1;
    };
    if (ink == 0) return 3;
    if (nih_rust_app_frame(1) != 0 or frame[0] != 0x0c or frame[1] != 0x22) return 4;
    return 0;
}

/// CPU0 display owner supplies exclusive, disjoint buffers. On success only the
/// 160x80 logical rectangle at (16,16) changes; publication is the owner's job.
export fn nih_rust_owner_render(scanout: [*]u8, scanout_len: u32, scratch: [*]u8, scratch_len: u32, selected: u32) callconv(.c) i32 {
    const frame_bytes = 720 * 1280 * 2;
    const scratch_bytes = 160 * 80 * 2;
    if (scanout_len < frame_bytes or scratch_len < scratch_bytes or selected > 1) return -1;
    const a = @intFromPtr(scanout);
    const b = @intFromPtr(scratch);
    if (if (a <= b) b - a < frame_bytes else a - b < scratch_bytes) return -1;
    if (nih_app_probe_attach(scratch, scratch_bytes, 160, 80, 320) != 0) return -3;
    const result = nih_rust_app_frame(selected);
    nih_app_probe_detach();
    if (result != 0) return result;
    // Logical landscape (x,y) maps to physical (y,1279-x).
    for (0..80) |y| for (0..160) |x| {
        const source = (y * 160 + x) * 2;
        const target = ((1279 - (x + 16)) * 720 + y + 16) * 2;
        scanout[target] = scratch[source];
        scanout[target + 1] = scratch[source + 1];
    };
    return 0;
}

/// Map serial bytes into the probe's bounded two-state input model.
export fn nih_rust_owner_input(byte: u32) callconv(.c) i32 {
    return switch (byte) {
        '0' => 0,
        '1' => 1,
        else => -1,
    };
}
