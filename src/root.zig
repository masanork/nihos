//! Host-testable root of the nihOS implementation.
//!
//! Hardware-specific code will live below `arch`, `soc`, and `board`. The
//! kernel imports only the stable platform ABI, never ESP-IDF headers.

pub const version = "0.0.0";
pub const platform_abi = @import("platform/abi.zig");

test {
    _ = platform_abi;
}
