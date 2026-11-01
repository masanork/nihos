//! CPU0 display/diagnostic owner; kept separate from scheduler compilation.
pub const probe = @import("display_probe.zig");
pub const runtime = @import("display_runtime.zig");
pub const ui = @import("diagnostic_ui.zig");
pub const keypad = @import("keypad_display.zig");
pub const canvas_pattern = @import("canvas_pattern.zig");
pub const canvas_demo_app = @import("canvas_demo_app.zig");
pub const canvas_workloads = @import("canvas_workloads.zig");

pub const xy_render_runtime = @import("xy_render_runtime.zig");
