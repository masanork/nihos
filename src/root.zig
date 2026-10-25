//! Host-testable root of the nihOS implementation.
//!
//! Hardware-specific code will live below `arch`, `soc`, and `board`. The
//! kernel imports only the stable platform ABI, never ESP-IDF headers.

pub const version = "0.0.0";
pub const arena = @import("kernel/arena.zig");
pub const test_pattern = @import("graphics/test_pattern.zig");
pub const platform_abi = @import("platform/abi.zig");

test {
    _ = arena;
    _ = test_pattern;
    _ = platform_abi;
}
