//! CPU0 display/diagnostic owner; kept separate from scheduler compilation.
pub const probe = @import("display_probe.zig");
pub const runtime = @import("display_runtime.zig");
pub const ui = @import("diagnostic_ui.zig");
