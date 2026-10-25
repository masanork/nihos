# Physical Tab5 periodic-timer smoke

- Date: 2026-10-25
- Firmware commit: `422258e38cbe9fd4fa675907b49f48f6ea29fe13`
- Board: M5Stack Tab5, ESP32-P4 revision 1.3
- Backend: ESP-IDF v5.4.4 bring-up oracle; FreeRTOS still owns interrupts and
  scheduling
- Platform ABI: 5

## Result

The Zig callback observed 128 interrupts from a 1,000 us GPTimer period in
128,235 us. Timer start, callback delivery, atomic tick accumulation, drain,
and stop all completed successfully.

The same boot also completed the existing 100,000-message SMP mailbox, all
four internal/PSRAM AXI-GDMA paths, display scanout and 60-vsync measurement,
and idle touch sampling. Display refresh measured 65.466 Hz.

## Interpretation

This qualifies the periodic interrupt ABI on the physical board and checks
that it does not regress the current bootstrap path. It does not qualify a
native nihOS timer, trap entry, context switch, preemption latency, or timing
under Quake/audio load; the callback is allocated and dispatched by ESP-IDF.
