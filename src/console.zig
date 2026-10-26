//! Diagnostic console foundation. Font files and Unicode composition are optional services.
pub const Journal = @import("diagnostics/boot_journal.zig").Journal;
pub const boot = @import("diagnostics/boot_state.zig");
pub const Grid = @import("console/ascii.zig").Grid;
pub const snapshot = @import("console/snapshot.zig");
pub const raster = @import("graphics/ascii_console.zig");
test {
    _ = @import("diagnostics/boot_journal.zig");
    _ = boot;
    _ = @import("console/ascii.zig");
    _ = raster;
    _ = snapshot;
}
