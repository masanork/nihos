//! Host-testable root of the nihOS implementation.
//!
//! Hardware-specific code will live below `arch`, `soc`, and `board`. The
//! kernel imports only the stable platform ABI, never ESP-IDF headers.

pub const version = "0.0.0";
pub const arena = @import("kernel/arena.zig");
pub const spsc_ring = @import("kernel/spsc_ring.zig");
pub const test_pattern = @import("graphics/test_pattern.zig");
pub const platform_abi = @import("platform/abi.zig");

test {
    _ = arena;
    _ = spsc_ring;
    _ = test_pattern;
    _ = platform_abi;
}
