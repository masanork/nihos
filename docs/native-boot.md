# Native Zig boot on ESP32-P4

This is the first independent native boot fixture. The stock ROM and
second-stage loader hand off to Zig/assembly code in internal SRAM, with no
ESP-IDF application runtime or FreeRTOS link. Both harts keep running under
nihOS-owned trap and timer handling. Each now runs the shared task runtime,
including timer preemption of two busy tasks and sleep/exit/reap/slot reuse.
After that fixture, both owners exchange 64 event notifications in each
direction while using WFI with periodic alarms disarmed.
The existing ESP-IDF display backend is still a separate implementation.

See [ADR 0018](adr/0018-independent-native-boot.md) for boot constraints and
[ADR 0019](adr/0019-permanent-native-task-owners.md) for the scheduler wiring.
Native inbox/IPI ownership and WFI qualification are described in
[ADR 0020](adr/0020-native-ipi-and-interrupt-wait.md).
Opt-in FP ownership and its integer regression mode are described in
[ADR 0021](adr/0021-native-opt-in-floating-contexts.md).
Compiler-generated Zig/C single-precision tasks and the ILP32F boundary are
covered by [ADR 0022](adr/0022-compiled-fp-and-c-boundary.md).
Owner-local SRAM allocation and its PSRAM boundary are described in
[ADR 0023](adr/0023-owner-local-native-sram.md).
Read-only native PSRAM command discovery is described in
[ADR 0024](adr/0024-bounded-native-psram-discovery.md).
Supply startup and command-data qualification are described in
[ADR 0025](adr/0025-native-psram-supply-and-command-data.md).
Reserved CPU mappings and cross-core PSRAM handoff are described in
[ADR 0026](adr/0026-native-psram-mapping-and-cache-handoff.md).
Full-capacity mapping and owner-local external boot allocation are described
in [ADR 0027](adr/0027-native-external-boot-arenas.md).
Reusable owner-local PSRAM heaps and their handle API are described in
[ADR 0028](adr/0028-owner-local-reusable-psram-heap.md).
Task-bound allocations, termination and deferred cleanup are described in
[ADR 0029](adr/0029-deferred-native-task-resource-cleanup.md).
Revision-aware resident regions, the 48 KiB heap budget and shared record
output are described in [ADR 0030](adr/0030-revision-aware-native-sram-budget.md).

## Build and emulated execution

Install ESP-IDF **v5.4.4** and its ESP32-P4 tools. Set `NIHOS_IDF_PATH` if it
is not already in `IDF_PATH` or `$HOME/esp32/esp-idf-v5.4.4`. Zig 0.17.0 and
ESP-EMU 0.50.0 are checksum-verified by the existing bootstrap scripts.

```sh
sh tools/run-native-smoke.sh
sh tools/run-native-smoke.sh floating
sh tools/run-native-smoke.sh compiled
sh tools/run-native-smoke.sh integer 32M
sh tools/run-native-smoke.sh compiled 32M
```

This builds only the stock loader and partition table with IDF. Zig links
the native app separately, the image audit runs, and ESP-EMU boots with
`--psram-size 0`. Outputs live under `build/native-emulator/`:

- `nihos-native.elf`, `nihos-native.bin`, `nihos-native-flash.bin`
- `image-audit.json`: sections, ROM boundary, sizes and artifact digests
- `emulator.log`, `smoke-report.json`: 300 rounds, task evidence and IPI/idle results

Floating-mode outputs use `build/native-emulator-floating/`. The default
integer mode requires zero FP trap copies. Floating mode adds opted-in banks
and validates f0..f31/fcsr across timer preemption, task calls and a running
task's self-IPI. Each task starts with a checked zero bank, and all FP banks
are retired before the integer bootstraps confirm final FS=Off.

Compiled-mode outputs use `build/native-emulator-compiled/`. This mode uses
ILP32F for scalar float arguments/results and C-to-Zig callbacks, checks
calculation bits against an integer oracle, and requires timer captures of
the generated task code. The direct two-float structure ABI did not agree
in this pinned toolchain; this fixture uses a pointer adapter in C instead.

The report also requires three task checkpoints per hart: both busy tasks
must keep progressing under timer preemption, and both lifecycle generations
must finish sleeping, exit and be reaped. A third generation deliberately
blocks with allocations and is terminated by its owner bootstrap. Its
completion remains retained until cleanup and reaping finish. Dispatch checks interrupt/task
stack sentinels, frame bounds, and elapsed-time accounting. These checks do
not provide memory protection between tasks.

The final marker is `NIHOS_NATIVE_FP_PASS`. Each owner must show 64
ordered message deliveries, 64 wakes from a registered event wait, at least
64 IPI captures of the parked bootstrap, a running-task self-IPI, and unchanged timer IRQ counts
during the IPI interval. One arrival per hart is deliberately made pending
before WFI with MIE clear. The earlier soak marker alone cannot pass this
workflow. These observations do not measure physical power savings.

