# 0035: Separate internal SRAM for native stacks

Status: accepted for native emulation; physical qualification pending, 2026-10-26.

## Source-supported placement

Keep the primary 160 KiB region and its 48 KiB heap minimum. Move the stack
reservations into a separate 56 KiB writable/non-executable internal-SRAM
span, `[0x4ff60000, 0x4ff6e000)`, common to both revision profiles.

Pinned ESP-IDF v5.4.4
[application memory definitions](https://github.com/espressif/esp-idf/blob/v5.4.4/components/esp_system/ld/esp32p4/memory.ld.in)
define early silicon's high RW window as `0x4ff40000` plus
`0x80000 - CONFIG_CACHE_L2_CACHE_SIZE`. With the retained 128 KiB cache, its
end is `0x4ffa0000`. Rev3 instead excludes a low cache prefix and provides
application SRAM from `0x4ff20000` to `0x4ffaefc0`. The chosen stack span is
inside both source-defined windows and disjoint from both primary regions.
This does not resize the cache, reclaim the ROM region or initialize a new
clock/power controller.

The early
[loader script](https://github.com/espressif/esp-idf/blob/v5.4.4/components/bootloader/subproject/main/ld/esp32p4/bootloader.ld)
places ROM shared buffers, CPU1 startup stack and ROM data below `0x4ff40000`.
Those reservations remain untouched. The
[rev3 loader script](https://github.com/espressif/esp-idf/blob/v5.4.4/components/bootloader/subproject/main/ld/esp32p4/bootloader.rev3.ld)
and actual loader ELF are checked separately; old early-silicon comments
are not substituted for rev3 bounds. Audits inspect every actual allocated
loader section, including NOBITS, against both complete native regions.
The measurement records the clean pinned SDK commit and layout-file digests.

## Reservations and initialization

| Use | Span | Reservation |
| --- | --- | ---: |
| CPU0 bootstrap | `0x4ff60000..0x4ff62000` | 8 KiB |
| CPU1 bootstrap | `0x4ff62000..0x4ff64000` | 8 KiB |
| CPU0 IRQ | `0x4ff64000..0x4ff66000` | 8 KiB |
| CPU1 IRQ | `0x4ff66000..0x4ff68000` | 8 KiB |
| CPU0's three task stacks | `0x4ff68000..0x4ff6b000` | 3 x 4 KiB |
| CPU1's three task stacks | `0x4ff6b000..0x4ff6e000` | 3 x 4 KiB |

All reservation sizes are retained. IRQ/task stacks keep their 16-byte
bottom guards; bootstrap stacks gain the same-size guard and use a guarded
runtime lower bound. This adds 16 guarded bytes per bootstrap reservation,
not an additional stack allocation. No stack is moved to PSRAM.

Give the existing task-stack array an explicit input section and collect it
with the four linker reservations in one NOBITS `.stacks` output section.
The app image contains no stack bytes. Before selecting CPU0's native SP or
calling C/Zig, assembly zeroes the full span while CPU1 remains parked in ROM.
Low BSS is cleared separately. Each hart checks all IRQ/task words are zero
before using them: 20,480 checked bytes per owner, excluding its already-live
bootstrap stack. It then initializes guards through the existing paths.

## Runtime evidence

A host-testable layout defines the ten disjoint spans. The permanent trap
dispatcher samples each captured frame and its saved SP, plus the dispatcher
SP on that hart's IRQ stack. Require owned/aligned frame bounds, a saved SP
exactly 128 bytes above the frame base, and a valid owned IRQ SP. Compile-time
validation ties that frame size to the actual integer context ABI.

Per owner, retain the lowest observed bootstrap frame, each of three physical
task-stack frames, and IRQ dispatcher SP. Every category must be observed.
These are sampled frame/SP locations, not exhaustive peak-stack or worst-case
headroom measurements. They cover integer, raw FP and compiled Zig/C tasks
through the common dispatcher, including lifecycle stack reuse.

At protocol completion, check bootstrap, IRQ and all worker guards, then
publish immutable samples under a local mask with release/acquire ordering.
Later traps can validate their bounds without mutating the frozen samples.
`NIHOS_NATIVE_STACKS` reports exact extents, samples, frame count, initial zero
checks and completion for both harts. Full smoke validation binds these
extents and runtime heap-owner partitions to the case's audited image.

## ELF, loader and accounting gates

Require `.stacks` to be exactly 56 KiB of writable/non-executable NOBITS at
the chosen base. Require every linker stack boundary, the task array symbol
address and its 24 KiB size. Only that named data section may occupy the new
span. Runtime functions must still be in primary SRAM or the two approved
Flash boot functions; no code or other data is implicitly moved to high SRAM.

The primary heap now starts after primary BSS, independent of the separate
stacks. Retain the 48 KiB floor and require both regions to be disjoint.
Keep the actual loader collision check for both whole spans, recording gaps
on either side where present; loader allocations in the intervening hole
remain legal. Cache geometry and silicon-selection audits remain mandatory.

Total controlled SRAM grows from 160 to 216 KiB. Report primary static bytes,
separate stack bytes, total static bytes and heap bytes explicitly. Heap
growth is the added region minus new code/state/alignment cost, not a claim
of an equal reduction in total resident footprint. Keep full per-case image
snapshots and all previous SMP/FP/PSRAM/allocator evidence.

## Remaining boundary

The selected window and permissions are source-derived and emulator-qualified.
No physical Tab5 was accessed in this stage. This does not qualify every
SRAM cell, physical bank behavior, ECC, DMA, cache-off operation, power or
retention timing. Unused high SRAM and the ROM/cache areas are not registered
as heap. New trace/cache/power configurations need their own layout review.
No latency or game-FPS claim follows from the extra internal heap capacity.
