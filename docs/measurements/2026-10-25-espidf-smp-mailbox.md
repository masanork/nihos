# ESP-IDF-hosted SMP mailbox validation

- Date: 2026-10-25
- Device: M5Stack Tab5, ESP32-P4 revision 1.3
- Evidence: physical hardware, ESP-IDF-hosted
- ESP-IDF: 5.4.4
- Zig: 0.17.0, `-Osafe`
- Platform ABI: 4
- Source state: clean committed tree

## Method

CPU0 creates a short-lived task pinned to CPU1 through the platform ABI. The
caller and worker exchange 100,000 eight-byte messages through two capacity-64
instances of the same Zig SPSC ring used by the host tests. CPU0 exclusively
produces requests and consumes completions; CPU1 exclusively consumes requests
and produces completions.

Each request carries a monotonic sequence and a deterministic payload. CPU1
returns the sequence and a transformed payload. CPU0 rejects any missing,
reordered, duplicated, or corrupted completion. Both tasks busy-poll for this
baseline; there is no semaphore, mutex, allocation, IPI wakeup, or console I/O
inside the measured exchange.

## Results

Three consecutive resets of the clean build completed the full bootstrap.
Every run reported:

- caller core 0 and worker core 1;
- 100,000 validated request/completion pairs;
- 20,131 to 20,133 microseconds elapsed;
- 4,966,969 to 4,967,463 completed pairs per second;
- `smp_mailbox=ok`;
- no boot error, panic, watchdog reset, or subsequent display/touch failure.

The capacity-64 request ring reported 99,873, 99,915, and 99,873 failed push
observations. These are expected fail-closed backpressure observations, not
lost messages: CPU0 retries after consuming a completion. The corresponding
empty-response observations were 1, 43, and 1.

After each exchange, direct display scanout remained about 65.466 Hz and eight
idle touch polls completed. The firmware image was 359,808 bytes and left 66%
of the 1 MiB application partition free.

## Interpretation and remaining gates

This is a throughput baseline for a pipelined request/completion transport,
not a per-request wakeup-latency result. It provides physical evidence that the
Zig release/acquire protocol and generated RV32 atomic operations preserve
ordering between the two ESP32-P4 cores under the coherent memory environment
configured by ESP-IDF.

FreeRTOS still owns CPU startup, task stacks, affinity, scheduling, and all
interrupt machinery. Busy polling also consumes both cores and is unsuitable
as the normal idle policy. Native nihOS must separately qualify secondary-core
startup, IPI-based wakeup, sleep/race handling, cancellation, saturation under
competing display and audio work, and Flash/PSRAM quiescence. No SQLite code is
linked by this test.
