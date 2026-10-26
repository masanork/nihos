# Native task-owned fixed-size slabs

- Date: 2026-10-26
- Zig 0.17.0, ESP-IDF v5.4.4 loader only, ESP-EMU 0.50.0
- [Source manifest, image audits and exact case evidence](2026-10-26-native-slabs.json)
- [ADR 0034](../adr/0034-task-owned-fixed-size-slabs.md)
- Reproduce: `sh tools/run-native-smoke.sh compiled 32M` and `sh tools/build-native.sh device compiled`.

## Result

Both harts exercised individually reusable 32-byte cells under task-owned
slab parents. A populated run requires 120 allocations, 24 explicit cell
frees and 27 slab rejections per hart. Copied leases share one free list.
Exhaustion, double/stale frees, old parent leases, prior-parent cells and
constructor entry with interrupts disabled were rejected. Volatile payload
reads checked separation after frees/refills. Each normal/forced lifecycle
generation retained one 16-cell slab and a monotonic pool at exit.

The existing cleanup reclaimed eight parents per hart, including those slabs
and final worker allocations, with no owned/pending resources at completion.
The outer buddy heaps then exhausted and recovered their full capacity.
Absent-PSRAM runs completed the same lifecycle protocol with zero slab work.
These are allocation/lifetime results, not latency or game-FPS measurements.

Slab initialization writes metadata with interrupts enabled between parent
registration and publication. Ready publication validates a fixed header;
cell operations touch bounded metadata without an outer buddy operation or
cell/payload traversal. Parent epoch plus local cell ticket protect operation
handles across parent address reuse. A 32-byte parent header and 16-byte cell
headers live in the parent; eight-byte payload alignment and buddy rounding
remain explicit costs. Payload initialization is the consumer's responsibility.

## SRAM budget

Both revision profiles produced identical relative sizes. Baseline `4eafec5`
uses the preceding source-bound Flash-boot measurement; its six audits were
not rebuilt. The JSON retains that evidence path/digest and all current
loader/configuration, image, snapshot and log digests.

| Mode | Previous static SRAM | Current static SRAM | Growth | Internal heap | Margin above 48 KiB gate |
| --- | ---: | ---: | ---: | ---: | ---: |
| Integer | 104,320 B | 110,080 B | 5,760 B | 53,760 B | 4,608 B |
| Raw FP | 108,352 B | 114,112 B | 5,760 B | 49,728 B | 576 B |
| Compiled FP | 108,736 B | 114,496 B | 5,760 B | 49,344 B | 192 B |

Growth includes allocator, guarded ownership/publication, qualification and
report code, state and alignment. Shared ownership/geometry/metadata helpers
and bounded-prefix fixture loops avoid duplicate expanded allocation paths.
The measured final code retains the original 48 KiB gate. The region remains
160 KiB; bootstrap/interrupt stacks remain four times 8 KiB and worker stacks
two times three times 4 KiB, with safe compilation and unchanged task quota.
No Flash boot function or SRAM bank was added. Remaining static-growth margin
is very small; further native additions need a separate placement/budget step.

After boot-fixture allocations and guards, internal free bytes per owner
were 26,304 in integer, 24,256 in raw FP and 24,064 in compiled FP. The normal
record table grew to 2,122 Flash bytes with FNV-1a `0x858ff1d4`; both harts'
initial/final reads matched their saved ELF. Boot-code size remains 4,280 B
and both captured boot PCs remain within their approved functions. App images
are now 67,728 B. Neither clock/cache policy nor a performance target changed.

## Qualification

All 131 host tests passed in Debug and ReleaseSafe. Twelve new tests cover
geometry/alignment, copied views, exact capacity, preserved payloads, invalid
handles, serial exhaustion, corrupt metadata, two-phase publication, quota,
wrong tasks/kinds, parent epochs when address and child ticket recur, cancelled
initialization and deferred recovery of unfinished/poisoned parents. Generic
cleanup does not interpret child metadata even when it is corrupted.

All 76 Python tests passed: 61 log, 13 image and two compiler tests. New log
mutations reject missing/incorrect slab counters in populated and absent runs.
ZLint, ShellCheck, six architecture ELF/instruction audits and six full profile
image audits passed. The strict Flash boot whitelist, loader collision/cache
configuration and heap/stack gates remain in force.

All nine final emulator cases passed: integer with absent/4/8/16/32/64 MiB,
raw FP without a die and compiled FP with absent/32 MiB PSRAM. Existing
300-round scheduling/FP, normal/forced lifecycle, IPI-only idle, SRAM,
PSRAM mapping/cache/command, heap recovery and monotonic-pool gates remained.
Each case retains and executes its exact ELF/app/merged image and audit.
All nine saved ELF/app pairs passed auditing again; allocated ELF contents
match the final image of the same mode and runtime SRAM spans match the
saved image's heap partition. Current remote CI is separate evidence.

## Evidence boundary

Baseline ordinary CI and
[Native boot](https://github.com/masanork/nihos/actions/runs/40260613255)
both succeeded. No physical device was accessed. Native execution qualifies
normal/forced cleanup of live slabs; pending/poisoned-parent recovery is host
evidence. XOR consistency words are not authentication or general corruption
proof, and operation handles do not revoke raw payload pointers. Variable
size classes, realloc, C/SQLite adapters, cross-task sharing, a general service
supervisor, cache-off execution, DMA and physical timing remain separate work.
