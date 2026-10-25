# 0026: Reserved PSRAM mappings and cross-core cache handoff

Status: accepted for native qualification, 2026-10-26.

## Mapping contract

After ADR 0025's supply, identity, device-mode and command-data checks,
CPU0 configures MSPI2 for the same conservative x8/fixed-latency policy and
creates three 64 KiB CPU test windows. There is no general external heap.
The physical pages are deliberately nonconsecutive:

| Virtual window | Physical address |
| --- | --- |
| `0x48000000` | 0 |
| `0x48010000` | Half the detected capacity |
| `0x48020000` | Detected capacity minus 64 KiB |

This tests translation, including the last physical page, rather than only
an identity address window. MMU1 entries use the documented PSRAM target
and valid bits. All 1,024 entries are written/read back; entries beyond the
three reserved pages are invalid. Flash MMU0 is untouched. The native
wrapper rejects active Flash-encryption counters; this fixture qualifies
plain pages and does not implement encrypted external mappings.

Close the PSRAM AXI port during setup, verify controller/PTE writes,
invalidate the reserved cache range and open the port only after checks
agree. Mapping cannot be repeated while ready. A rejected cache operation,
failed readback or data mismatch closes the port, attempts to invalidate
all entries and poisons that owner. A partial span is never published.

Primary facts come from pinned ESP-IDF v5.4.4
[MMU definitions](https://github.com/espressif/esp-idf/blob/v5.4.4/components/hal/esp32p4/include/hal/mmu_ll.h),
[MSPI2 configuration](https://github.com/espressif/esp-idf/blob/v5.4.4/components/hal/esp32p4/include/hal/psram_ctrlr_ll.h)
and [external address definitions](https://github.com/espressif/esp-idf/blob/v5.4.4/components/soc/esp32p4/include/soc/ext_mem_defs.h).

## Cache boundary

P4's external address range uses L2 according to
[the official cache LL](https://github.com/espressif/esp-idf/blob/v5.4.4/components/hal/esp32p4/include/hal/cache_ll.h).
Keep the loader's SRAM/cache geometry and require 64-byte lines. Use the
same ROM ABI as that LL for line-size discovery, L2 enable, address-range
writeback and invalidation. Direct cache-register bring-up failed its
write/readback check in ESP-EMU; the accepted implementation uses these
vendor entry points. The ELF audit now requires exactly six known ROM
symbols, including the two earlier console/CPU1 functions. No IDF runtime
or C cache implementation is linked.

Operations target only L2 and the aligned 192 KiB reserved range. CPU0 owns
cache maintenance before CPU1 starts and after CPU1 has published the end
of external accesses. There are no concurrent external consumers or DMA.
The writeback/invalidate sequence follows
[the IDF memory synchronization path](https://github.com/espressif/esp-idf/blob/v5.4.4/components/esp_mm/esp_cache_msync.c).
The separate AXI-idle helper used during sleep/clock switching is outside
this unchanged-clock path.
MMIO writes and the cache API boundary use full RISC-V I/O fences. The
CPU-to-CPU payload protocol uses ordinary memory fences separately.

ROM calls are synchronous and their returned errors are checked. Unlike
the Zig SPI polling and mailbox waits, their internal hardware waits do not
have a nihOS software timeout. Physical cache timing and hang/watchdog
behavior remain qualification work. ROM use is an explicit hardware ABI
boundary, not evidence of an ESP-IDF application dependency.

## CPU/command and CPU/CPU checks

Before CPU1 release, CPU0 writes six word samples per window, covering line
and page boundaries. Write back, verify all 18 words using physical SPI
commands, overwrite through the command path, invalidate and check all CPU
views. Repeat with the complementary pattern. Success requires 36 checks
from each view, 72 physical commands and five cache operations including
initial invalidation.

After CPU1 starts, both bootstraps exchange 64 rounds over one 64-byte
payload per window. Request/acknowledgement words stay in internal SRAM;
payloads stay in PSRAM. Release/acquire publication and explicit RISC-V
fences order payload ownership. CPU1 validates and complements each word;
CPU0 validates the reply. Each hart checks 3,072 payload words. Cache
maintenance is not run during this shared-L2 handoff. After peer completion,
CPU0 writes back and checks CPU1's final 48 words through physical commands.
Then the existing scheduler, SRAM, IPI and FP qualification continues.

Host models keep physical memory and CPU cache views distinct. Dropping
writeback or invalidation, ignoring nonidentity translation, dropping a PTE,
rejecting a ROM operation or failing a physical command must revoke the
mapping. These models check sequencing; they do not model silicon cache
timing. An absent die skips both mapping and external handoff, with no
external CPU accesses. Native log validation requires the new records and
all earlier gates before accepting the final marker.

## Remaining boundary

The mapped 192 KiB is reserved for tests, with zero allocatable external
bytes. It is not a claim that all detected capacity has been mapped or
qualified. Sparse data checks, emulation and the cache model do not qualify
physical coherency, power timing, retention, DMA, x16 or high-speed MPLL/DLL
operation. No physical device was accessed. Full-capacity layout and
external allocator registration are subsequent steps.