The linker now assigns the unused SRAM tail to a NOBITS `.heap` section.
The resident region is 160 KiB: `0x4ff00000..0x4ff28000` for the physical
rev1/2 profile, and `0x4ff20000..0x4ff48000` for the rev3 emulator profile.
The latter skips the pinned 128 KiB cache prefix. The linker and image audit
require at least 48 KiB of internal heap; all stack reservations are retained.
CPU0 splits it into two guarded arenas before releasing CPU1. Native
allocation selects the current hart's arena and masks local interrupts only
for the cursor update. It has no shared lock, fallback, free or reset.
Each bootstrap and both preemptible workers allocate aligned buffers;
the final `NIHOS_NATIVE_MEMORY` records check patterns, guards, disjoint
bounds and exact capacity accounting after the IPI fixture. The reports
add a `memory` array, and the image audit distinguishes static reservation
from the runtime heap span. These are boot arenas, not a general reusable
heap. The same domain implementation manages a separate PSRAM boot arena;
most of that backing is now transferred to the reusable external heap.
`alloc` remains an SRAM boot allocation. `allocExternal` returns a reusable
handle tied to the current task, and `freeExternal` checks both task generation
and hart ownership. There is no fallback. The qualification runtime has a
fixed quota of two outstanding handles per task; a full ledger fails before
calling the heap. Services needing many objects need a scoped arena/pool.

Before CPU1 release, Zig now reads the PSRAM identity through MSPI3 with
bounded polling and a repeated-read check. `NIHOS_NATIVE_PSRAM` reports the
mode-register capacity. A populated device now maps its full detected capacity,
with 192 KiB reserved for CPU/command tests. The discovery record still shows
zero allocatable bytes because external registration occurs after the
cross-core boot checks. This is an emulated
qualification fixture. Its ROM boundary includes four explicit cache
functions alongside the earlier console output and CPU1 entry functions.

The native path now programs and reads back LDO channel 2 for 1.8 V, using
complete factory trim fields when present and nominal settings otherwise.
It leases CPU0's stopped timer for a bounded 1 ms boot settling wait and
returns it with a reset scheduler deadline. A detected die receives verified
x8/fixed-latency mode settings, followed by two complementary write/read
passes over 22–26 address-derived samples spanning its address lines and
final word. `NIHOS_NATIVE_PSRAM_SUPPLY` and `NIHOS_NATIVE_PSRAM_IO` report
these results. An absent die receives no mode or data writes. All CPU
stacks and allocator descriptors still use internal SRAM. The reusable
heap's tree and allocation headers live in PSRAM.

CPU0 maps the first, middle and final physical pages into three consecutive
64 KiB windows, verifies CPU/command visibility with writeback/invalidation,
then releases CPU1. The bootstraps check 64 rounds over PSRAM payloads with
internal request/acknowledgement words, followed by a physical-command check
of CPU1's last reply. `NIHOS_NATIVE_PSRAM_MAP` and `NIHOS_NATIVE_PSRAM_SMP`
report these gates. ROM cache operations follow the vendor API; their internal
wait time is not bounded by nihOS. Physical voltage/timing, coherency,
high-speed tuning and DMA remain unqualified.

The first three virtual pages still refer to physical first/middle/final
pages. The displaced physical pages 1 and 2 occupy the middle/final virtual
slots, so every physical page appears exactly once. All 1,024 PTEs are read
back, with entries beyond capacity invalidated. CPU1 waits after its final
external boot access while CPU0 completes command checks and registers two
guarded, disjoint external arenas. Only then are workers released.

Each owner allocates a 64-byte bootstrap buffer and two 65,728-byte worker
buffers from PSRAM, crossing page boundaries under timer preemption. Every
byte and both guards are checked after task retirement. The final
`NIHOS_NATIVE_EXTERNAL` records and `external_memory` report array require
exact bounds/accounting. `external_registered_bytes` describes the original
guarded arena capacity, all consumed by test buffers and heap backing.
`external_allocatable_bytes` now describes reusable payload capacity after
boot buffers, tree metadata and guards have been deducted.
The absent-die case rejects external allocation and reports zero records.

Both owners initialize a buddy heap with 64-byte minimum blocks before
either scheduler timer starts. `NIHOS_NATIVE_HEAP` and the `heaps` report
array require variable-size aligned allocation/free churn under preemption,
13 rejected operations per owner, complete exhaustion and full recovery
with zero live blocks. Runtime operations visit at most 59 metadata nodes
plus a fixed guard/header check. The counter does not measure interrupt
latency. The native wrapper preserves MIE on success and error paths.

