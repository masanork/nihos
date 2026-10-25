# Independent native Zig boot, SRAM and two-core timers

- Date: 2026-10-25
- Firmware implementation: `eb1a912caabc7ac54b0f32ab36a0b8aede2078bc`
- Tools: Zig 0.17.0, ESP-IDF v5.4.4 loader/tools, ESP-EMU v0.50.0
- [Machine-readable results and artifact digests](2026-10-25-independent-native-boot.json)
- [Design and ownership boundaries](../adr/0018-independent-native-boot.md)
- [Reproduction commands](../native-boot.md)

## Result

The independently linked Zig/assembly app booted from the emulator's real
ESP32-P4 revision-3 ROM through the stock second-stage loader, with PSRAM
configured absent. The app used its own entry, stacks, BSS initialization,
CLIC trap handling, direct CPU1 startup, and two TG0 timer channels. It never
entered the ESP-IDF application startup or a FreeRTOS scheduler.

Both harts returned from an ECALL and remained in their native execution
loops. A single boot reached all three execution checkpoints and the final
`NIHOS_NATIVE_SOAK_PASS` marker, with 31 recorded heartbeat samples spanning
300 rounds. Every subsequent sample showed both harts and timers increasing.

| Observation | Result |
| --- | ---: |
| CPU0 progress counter | 299,967,199 |
| CPU1 progress counter | 599,935,883 |
| CPU0 timer interrupts | 1,200 |
| CPU1 timer interrupts | 1,200 |
| Native text, each profile | 6,338 bytes |
| SRAM reserved including both stacks and alignment | 23,008 bytes |
| Stack reservation | 8,192 bytes per hart |
| App image, each profile | 65,616 bytes |
| Merged loader/partition/app image | 131,152 bytes |

The two read-only Flash mappings contain the 256-byte app descriptor and a
four-byte compatibility marker required by the standard loader. Their image
alignment accounts for most of the 64 KiB application binary. Ordinary
runtime code/data and both stacks are in internal SRAM. These numbers are
not a comparison with the much larger hosted app, which also initializes
display, touch, DMA and other fixtures.

## Checks and evidence limits

Both device and emulator profile builds passed the structural image audit:
native SRAM entry, permitted section ranges, fixed ROM symbols, no unresolved
symbols, stack placement, ELF SHA256 embedded in the descriptor, and complete
image SHA256. Five deliberate mutations were rejected: Flash entry, invalid
descriptor, incorrect ELF digest, corrupt image digest, and truncated image.

Six log-validator regression tests passed, including a reboot, missing final
checkpoint, frozen hart/timer counters, later failure, and early termination.
ZLint reported zero errors/warnings over 32 files; ShellCheck and the RV32
contract compile passed. Existing Debug and ReleaseSafe host kernel tests
passed from their unchanged cached inputs. Those host tests do not exercise
the new MMIO startup path; the target emulator supplies that evidence.

The physical-profile image was built and audited, but was **not flashed or
boot-tested**. The shared Tab5 serial port was owned by a concurrent Quake
development operation, so this work did not access the device. There is no
physical, cold-power, PSRAM, display, scheduler integration, memory protection,
or performance qualification for this new backend yet. Progress counters
show continued execution and interrupt return, not a throughput benchmark.

Remote workflow results are recorded by GitHub Actions separately from this
local measurement; a dispatch alone is not a remote CI pass.
