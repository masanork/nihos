//! Host-testable root of the nihOS implementation.
//!
//! Hardware-specific code will live below `arch`, `soc`, and `board`. The
//! kernel imports only the stable platform ABI, never ESP-IDF headers.

pub const ccid = @import("ccid");
pub const jpki = @import("usb/jpki.zig");
pub const card_input_support = @import("card/input_support.zig");
pub const card_service = @import("card/service.zig");
pub const card_pin_entry = @import("card/pin_entry.zig");
pub const card_ccid_owner = @import("card/ccid_owner.zig");
pub const tab5_touch = @import("board/tab5/touch.zig");
pub const tab5_touch_feedback = @import("board/tab5/touch_feedback.zig");
pub const card_pin_graphics = @import("graphics/card_pin.zig");
pub const keypad_demo = @import("card/keypad_demo.zig");
pub const keypad_plan = @import("graphics/keypad_plan.zig");
pub const usb_host = @import("soc/esp32p4/usb_host.zig");
pub const usb_descriptors = @import("usb/descriptors.zig");
pub const boot_i2c = @import("board/tab5/boot_i2c.zig");
pub const version = "0.0.0";
pub const block_reader = @import("storage/block.zig");
pub const record_log = @import("diagnostics/record.zig");
pub const native_stack_layout = @import("platform/native/stack_layout.zig");
pub const riscv32_context = @import("arch/riscv32/context.zig");
pub const riscv32_trap = @import("arch/riscv32/trap.zig");
pub const esp32p4_timer_group = @import("soc/esp32p4/timer_group.zig");
pub const esp32p4_software_ipi = @import("soc/esp32p4/software_ipi.zig");
pub const esp32p4_psram = @import("soc/esp32p4/psram.zig");
pub const esp32p4_sdmmc = @import("soc/esp32p4/sdmmc.zig");
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
pub const console = @import("console.zig");
pub const boot_graphics = @import("graphics/boot_graphics.zig");
pub const tab5_boot_i2c = @import("board/tab5/boot_i2c.zig");
pub const tab5_display = @import("board/tab5/display.zig");
pub const psram_tuning = @import("soc/esp32p4/psram_tuning.zig");
pub const psram_mpll = @import("soc/esp32p4/psram_mpll.zig");
pub const cpu_clock = @import("soc/esp32p4/cpu_clock.zig");
pub const tab5_panels = @import("board/tab5/panels.zig");
pub const display_dcs = @import("board/tab5/dcs.zig");
pub const scanout_state = @import("board/tab5/scanout_state.zig");
pub const platform_abi = @import("platform/abi.zig");
pub const esp_at = @import("net/esp_at.zig");
pub const at_controller = @import("net/at_controller.zig");
pub const c6_sdio = @import("net/c6_sdio.zig");
pub const esp32p4_sdio = @import("soc/esp32p4/sdio.zig");

test {
    _ = @import("platform/native/foreground_timer.zig");
    _ = cpu_clock;
    _ = ccid;
    _ = jpki;
    _ = card_input_support;
    _ = card_service;
    _ = card_pin_entry;
    _ = card_ccid_owner;
    _ = tab5_touch;
    _ = tab5_touch_feedback;
    _ = card_pin_graphics;
    _ = keypad_demo;
    _ = keypad_plan;
    _ = @import("graphics/keypad_atlas_test.zig");
    _ = @import("graphics/card_read_result.zig");
    _ = @import("card/wire_policy.zig");
    _ = @import("card/surface.zig");
    _ = @import("card/license.zig");
    _ = @import("card/presence.zig");
    _ = @import("card/extended_test.zig");
    _ = @import("card/jis0208.zig");
    _ = @import("card/service_test.zig");
    _ = usb_host;
    _ = usb_descriptors;
    _ = boot_i2c;
    _ = block_reader;
    _ = record_log;
    _ = native_stack_layout;
    _ = riscv32_context;
    _ = riscv32_trap;
    _ = esp32p4_timer_group;
    _ = esp32p4_software_ipi;
    _ = esp32p4_psram;
    _ = esp32p4_sdmmc;
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
    _ = @import("kernel/size_pool_test.zig");
    _ = @import("kernel/c_allocator_test.zig");
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
    _ = boot_graphics;
    _ = console;
    _ = tab5_boot_i2c;
    _ = @import("board/tab5/rtc.zig");
    _ = @import("board/tab5/bmi270.zig");
    _ = @import("board/tab5/es8388.zig");
    _ = @import("audio/tone.zig");
    _ = @import("audio/playback_probe.zig");
    _ = @import("net/ble_hci.zig");
    _ = tab5_display;
    _ = tab5_panels;
    _ = display_dcs;
    _ = scanout_state;
    _ = @import("platform/native/external_layout.zig");
    _ = psram_mpll;
    _ = psram_tuning;
    _ = platform_abi;
    _ = esp_at;
    _ = @import("net/esp_at_test.zig");
    _ = at_controller;
    _ = @import("net/at_controller_test.zig");
    _ = @import("net/wifi_station_test.zig");
    _ = @import("net/hosted_test.zig");
    _ = @import("net/ipv6_test.zig");
    _ = c6_sdio;
    _ = @import("net/c6_sdio_test.zig");
    _ = @import("net/c6_link_test.zig");
    _ = esp32p4_sdio;
    _ = @import("soc/esp32p4/sdio_test.zig");
}

test "Tab5 scanout reservation uses identity-mapped PSRAM pages" {
    const std = @import("std");
    for ([_]u32{ 4, 8, 16, 32, 64 }) |mib| {
        const capacity = mib * 1024 * 1024;
        const selected = tab5_display.layout(capacity).?;
        const first = (selected.frame_start - esp32p4_psram_mapping.virtual_base) / esp32p4_psram_mapping.page_bytes;
        for (0..tab5_display.reserve_bytes / esp32p4_psram_mapping.page_bytes) |offset| {
            const page = first + @as(u32, @intCast(offset));
            try std.testing.expectEqual(page, esp32p4_psram_mapping.physicalPage(capacity, page).?);
        }
    }
}

test {
    _ = @import("card/license_crypto.zig");
    _ = @import("card/license_trust.zig");
    _ = @import("card/license_session_test.zig");
}
