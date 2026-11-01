//! CPU0 display-owner copy. Publication/cache writeback stays with the caller.
const builtin = @import("builtin");
pub const text_section = if (builtin.cpu.arch == .riscv32 and builtin.os.tag == .freestanding)
    ".flash.text.rust_app"
else if (builtin.os.tag == .macos)
    "__TEXT,__text"
else
    ".text";
pub const scanout_bytes = 720 * 1280 * 2;
pub const frame_bytes = 160 * 80 * 2;
pub noinline fn copy(scanout: []u8, pixels: []const u8) linksection(text_section) bool {
    if (scanout.len != scanout_bytes or pixels.len != frame_bytes) return false;
    const a = @intFromPtr(scanout.ptr);
    const b = @intFromPtr(pixels.ptr);
    if (if (a <= b) b - a < scanout.len else a - b < pixels.len) return false;
    for (0..80) |y| for (0..160) |x| {
        const source = (y * 160 + x) * 2;
        const target = ((1279 - (x + 16)) * 720 + y + 16) * 2;
        scanout[target..][0..2].* = pixels[source..][0..2].*;
    };
    return true;
}
export fn nih_app_present_copy(scanout: [*]u8, len: u32, pixels: [*]const u8, count: u32) linksection(text_section) callconv(.c) i32 {
    return if (copy(scanout[0..len], pixels[0..count])) 0 else -1;
}
