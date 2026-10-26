# 0030: Revision-aware resident SRAM and typed diagnostic records

Status: accepted for native emulation; physical qualification pending, 2026-10-26.

## Region contract

The original 128 KiB resident region had only 1,856 bytes of headroom above
its 16 KiB internal heap gate in compiled FP mode. Keep all bootstrap,
interrupt and worker stack reservations and ReleaseSafe checks, reduce
resident code duplication, then enlarge only a source-supported SRAM span.

Pinned ESP-IDF v5.4.4
[application memory definitions](https://github.com/espressif/esp-idf/blob/v5.4.4/components/esp_system/ld/esp32p4/memory.ld.in)
distinguish early silicon's low SRAM bank from rev3's continuous SRAM
region after the configured L2 cache prefix. Use two explicit 160 KiB regions:

| Build profile | Resident interval | Rationale |
| --- | --- | --- |
| `device`, rev1/2 | `[0x4ff00000, 0x4ff28000)` | Below all live early-loader allocations and the documented ROM shared-buffer area |
| `emulator`, rev3 | `[0x4ff20000, 0x4ff48000)` | Excludes the configured first 128 KiB cache bank and stays below the rev3 loader |

The earlier rev3 emulator fixture shared the early-silicon origin. It did
not account for the rev3 application cache-prefix exclusion; passing that
emulation was not physical evidence that the prefix was usable SRAM.
Correct the profile origin here. This does not retune cache size or reclaim
loader/ROM memory. High-bank SRAM, TCM and ROM startup stacks are not added.

The early
[bootloader script](https://github.com/espressif/esp-idf/blob/v5.4.4/components/bootloader/subproject/main/ld/esp32p4/bootloader.ld)
documents shared buffers beginning at `0x4ff296b8`. The selected end leaves
5,816 bytes before them. Actual early-loader allocations begin at
`0x4ff2abd0`, 11,216 bytes above the region end. The
[rev3 script](https://github.com/espressif/esp-idf/blob/v5.4.4/components/bootloader/subproject/main/ld/esp32p4/bootloader.rev3.ld)
and actual rev3 ELF place the first live loader allocation at `0x4ffac2c0`,
410,304 bytes above the selected rev3 end. These are build/source facts,
not hardware measurements.

## Build and image gates

Preprocess the linker script with the same revision selector used by the
native assembly. Emit an absolute profile marker and audit it against the
requested build profile. All code, constants, data, stacks and heap must
fit that profile's interval. Raise the linker and ELF-audit minimum heap
from 16 to 48 KiB, reserving the added space rather than allowing silent
growth back to the old minimum.

Full image builds inspect the actual stock loader ELF: every allocated
section, including NOBITS/BSS, must be disjoint from the entire native
region. Retain its digest, allocated intervals and nearest gap. Also audit
the generated loader configuration: L2 cache must remain 128 KiB with
64-byte lines and silicon selection must match the native profile.
Mismatches fail the build. Standalone architecture links need no IDF
installation and enforce the fixed profile/heap contract; they cannot claim
loader collision evidence without the loader artifact.

Emulator log validation now requires owner-local SRAM inside the rev3
interval, rejecting the obsolete low/cache prefix, misalignment and overlap.
The physical image uses the early-silicon interval; an emulator result still
does not qualify that image on Tab5.

## Code sharing

Most normal reports shared the same name/u32 hexadecimal record format but
expanded one sequence of print calls per field. Add one sink-specific loop
with compile-time schemas. Descriptors store name pointer, u16 length and
u16 offset; RV32 descriptors occupy eight bytes. Normal records retain
their exact marker, field order, lowercase eight-digit values and optional
hart prefix. Error/trap diagnostics keep the direct console path.

Schemas require naturally aligned runtime u32 fields and reject packed
structures, comptime-only fields, oversized descriptors and underaligned
record pointers. Actual field offsets follow Zig layout, not an assumed
flat u32 array. The private type-erased emitter accepts only descriptors
constructed by the typed entry point. Records still require a valid borrowed
snapshot; this is not arbitrary-address validation. No heap allocation,
formatting library or asynchronous pointer retention is involved.

Keep the PSRAM probe/mapping preparation as distinct cold boot functions.
This is a code-placement/optimizer hint, with no safety-check or clock
policy change. Descriptor tables consume some read-only SRAM, so compare
total resident bytes rather than quoting text savings alone.

## Qualification and next boundary

Host tests require exact output ordering/full u32 values and mixed-layout
field offsets. Compiler-negative tests exercise all five rejected schema
classes. Python tests cover both heap regions, loader edge/BSS overlaps,
missing loader allocations, cache/revision mismatch and the earlier native
log gates. Full emulation retains the complete scheduler, FP, IPI/idle,
PSRAM cache/command, reusable heap and deferred task cleanup matrix.

Measurements separate two effects: smaller resident code/data and 32 KiB
more explicitly bounded SRAM. The app's padded Flash image need not shrink.
No stack was reduced; no safety mode, cache size, frequency or task quota
was relaxed. No physical device was accessed. Full-bank cell testing,
physical cache topology, DMA suitability, hardware timing and later cache
reconfiguration remain separate qualification. Flash XIP or additional
memory banks need their own ownership/layout work before registration.
