//! Host bridge: previews call the firmware renderer itself.
const boot = @import("boot_graphics");

export fn nih_boot_preview(data: [*]u8, length: usize, progress: u8, state: u8, landscape: bool) bool {
    if (state < 1 or state > 7) return false;
    const status: boot.Status = @fromBackingInt(@intCast(state));
    if (landscape) return boot.paintLandscapePlacedRgb565Le(null, data[0..length], boot.width, boot.height, boot.width * 2, progress, status);
    return boot.paintRgb565Le(data[0..length], boot.width, boot.height, boot.width * 2, progress, status);
}
