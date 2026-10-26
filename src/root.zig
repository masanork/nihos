//! Host-testable root of the nihOS implementation.
//!
//! Hardware-specific code will live below `arch`, `soc`, and `board`. The
//! kernel imports only the stable platform ABI, never ESP-IDF headers.

pub const version = "0.0.0";
pub const record_log = @import("diagnostics/record.zig");
pub const riscv32_context = @import("arch/riscv32/context.zig");
pub const riscv32_trap = @import("arch/riscv32/trap.zig");
pub const esp32p4_timer_group = @import("soc/esp32p4/timer_group.zig");
pub const esp32p4_software_ipi = @import("soc/esp32p4/software_ipi.zig");
pub const esp32p4_psram = @import("soc/esp32p4/psram.zig");
pub const esp32p4_psram_supply = @import("soc/esp32p4/psram_supply.zig");
pub const esp32p4_psram_mapping = @import("soc/esp32p4/psram_mapping.zig");
pub const arena = @import("kernel/arena.zig");
pub const core_arena = @import("kernel/core_arena.zig");
pub const buddy_heap = @import("kernel/buddy_heap.zig");
pub const task_resources = @import("kernel/task_resources.zig");
pub const scheduler = @import("kernel/scheduler.zig");
pub const spsc_ring = @import("kernel/spsc_ring.zig");
pub const spsc_channel = @import("kernel/spsc_channel.zig");
pub const remote_events = @import("kernel/remote_events.zig");
pub const park = @import("kernel/park.zig");
pub const tick_counter = @import("kernel/tick_counter.zig");
pub const tick_clock = @import("kernel/tick_clock.zig");
pub const task_control = @import("kernel/task_control.zig");
pub const fp_vectors = @import("kernel/fp_vectors.zig");
pub const test_pattern = @import("graphics/test_pattern.zig");
pub const platform_abi = @import("platform/abi.zig");

test {
    _ = record_log;
    _ = riscv32_context;
    _ = riscv32_trap;
    _ = esp32p4_timer_group;
    _ = esp32p4_software_ipi;
    _ = esp32p4_psram;
    _ = esp32p4_psram_supply;
    _ = esp32p4_psram_mapping;
    _ = @import("soc/esp32p4/psram_mapping_test.zig");
    _ = @import("soc/esp32p4/psram_test.zig");
    _ = arena;
    _ = core_arena;
    _ = buddy_heap;
    _ = task_resources;
    _ = @import("kernel/task_resources_test.zig");
    _ = @import("kernel/task_pools_test.zig");
    _ = task_resources.slab;
    _ = @import("kernel/slab_test.zig");
    _ = @import("kernel/buddy_heap_test.zig");
    _ = scheduler;
    _ = spsc_ring;
    _ = spsc_channel;
    _ = @import("kernel/spsc_channel_test.zig");
    _ = remote_events;
    _ = @import("kernel/remote_events_test.zig");
    _ = park;
    _ = tick_counter;
    _ = tick_clock;
    _ = task_control;
    _ = fp_vectors;
    _ = @import("kernel/task_control_test.zig");
    _ = test_pattern;
    _ = platform_abi;
}
