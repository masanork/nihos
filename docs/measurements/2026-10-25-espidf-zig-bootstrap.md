# ESP-IDF-hosted Zig bootstrap on Tab5

- Date: 2026-10-25
- Evidence: physical M5Stack Tab5, ESP-IDF-hosted firmware
- SoC: ESP32-P4 revision 1.3
- ESP-IDF: v5.4.4
- Zig: 0.17.0, `-Osafe`, freestanding RISC-V static library

This checkpoint proves that the vendor boot path can link and call a
freestanding Zig entry through the handwritten nihOS C ABI. It also transfers
bounded internal-RAM and PSRAM regions to Zig-owned boot arenas and exercises
aligned PSRAM cache writeback and invalidation. ESP-IDF and FreeRTOS SMP still
own startup and scheduling; this is not the native nihOS kernel.

## Firmware size

ESP-IDF reported:

| Measurement | Bytes |
| --- | ---: |
| Application image | 172,672 (`0x2a280`) |
| Flash text | 70,874 |
| Flash read-only data | 35,960 |
| DIRAM text | 55,022 |
| DIRAM data | 10,085 |
| DIRAM BSS | 6,008 |

The default 1 MiB application partition had 875,904 bytes (84%) free. Adding
the arenas, ABI calls, checks, and cache synchronization increased the binary
by 2,432 bytes over the serial-only checkpoint.

## Physical boot result

The firmware was flashed through `/dev/cu.usbmodem101`. The first boot printed:

```text
nihos: Zig kernel entry
abi=1
chip_revision=103
cpu_count=2
internal_heap_bytes=525527
psram_heap_bytes=33554432
flash_bytes=16777216
internal_arena_bytes=65536
internal_allocator=ok
psram_arena_bytes=1048576
psram_allocator=ok
psram_cache_sync=ok
nihos: bootstrap complete
```

The `chip_revision` value is ESP-IDF's integer encoding for revision 1.3.
The two-core value confirms that the bring-up backend was built with FreeRTOS
SMP enabled; it does not yet demonstrate a nihOS scheduler running work on
both cores. The cache result covers an aligned 128-byte PSRAM range using
ESP-IDF's cache-to-memory and memory-to-cache operations. It validates the ABI
and cache-line rules, but not a real peripheral DMA transfer.

## Recovery evidence

Before flashing, the complete 16 MiB device Flash was read to a local recovery
image that is not checked into the repository.

```text
size:   16777216 bytes
sha256: 138032f70f24da232aa0efbbb3c039e03c34156f857d14243f46a8abfe7df754
```

## Remaining gates

- add reusable allocation classes beyond the monotonic boot arenas;
- measure a real DMA transfer and its cache ownership transitions;
- bring up display scanout and vsync;
- replace FreeRTOS scheduling with the native nihOS path before making native
  kernel or SMP claims.
