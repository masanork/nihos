# Native task-owned size-class pools

- Date: 2026-10-26
- Zig 0.17.0, ESP-IDF v5.4.4 loader only, ESP-EMU 0.50.0
- [Source manifest, six image audits and nine retained case sets](2026-10-26-native-size-pools.json)
- [ADR 0036](../adr/0036-task-owned-size-class-pools.md)
- Reproduce: `sh tools/run-native-smoke.sh compiled 32M` and `sh tools/build-native.sh device compiled`.

## Result and scope

Native tasks can allocate 8..4096-byte objects through ten size classes under
one tracked parent. Resize keeps the current class when capacity is sufficient
and issues a new operation ticket. A moving resize reserves the destination,
copies with interrupts enabled and only then frees the source. Destination
exhaustion preserves the original object and data. No parent/cell traversal
is introduced into task close or deferred outer-heap cleanup.

Each class has a fixed equal quota. There is no larger-class fallback, pool
growth, per-object SRAM ledger, shared cross-core pool or pointer-based C
allocator. Class metadata remains in PSRAM. Count two requests 17,008 bytes
(16,368 payload capacity and 640 class/cell metadata); buddy rounding consumes
32 KiB per parent. Four retained fixture pools occupy 128 KiB of outer PSRAM
blocks across both harts. This policy is intentionally simple and has not
been tuned for SQLite or other service allocation distributions.

## Local verification

| Check | Result |
| --- | --- |
| Host Debug / ReleaseSafe | 142 / 142 tests passed |
| Python log / image / compiler checks | 65 + 17 + 2 = 84 passed |
| Zig format, ZLint, ShellCheck | Passed |
| Integer / raw FP / compiled FP, both profiles | Six ELF/instruction audits and six full loader/image audits passed |
| Integer PSRAM cases | Absent, 4, 8, 16, 32, 64 MiB passed |
| Raw FP PSRAM cases | Absent passed |
| Compiled Zig/C FP PSRAM cases | Absent and 32 MiB passed |

Host tests cover class boundaries, exact slice length, fixed per-class
exhaustion, same-address ticket renewal, serial exhaustion before mutation,
null/zero resize, source preservation on OOM, cancellation, poisoned-source
rollback, hart/task/kind checks and old plans after task/parent reuse. Closing
an unpublished parent or an in-progress move returns the entire parent as one
resource. Poisoned child metadata does not prevent generic outer reclamation.
The Python checks reject missing or altered resize/copy/rejection counts in
both absent and populated reports.

Both busy workers on each populated hart run the same sequence: 13 to 15
bytes in place, 300 bytes by move, shrink to nine retaining 512-byte capacity,
move to 2048 and 4096, exhaust the largest class and fail a 32-to-4096 move,
then free blockers and retry successfully. They check preserved prefixes and
retain a filled 4096-byte object. Cleanup checks all retained payload bytes
before releasing the parent, outside its masked metadata operation.

Each populated hart must report:

- Eight moves, four in-place resizes, eight rejected operations and 4208
  copied bytes. The largest individual fixture copy is 2048 bytes.
- Ten reclaimed parents, zero retained/pending resources and full outer-heap
  recovery. The preceding stage reclaimed eight parents; the two extra parents
  are the busy workers' object pools.
- The previous monotonic/slab counts: 18/6 objects/rejections and
  120/24/27 slab allocations/frees/rejections.

Absent-PSRAM cases must report zero object/copy/reclamation counts while
retaining the existing scheduler/lifecycle qualification. All cases still
complete 300 rounds and the two-way 64-notification IPI/WFI phase. Existing
integer/FP isolation, captured stack bounds and guard checks remain required.
The copy helper checks MIE before/after its payload copy. This proves enabled
interrupt state at those observations; it does not prove a timer interrupted
each copy or measure worst-case allocator/interrupt latency.

## Footprint and attribution

Both revision profiles produce these sizes. The baseline is recorded commit
`034aa5a9e92c2eb2275c4735a5b28fc58eb3a1a2`, using the preceding
[stack-region evidence](2026-10-26-native-stack-region.json); its images were
not rebuilt during this stage.

| Mode | Previous total static | Current primary static | Separate stacks | Current total static | Internal heap | Static growth |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Integer | 111,872 B | 65,792 B | 57,344 B | 123,136 B | 98,048 B | 11,264 B |
| Raw FP | 116,032 B | 69,824 B | 57,344 B | 127,168 B | 94,016 B | 11,136 B |
| Compiled FP | 116,416 B | 70,080 B | 57,344 B | 127,424 B | 93,760 B | 11,008 B |

The controlled primary/stack spans remain 160/56 KiB, totaling 216 KiB.
The tightest internal heap has 44,608 bytes above the 48 KiB gate. These
deltas include allocator code, native wrappers, test fixtures/retained state,
new report fields and alignment; an isolated production allocator cost was
not measured. No additional SRAM region, cache change, stack enlargement or
Flash executable function is introduced.

Application image sizes are 69,664 / 72,736 / 73,040 bytes in integer / raw FP /
compiled FP. Read-only Flash report tables grow from 2368 to 2450 bytes,
with runtime/audit FNV-1a `0x50b4d635`. Both harts must preserve that table
checksum. The existing two-function CPU0 Flash boot whitelist is unchanged.

## Evidence boundaries

The JSON hashes nine changed source/test/validator files and verifies six
full images against their ELF contents, pinned loader configuration and actual
loader sections. Each of nine retained case directories includes the executed
ELF, app, merged image, linker layout, audit, log and report. Reports bind the
exact case ELF digest. Allocated contents match the final per-mode image;
full ELF determinism is not claimed because debug/cache paths can differ.
Runtime internal-heap and stack bounds match their case audits.

These are local host/build/emulator results. No physical device was accessed.
Physical PSRAM/cache behavior, copy latency, complete maximum stack use and
real service allocation performance remain unqualified. Remote CI is separate
evidence and is not included in these local results. The C allocator/SQLite
adapter and database service lifecycle remain subsequent work.
