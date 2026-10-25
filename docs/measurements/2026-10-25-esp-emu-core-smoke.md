# ESP-EMU ESP32-P4 core smoke

- Date: 2026-10-25
- Evidence: emulator-executed ESP-IDF-hosted target firmware
- ESP-EMU: 0.50.0
- ESP-IDF: 5.4.4
- Zig: 0.17.0, `-Osafe`
- Emulated chip revision: 3.1
- Emulated CPU count: 2
- Emulated PSRAM: 32 MiB

## Method

Build the ordinary ESP-IDF-hosted Zig entry against a separate revision-3
sdkconfig, merge the complete Flash image, and boot it through the ESP32-P4 ROM
in ESP-EMU. Exit successfully only after the serial marker
`nihos: core smoke complete` appears.

The marker is emitted after ABI discovery, bounded internal-RAM and PSRAM
allocator checks, PSRAM cache synchronization, and 100,000 ordered SPSC
request/completion pairs between CPU0 and CPU1. It deliberately precedes the
AXI-GDMA, Tab5 display, and touch checks because those require peripheral
models or physical board behavior outside this smoke's contract.

## Initial result

The firmware reached the marker with CPU0 as caller and CPU1 as worker. All
100,000 mailbox pairs were validated, with no missing, reordered, duplicated,
or corrupted response. The emulator reported 11,761 microseconds for the
busy-polled exchange; this timing is recorded only to make gross regressions
visible and is not a hardware performance claim.

## Remaining gates

The current image still relies on ESP-IDF and FreeRTOS for boot, secondary-core
startup, stacks, affinity, and scheduling. Add native timer, trap, scheduler,
IPI, syscall, and process-lifecycle scenarios as those implementations land.
Promote the workflow to an automatic gate only when those scenarios offer
stable signal relative to its build cost.

Physical Tab5 tests remain mandatory for power sequencing, real DMA and cache
behavior, display and touch, audio, SD and Flash persistence, timing, and
endurance.
