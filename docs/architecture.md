# Architecture bootstrap

nihos is built as a vertical Tab5 port first. It does not begin with a generic
HAL designed in isolation.

```text
applications and optional WASM
              |
       kernel services
     VFS / IPC / handles
              |
        nihOS kernel
 scheduler / memory / SMP
              |
       stable platform ABI
       /                 \
ESP-IDF bring-up       native ESP32-P4
backend                backend
       \                 /
             Tab5 board
```

## Layers

- `kernel/`: scheduling policy, capabilities, IPC, VFS, and resource tables.
- `arch/riscv32/`: traps, atomics, context frames, privilege, and PMP.
- `soc/esp32p4/`: CPU startup, interrupts, cache, DMA, PSRAM, and Flash rules.
- `board/tab5/`: pins, power sequencing, display, touch, audio, SD, and C6
  connections.
- `compat/espidf/`: the only place that may include ESP-IDF headers.
- `fs/`: a small VFS, a direct littlefs adapter for internal NOR, and a
  removable-media backend for SD.

Directories are introduced only when their first tested implementation is
added. The current `src/platform` module establishes the ABI layout first.

## Two backends

The ESP-IDF backend is a bring-up oracle. It proves hardware sequences and
provides a known implementation against which the native backend can be
measured. It may use FreeRTOS SMP temporarily.

The native backend uses the Espressif boot path and licensed low-level support
but owns scheduling, interrupts, resources, and services. Kernel code must not
know which backend provided the platform ABI.

## Hardware contracts

The platform boundary models resources, not generic convenience calls.

- Display scanout owns framebuffer format, stride, rotation, and vsync.
- DMA buffers carry direction, alignment, lifetime, and cache state.
- Block devices report erase and transfer geometry and removable-media state.
- CPU startup defines the shared-memory and interrupt protocol before CPU1 is
  allowed to call any service.
- Flash writes require an explicit guard that prevents unsafe execution or
  PSRAM access on the other core.

## Storage direction

- Internal NOR configuration and small writable state: littlefs core with a
  nihOS block adapter.
- Large Quake PAK files and media: SD FAT/exFAT with large batched reads.
- Immutable boot assets: a simple read-only packed partition if measurements
  justify it.
- M5FS implementation: not imported. Its atomic-replace and fault-test
  requirements are retained as specifications.

## Bring-up order

1. Host ABI and data-structure tests.
2. ESP-IDF boot and serial output through the C ABI.
3. Internal allocator, PSRAM discovery, and cache/DMA tests.
4. Display scanout and vsync, then touch input.
5. Timer interrupts and a single-core scheduler.
6. CPU1 startup, IPI, atomics, and bounded cross-core rings.
7. Block I/O, littlefs, and fault injection.
8. Audio, SD assets, C6 networking, and performance applications.

Every stage records whether evidence is host-only, ESP-IDF-hosted, native
firmware, or physical Tab5 behavior.

The first two stages are complete as of 2026-10-25. Stage 2 is physical Tab5
evidence, but remains ESP-IDF-hosted: ESP-IDF and FreeRTOS still own boot,
interrupt setup, and scheduling before control crosses the platform ABI into
Zig.
