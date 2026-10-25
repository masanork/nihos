# ESP-EMU periodic timer interrupt validation

- Date: 2026-10-25
- Evidence: emulator-executed ESP-IDF-hosted target firmware
- ESP-EMU: 0.50.0
- ESP-IDF: 5.4.4
- Zig: 0.17.0, `-Osafe`
- Platform ABI: 5
- Timer period: 1,000 microseconds

## Method

The platform ABI configures one auto-reloading ESP32-P4 GPTimer at 1 MHz. Its
alarm callback runs in interrupt context and calls the Zig entry that publishes
one tick to the saturating atomic counter. The foreground bootstrap performs no
timer polling through ESP-IDF; it waits only on the Zig counter, stops and
releases the timer after at least 128 ticks, then emits the core-smoke marker.

## Emulator result

ESP-EMU delivered exactly 128 observed ticks in 128,049 emulated microseconds.
The subsequent `periodic_timer=ok` and `nihos: core smoke complete` markers
were reached after the earlier two-core mailbox validation.

## Boundary

This proves that the ESP-IDF GPTimer ISR can cross the ABI into the freestanding
Zig code and publish periodic ticks under the emulator. ESP-IDF still allocates
the interrupt and controls GPTimer setup; FreeRTOS still owns task execution.
It is not evidence of native CLIC/trap entry, context switching, physical timer
jitter, Flash-cache-off safety, or task preemption. Those require native and
physical-device validation.
