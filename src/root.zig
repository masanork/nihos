//! Host-testable root of the nihOS implementation.
//!
//! Hardware-specific code will live below `arch`, `soc`, and `board`. The
//! kernel imports only the stable platform ABI, never ESP-IDF headers.

pub const version = "0.0.0";
pub const riscv32_context = @import("arch/riscv32/context.zig");
pub const riscv32_trap = @import("arch/riscv32/trap.zig");
pub const arena = @import("kernel/arena.zig");
pub const scheduler = @import("kernel/scheduler.zig");
pub const spsc_ring = @import("kernel/spsc_ring.zig");
pub const tick_counter = @import("kernel/tick_counter.zig");
pub const test_pattern = @import("graphics/test_pattern.zig");
pub const platform_abi = @import("platform/abi.zig");

test {
    _ = riscv32_context;
    _ = riscv32_trap;
    _ = arena;
    _ = scheduler;
    _ = spsc_ring;
    _ = tick_counter;
    _ = test_pattern;
    _ = platform_abi;
}
