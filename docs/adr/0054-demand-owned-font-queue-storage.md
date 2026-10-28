# 0054: Demand-owned payload slots for the serialized native font exchange

Status: accepted for bounded host/native-emulator qualification, 2026-10-28.

The runtime-text fixture has one outstanding request, including raster release,
with no subsequent render until the previous reply and raster are retired. Two
inline slots in each channel reserve 3,200 B of primary SRAM for a single-credit
protocol. Keep generic multi-slot SpscRing unchanged; use a one-item SpscMailbox
for this exchange and retain SpscChannel's existing publish/notify/wait behavior.

A mailbox has separate release/acquire publication counters and a borrowed slot
pointer. Bind once before admitting endpoints; reject payload overlap with its
metadata. Empty/full and wrapping counter checks precede payload access. A push
copies caller bytes before publication and a pop copies bytes before releasing
the slot. Producer and consumer own distinct counters, on separate cache lines.
The native channel descriptors and atomics stay in SRAM. Only pointer-free
Request/Reply payloads move into the bootstrap's task-owned PSRAM archive.
Binding while interrupts are masked changes SRAM metadata only; payload access
occurs in existing interrupt-enabled bootstrap/font-task paths, outside IRQs.
No atomic access is moved to PSRAM. Both native endpoints run on CPU0; host
cross-thread tests are separate evidence, not a physical SMP/PSRAM claim.

Detachment requires external quiescence; an empty mailbox alone cannot prove
that an endpoint is finished. Preserve the forced final reply-space notification
gap, distinct terminal ACK, task resource cleanup and scheduler reap. Only after
runGraphics has returned may the bootstrap probe full rejection, drain the test
copies, detach both slots, and free its archive. A mailbox cannot be rebound or
access its payload after detachment. The archive accessor also exposes no freed
text snapshots. This remains one qualified service lifetime, not restart/cancel.

The archive grows from 3,336 to 4,496 logical bytes and its buddy charge from
4,096 to 8,192 B, only while this workload runs. Channel metadata falls from
3,200 to 768 B of SRAM; packet ABIs and the 16-glyph capacity are unchanged.
The bootstrap still uses at most two roots (archive and canvas). All archive,
raster and canvas PSRAM must return after worker retirement. The 32 KiB font
stack and 32 KiB library region remain fixed SRAM; reclaiming those requires a
separate executable-data/stack ownership design. This stage does not claim a
fully demand-loaded font service.

Accept with copied-input/output and runtime-source checks unchanged, all 64
matrix runs and five text jobs matching the prior independent host reference,
all four frame digests unchanged, real Flash preemption, full/duplicate-binding/
post-detach rejection, and complete heap recovery. Audit SRAM descriptors against
ELF symbols and payload pointers against the disjoint CPU0 PSRAM heap ranges.
Retain the 48 KiB primary-heap floor, 16 KiB frontend cap, runtime bounds/overflow
checks, stack reservations and exact Flash function whitelist. Device evidence
is compile/loader audit only; physical cache, LCD and native font IO remain open.


The final candidate passes 253 host Zig tests and 192 Python tests, including
100,000 ordered cross-thread mailbox transfers across counter wrap, alias/full/
closed rejection and stale wake backpressure. Static analysis and six default
native links pass. Both graphics profiles pass image/loader audits; the exact
emulator image passes all unchanged renderer/source checks plus queue retirement,
post-free closed checks and final bootstrap/IRQ stack guards.

| Footprint | Runtime-text baseline | Queue-storage candidate |
| --- | ---: | ---: |
| Device primary static SRAM | 114,688 B | 113,536 B |
| Device primary heap | 49,152 B | 50,304 B |
| Emulator primary heap | 49,408 B | 50,432 B |
| Channel SRAM metadata/storage | 3,200 B | 768 B |
| Archive PSRAM charge during use | 4,096 B | 8,192 B |
| Frontend Flash | 16,040 B | 16,048 B |

The net device SRAM reduction is 1,152 B after additional lifetime checks and
qualification/report code; the descriptor reduction alone is 2,432 B. The device
heap is 1,152 B above its unchanged floor and frontend is 336 B below its cap.
All PSRAM returns to the original 16,022,848 B CPU0 heap after retirement. See
[`2026-10-28-native-queue-storage.json`](../measurements/2026-10-28-native-queue-storage.json)
for current source, candidate, reference and capture hashes.
