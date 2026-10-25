# ESP-IDF-hosted Zig bootstrap on Tab5

- Date: 2026-10-25
- Evidence: physical M5Stack Tab5, ESP-IDF-hosted firmware
- SoC: ESP32-P4 revision 1.3
- ESP-IDF: v5.4.4
- Zig: 0.17.0, `-Osafe`, freestanding RISC-V static library

This checkpoint proves that the vendor boot path can link and call a
freestanding Zig entry through the handwritten nihOS C ABI. ESP-IDF and
FreeRTOS SMP still own startup and scheduling; this is not the native nihOS
kernel.

## Firmware size

ESP-IDF reported:

| Measurement | Bytes |
| --- | ---: |
| Application image | 170,240 (`0x29900`) |
| Flash text | 70,064 |
| Flash read-only data | 35,776 |
| DIRAM text | 54,196 |
| DIRAM data | 9,473 |
| DIRAM BSS | 6,000 |

The default 1 MiB application partition had 878,336 bytes (84%) free.

## Physical boot result

The firmware was flashed through `/dev/cu.usbmodem101`. The first boot printed:

```text
nihos: Zig kernel entry
abi=1
chip_revision=103
cpu_count=2
internal_heap_bytes=526919
psram_heap_bytes=33554432
flash_bytes=16777216
nihos: bootstrap complete
```

The `chip_revision` value is ESP-IDF's integer encoding for revision 1.3.
The two-core value confirms that the bring-up backend was built with FreeRTOS
SMP enabled; it does not yet demonstrate a nihOS scheduler running work on
both cores.

## Recovery evidence

Before flashing, the complete 16 MiB device Flash was read to a local recovery
image that is not checked into the repository.

```text
size:   16777216 bytes
sha256: 138032f70f24da232aa0efbbb3c039e03c34156f857d14243f46a8abfe7df754
```

## Remaining gates

- exercise a Zig-owned allocator against internal RAM and PSRAM;
- measure cache synchronization and DMA buffer rules;
- bring up display scanout and vsync;
- replace FreeRTOS scheduling with the native nihOS path before making native
  kernel or SMP claims.
