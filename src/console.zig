//! Diagnostic console foundation. Font files and Unicode composition are optional services.
pub const keys = @import("console/diagnostic_keys.zig");
pub const session = @import("console/session.zig");
pub const scratch = @import("xy/scratch.zig");
pub const keyboard = @import("board/tab5/keyboard.zig");
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
    _ = keys;
    _ = keyboard;
    _ = session;
    _ = session.input;
    _ = scratch;
}