Tickets reject stale/double/interior/wrong-size/foreign-owner frees; they
do not prevent stale payload accesses. Power-of-two rounding and per-owner
partitioning limit allocation efficiency and maximum block size. The 32 MiB
layout has an 8 MiB raw maximum buddy per owner, before header/padding.
Larger Quake hunks need a separate extent plan; SQLite needs a small-object
layer and an allocator adapter. Cross-core frees are not wired. Sparse tests
do not qualify all memory cells.

Every native EXIT closes the current task's fixed SRAM resource ledger.
The bootstrap termination path also closes its target after stopping it.
Closing performs no heap access. The bootstrap drains at most one retained
allocation per service pass, preserving MIE around the bounded release.
Task stack/FP retirement and slot reuse wait until the ledger is empty and
marked cleaned. Pending cleanup prevents WFI; completing a close yields to
the scheduler even when periodic alarms are disarmed.

`NIHOS_NATIVE_RESOURCES` and the `task_resources` array require seven opened
generations per hart (including the retained bootstrap), six closed/cleaned
tasks, three slot reuses, three stale-generation rejections and one forced
termination. A populated run reclaims eight intentionally retained handles
per hart, with no owned or pending resources at the end. An absent run still
checks the lifecycle and empty-ledger protocol but must claim zero frees.
Ordinary worker churn now uses the same task-bound allocation API; the final
heap check no longer frees forgotten worker buffers on their behalf.

The optional second smoke argument selects `0`, `4M`, `8M`, `16M`, `32M` or
`64M`. Nonzero results are written under `psram-SIZE/` inside that mode's
build directory. The validator requires the requested size to match the
decoded identity, then requires the complete existing 300-round run.

To compile/link only the application, without an IDF installation:

```sh
sh tools/build-native-elf.sh emulator
sh tools/build-native-elf.sh device
sh tools/build-native-elf.sh emulator build/native-emulator-floating floating
sh tools/build-native-elf.sh emulator build/native-emulator-compiled compiled
```

Normal architecture CI links and instruction-audits all three modes for both
profiles through this script. Compiled mode uses ILP32F; the other modes use
ILP32. Kernel FP instructions are rejected even in compiled mode. The tested
scalar/callback and pointer interfaces are qualified in the emulator;
arbitrary aggregates, varargs and f64 interfaces are not covered.

The manual **Native boot** workflow runs all three modes without a die and
the five populated sizes in integer mode plus compiled FP with 32 MiB,
builds the three physical images,
and retains the artifacts. It does not flash hardware.
Full builds also require disjoint live loader allocations and verify the
loader's 128 KiB L2 / 64-byte-line configuration and revision selection.
Each image audit records the region, loader digest and allocation gap.
Manual runs queue behind an active run on the same branch so a later
request does not cancel the preceding commit's qualification.

## Physical image

```sh
sh tools/build-native.sh device
sh tools/build-native.sh device floating
sh tools/build-native.sh device compiled
```

The image is built for P4 rev1/2 CLIC threshold semantics. The emulator image
uses rev3 semantics; the two headers have disjoint revision ranges. Device
outputs are under `build/native-device/`. The app occupies the factory slot
at `0x10000`; the merged image includes loader at `0x2000` and partition table
at `0x8000` and is written at `0x0`.

Floating outputs use `build/native-device-floating/`. Modes of the same
profile share the stock loader build; build those images sequentially.

Physical qualification is pending while emulator development continues.
Do not interpret a successful device-profile build as a physical boot result.
In this fixture the console is the output; display and touch are not
initialized. CPU-accessible external RAM uses conservative x8 timing.
Migration and a general tickless deadline policy are not yet
connected to this permanent native runtime.

The smoke has fifty-two log validator regression tests, including frozen
hart/timer/task counters, missing scheduler evidence, incomplete lifecycle,
a reboot, a later failure, timer fallback during IPI-only idle and incomplete
IPI/pending-before-WFI evidence, FP accounting, wrong build mode and missing
generated-code preemption, SRAM ownership/accounting, PSRAM discovery,
supply programming, command-data accounting, MMU/cache bridges and cross-core
PSRAM handoff, external arena bounds and absent-die allocation rejection.
Reusable heap records also require bounded walks, exact backing/metadata
geometry, zero leaks and capacity recovery.
Task resource records require cleanup completion, generation reuse and
actual forced termination, including the no-PSRAM path.
Eight more tests check instructions, heap/loader boundaries and loader cache
configuration. One compiler test checks five invalid diagnostic schemas.
Normal report output uses a shared, allocation-free typed record writer;
two host tests cover ordering/full values and actual struct offsets.

Run all 61 Python tests with:

```sh
python3 -m unittest discover -s tools -p 'native*_test.py'
```
