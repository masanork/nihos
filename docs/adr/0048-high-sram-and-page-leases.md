# 0048: Retained high SRAM and externally described page leases

Status: accepted for device qualification, 2026-10-27.

## Context

The development profile needs approximately 256 KiB of internal heap and
128 KiB of stacks. The native fixture previously managed only its low SRAM
heap and a separate 56 KiB stack bank. The pinned ESP-IDF v5.4.4 rev1/2 map
with 128 KiB L2 supports another 328 KiB outside those reservations.
The existing PSRAM buddy heap stores a header inside each allocation, making
a power-of-two payload require the next larger block.

## Decision

Keep the existing primary bank, loader hole, active stacks and cache layout.
An opt-in `NIHOS_NATIVE_HIGH_SRAM=1` device build reserves the two additional
banks as writable, non-executable NOBITS. Audit both against the exact loader
ELF and cache configuration. Reject the emulator profile, whose primary bank
overlaps the first high bank.

Use 208 KiB for a serialized 4 KiB page pool. Reserve 32 KiB for future DMA,
72 KiB for future stacks, and four 4 KiB software guard pages. Reservations
are excluded from allocation; they do not implement DMA or stack admission.
No MPU/PMP protection is implied by the software guards or section flags.

Page metadata stays outside the supplied memory. Each lease records a caller
owner, slot and nonwrapping 64-bit ticket, requested slice and charged pages.
Allocation rounds only to the page size, never crosses a region boundary,
and bounds both page count and lease count. Free validates the canonical
lease before changing metadata. The caller serializes access, supplies
generation-aware owner identities for production use, zeroes as required,
and must not reinitialize a pool while old leases can be used. Raw payload
pointers do not provide access isolation or revocation.

CPU0 owns metadata in this fixture. It publishes four disjoint pages for
workers on both CPUs, then frees them only after both CPUs publish completion.
Before general PSRAM heap initialization or CPU1 release, the same allocator
temporarily tests a separate 8 MiB PSRAM window with exact 4 MiB and 8 MiB
leases. No lease survives that window's handoff to the existing heaps.

## Consequences

The exact loader/device combination can qualify the extra SRAM and the
large-allocation accounting without silently changing normal heap policy.
The option defaults off. The existing two-owner PSRAM buddy heaps remain
unchanged. Production broker/syscall integration, small-object allocation,
quotas, automatic task cleanup and stack admission remain separate changes.

See the [physical receipt](../measurements/2026-10-27-tab5-high-sram.md).
