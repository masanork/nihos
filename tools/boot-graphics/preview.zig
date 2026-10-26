//! Host bridge: previews call the firmware renderer itself.
const boot = @import("boot_graphics");

export fn nih_boot_preview(data: [*]u8, length: usize, progress: u8, state: u8) bool {
    if (state < 1 or state > 6) return false;
    const status: boot.Status = @fromBackingInt(@intCast(state));
    return boot.paintRgb565Le(data[0..length], boot.width, boot.height, boot.width * 2, progress, status);
}
