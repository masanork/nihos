# ESP-IDF-hosted Zig bootstrap on Tab5

- Date: 2026-10-25
- Evidence: physical M5Stack Tab5, ESP-IDF-hosted firmware
- SoC: ESP32-P4 revision 1.3
- ESP-IDF: v5.4.4
- Zig: 0.17.0, `-Osafe`, freestanding RISC-V static library

This checkpoint proves that the vendor boot path can link and call a
freestanding Zig entry through the handwritten nihOS C ABI. It also transfers
bounded internal-RAM and PSRAM regions to Zig-owned boot arenas and exercises
aligned cache writeback and invalidation. A real AXI-GDMA engine copies data
across internal RAM and PSRAM. ESP-IDF and FreeRTOS SMP still own startup and
scheduling; this is not the native nihOS kernel.

## Firmware size

ESP-IDF reported:

| Measurement | Bytes |
| --- | ---: |
| Application image | 194,912 (`0x2f960`) |
| Flash text | 87,670 |
| Flash read-only data | 40,076 |
| DIRAM text | 56,266 |
| DIRAM data | 10,169 |
| DIRAM BSS | 6,016 |

The default 1 MiB application partition had 853,664 bytes (81%) free. Adding
the public ESP-IDF async-copy driver and the Zig probe increased the binary by
22,240 bytes over the arena-and-cache checkpoint.

## Physical boot result

The firmware was flashed through `/dev/cu.usbmodem101`. The first boot printed:

```text
nihos: Zig kernel entry
abi=1
chip_revision=103
cpu_count=2
internal_heap_bytes=524167
psram_heap_bytes=33554432
flash_bytes=16777216
internal_arena_bytes=65536
internal_allocator=ok
psram_arena_bytes=1048576
psram_allocator=ok
psram_cache_sync=ok
dma_bytes_per_path=131072
dma_internal_to_internal_us=1467
dma_internal_to_psram_us=1401
dma_psram_to_internal_us=1413
dma_psram_to_psram_us=1638
axi_gdma_copy=ok
nihos: bootstrap complete
```

The `chip_revision` value is ESP-IDF's integer encoding for revision 1.3.
The two-core value confirms that the bring-up backend was built with FreeRTOS
SMP enabled; it does not yet demonstrate a nihOS scheduler running work on
both cores. The cache result covers aligned 128-byte ranges using ESP-IDF's
cache-to-memory and memory-to-cache operations.

## AXI-GDMA copy baseline

Each path copied a 16 KiB buffer eight times and verified every destination
byte after the DMA interrupt. The table summarizes three independent boots.

| Source to destination | Elapsed range for 128 KiB | Mean throughput |
| --- | ---: | ---: |
| internal to internal | 1,467-1,470 us | 85.13 MiB/s |
| internal to PSRAM | 1,400-1,401 us | 89.24 MiB/s |
| PSRAM to internal | 1,413-1,414 us | 88.42 MiB/s |
| PSRAM to PSRAM | 1,637-1,640 us | 76.30 MiB/s |

The timing starts after the AXI-GDMA driver is installed. It includes each
ESP-IDF transaction's descriptor setup, driver-managed cache work, interrupt,
and semaphore wakeup. The explicit caller-side cache transitions surrounding
the transaction are outside the timer. These are bring-up baselines, not peak
bandwidth claims and not display scanout measurements.

## Recovery evidence

Before flashing, the complete 16 MiB device Flash was read to a local recovery
image that is not checked into the repository.

```text
size:   16777216 bytes
sha256: 138032f70f24da232aa0efbbb3c039e03c34156f857d14243f46a8abfe7df754
```

## Remaining gates

- add reusable allocation classes beyond the monotonic boot arenas;
- bring up display scanout and vsync;
- replace FreeRTOS scheduling with the native nihOS path before making native
  kernel or SMP claims.
