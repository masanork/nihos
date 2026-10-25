# 0023: Owner-local native SRAM arenas

Status: accepted for the native boot fixture, 2026-10-26.

## Problem

The independent native runtime previously used only statically linked
storage and stacks. Services need a bounded allocation entry point before
external memory can be brought up. A shared heap lock would introduce a
cross-core dependency into this first step; assuming that an emulator's
PSRAM address window represents initialized hardware would hide another.

## Decision

Keep the conservative 128 KiB SRAM window established by ADR 0018. The
linker reserves its tail after static data and all four bootstrap/IRQ stacks
as a writable, non-executable, NOBITS `.heap` section. It exports the start
and end and refuses a build with less than 16 KiB in that tail. The image
audit checks those symbols against sections, alignment and static storage;
the Flash image does not contain heap contents.

CPU0 initializes two equal, disjoint partitions before releasing CPU1.
Partition boundaries are multiples of 64 bytes; an odd trailing granule
is left unused. Each partition has a 64-byte guard at each end. The chosen
granule is an allocation/diagnostic convention, not a statement about cache
line size or cache maintenance requirements.

Each hart allocates only from its own monotonic arena. The native API reads
`mhartid`, briefly clears MIE around the bounded cursor update, and restores
its previous enable state. This serializes preemptible callers on one hart
without a shared lock. Interrupt handling does not allocate. Zero length,
invalid alignment, excessive size and requests by a different owner fail
without consuming storage. There is no fallback, free or reset API at the
native boundary. This is boot allocation, not yet a reusable application
heap suitable for SQLite or arbitrary C `malloc`/`free`.

Initialization and final diagnostic reports use release/acquire publication.
Remote code never reads another hart's mutable allocator cursor. A final
report becomes immutable before publication. Same-hart tasks still share
machine-mode authority; an ownership argument and guard bytes do not
provide task memory isolation.

## Runtime evidence

Each bootstrap allocates 64 bytes before enabling its timer. Both busy
tasks on each hart independently allocate 192-byte aligned buffers while
running under the timer scheduler. The compiled FP mode reaches the same
probe through its existing integer callback. Task-specific byte patterns
are sampled continuously; after workers exit and are reaped, the bootstrap
checks every byte, alignment and both guards after the IPI/idle fixture.
Allocation must preserve MIE=0 in the bootstrap and MIE=1 in the workers;
the fixture checks both states explicitly. Owner descriptors also occupy
separate 64-byte-aligned slots.

The final per-hart report requires 448 bytes consumed, exact remaining-space
accounting, three rejected requests with no capacity change, at least four
checks from each worker and completion by both owners. The log validator
rejects missing/duplicate owners, unaligned or external addresses,
overlapping partitions and incomplete accounting. Host tests exercise
foreign-owner rejection, exhaustion, alignment padding, boundary corruption
and partition rounding. All existing task, IPI and FP gates remain required.

## External-memory boundary

No PSRAM region is registered or accessed. The SRAM arena receives only
the linker-provided internal span, and all three smoke modes continue to
run with `--psram-size 0`. The existing ESP-IDF display/PSRAM backend remains
a separate oracle. Device-profile compilation is not a physical result.

Native PSRAM work follows the pinned ESP-IDF v5.4.4 primary implementation:

- [AP hex controller/device startup](https://github.com/espressif/esp-idf/blob/v5.4.4/components/esp_psram/device/esp_psram_impl_ap_hex.c): MPLL, controller clocks, DQS, mode registers and timing setup.
- [PSRAM initialization and registration](https://github.com/espressif/esp-idf/blob/v5.4.4/components/esp_psram/esp_psram.c): discovery, MMU/cache setup and memory exposure.
- [P4 MMU definitions](https://github.com/espressif/esp-idf/blob/v5.4.4/components/hal/esp32p4/include/hal/mmu_ll.h): page mapping and address translation.

Bring-up must establish controller timing, discovered capacity and cache/MMU
mapping before exposing an external span. Perform initial shared setup
before CPU1 release; later global reconfiguration needs an explicit
cross-core quiescence protocol. Real cache visibility, DMA ownership and
board timing require separate qualification. None is inferred from this
SRAM fixture or the emulator's RAM backing.
