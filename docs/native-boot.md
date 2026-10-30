# Native Zig boot on ESP32-P4

When configured Wi-Fi obtains an IPv4 lease and DNS, the normal build
[queries public NTP and synchronizes the RTC in UTC](adr/0053-network-time-to-rtc.md).
No network time is inferred from the build/host clock. The observed public-NTP
write/readback and no-NTP warm retention are documented separately from cold
power-loss and long-duration qualification.

The normal public device build includes [on-demand speaker, microphone and
RS485 drivers](adr/0052-default-on-demand-device-drivers.md). It leaves these
idle until explicitly requested and writes its connected artifacts to
`build/native-device-network-devices-camera/`. The camera prototype supplies
shell `camera` and `camera-live` commands. Set `NIHOS_NATIVE_CAMERA_ID=0` to
retain the image without camera in `build/native-device-network-devices/`.
Set `NIHOS_NATIVE_DEVICES=0` for the
smaller connected image in `build/native-device-network/`. The [combined controller exercise](measurements/2026-10-28-default-devices.md)
has passed; dedicated probes retain their own profiles.

Normal `camera-live` keeps the sensor, CSI and ISP running and rearms DMA from
the shared DW-GDMA interrupt. Two pinned RAW8 buffers protect foreground sampling
from incoming writes; frames are dropped while the reader holds the other slot.
Two finite trials measured approximately 17 updates per second for the 80×45
grayscale preview. A dismissal drains capture before repainting the shell.
`camera` remains a finite snapshot, and diagnostic profiles retain finite live
captures. After 500 ms idle the owner powers the sensor and XCLK down. The first
normal camera use reserves a 2 MiB PSRAM frame allocation plus scratch until
reset, including when starting with a single snapshot. See the
[continuous capture trial](measurements/2026-10-31-camera-continuous.md) for
identities, memory accounting and remaining qualification limits.

An opt-in [normal-boot networking integration](adr/0045-normal-boot-network-integration.md)
services factory Hosted Wi-Fi alongside the live display. The initial
[120-second physical evidence](measurements/2026-10-27-normal-boot-network.md)
is followed by [lease maintenance and retry](adr/0046-native-network-lease-lifecycle.md).
[Physical early renewal and controlled C6-reset recovery](measurements/2026-10-27-network-lease-device.md)
have passed; natural lease timing and long-duration operation remain separate gates.

This is the first independent native boot fixture. The stock ROM and
second-stage loader hand off to Zig/assembly code in internal SRAM, with no
ESP-IDF application runtime or FreeRTOS link. Both harts keep running under
nihOS-owned trap and timer handling. Each now runs the shared task runtime,
including timer preemption of two busy tasks and sleep/exit/reap/slot reuse.
After that fixture, both owners exchange 64 event notifications in each
direction while using WFI with periodic alarms disarmed.
The existing ESP-IDF display backend is still a separate implementation.
Two CPU0-only PSRAM boot functions now execute from the retained Flash mapping;
the ongoing kernel/task runtime remains resident.

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
Task-owned monotonic pools are described in
[ADR 0031](adr/0031-task-owned-monotonic-pools.md).
Read-only loader-mapped diagnostic tables are described in
[ADR 0032](adr/0032-loader-mapped-read-only-record-tables.md).
Whitelisted CPU0 boot-code placement and executed-PC evidence are described in
[ADR 0033](adr/0033-whitelisted-flash-boot-code.md).
Task-owned fixed-size cell allocation/reuse is described in
[ADR 0034](adr/0034-task-owned-fixed-size-slabs.md).
Separate source-supported internal SRAM for stacks is described in
[ADR 0035](adr/0035-separate-internal-sram-stack-region.md).
Task-owned size-class pools and preemptible resize are described in
[ADR 0036](adr/0036-task-owned-size-class-pools.md).
The opt-in CPU0 protected task fixture, synchronous bus-error requirement,
and exact Tab5 v1.3 fault evidence are described in
[CPU0 protected native tasks](native-user-pmp.md). Ordinary native workers
remain in the trusted M-mode domain.

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
sh tools/run-native-smoke.sh sqlite 4M
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
The primary resident region is 160 KiB: `0x4ff00000..0x4ff28000` for the physical
rev1/2 profile, and `0x4ff20000..0x4ff48000` for the rev3 emulator profile.
The latter skips the pinned 128 KiB cache prefix. The linker and image audit
require at least 48 KiB of internal heap; all stack reservations are retained.
Stacks now occupy the separate 56 KiB region described in ADR 0035 below.
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
termination. A populated run reclaims ten intentionally retained handles
per hart, with no owned or pending resources at the end. An absent run still
checks the lifecycle and empty-ledger protocol but must claim zero frees.
Ordinary worker churn now uses the same task-bound allocation API; the final
heap check no longer frees forgotten worker buffers on their behalf.

Task-owned monotonic pools now group small objects under one tracked parent
using `memory.reusable.openPool`, `allocPool` and `closePool`. The canonical
cursor stays in SRAM, so copied handles share one position; each child request
validates the current task and live parent ticket without touching the buddy
tree or PSRAM. Explicit close invalidates all handle copies. Task close rejects
new child requests immediately and the existing deferred cleanup releases the
parent without traversing its children. Populated runs additionally require
18 child allocations and six pool rejections per hart; absent runs require
zero. Returned pointers require caller-controlled lifetimes. There is no child
free/reset/realloc or SQLite allocator adapter yet. See
[ADR 0031](adr/0031-task-owned-monotonic-pools.md).

The optional second smoke argument selects `0`, `4M`, `8M`, `16M`, `32M` or
`64M`. All results, including absent PSRAM (`psram-0/`), are written under
`psram-SIZE/` inside that mode's build directory. Each case retains its exact
ELF, app/merged images, layout and audit, and executes that retained image;
later per-mode rebuilds cannot replace its evidence. The validator requires the requested size to match the
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

The smoke has sixty-four log validator regression tests, including frozen
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
Seventeen more tests check instructions, heap/loader boundaries, loader cache
configuration and bounded read-only Flash sections/checksums. Two compiler
tests check six invalid diagnostic schema classes, including oversized text.
Normal report output uses a shared, allocation-free typed record writer;
four host tests cover ordering/full values, actual struct offsets,
self-contained relative tables and empty schemas.

Normal record tables now use the loader's second Flash mapping instead of
SRAM. Runtime code, mutable state, ordinary constants and direct trap/error output
remain resident. `NIHOS_NATIVE_FLASH` requires full-table initial/final reads
from both harts, with addresses and checksums matching the audited ELF.
Smoke reports retain that image's ELF digest. The second Flash section is
read-only, non-executable and restricted to one 64 KiB page. No Flash write
or cache-off protocol is implemented; normal logging requires the retained
Flash mapping and cache. All previous resource, scheduler and memory gates
remain required.

The first Flash mapping now contains the descriptor followed by two approved
CPU0 boot functions: PSRAM discovery/setup and mapping preparation. The image
still has exactly two external mapped segments. `NIHOS_NATIVE_BOOT_CODE`
requires a completed probe PC and, with a populated die, a mapping PC within
their individual ELF-audited function ranges. No-die runs require a zero
mapping PC. The ELF audit rejects any other Flash function and applies the
existing integer/FP instruction boundaries to the moved code. The functions
run before CPU1 release and scheduler timers; general service code and
cache-off execution are not qualified by this placement.

Task-owned slabs now provide individually reusable fixed-size cells under
one parent resource. Initialization is two-phase with interrupts enabled;
cell operations update bounded parent metadata under the owner mask. Parent
epochs and child tickets reject stale frees across cell and parent reuse.
Populated resource reports additionally require 120 slab allocations, 24
cell frees and 27 rejections per hart; absent runs require zero. Normal and
forced task cleanup reclaim live/pending/poisoned slabs as one parent without
walking their children. These fixed slabs also back the size-class pools below.

The stack reservations now use a separate 56 KiB internal-SRAM span at
`0x4ff60000..0x4ff6e000`. Primary SRAM bounds, cache geometry and the 48 KiB
heap gate remain. All four 8 KiB and six 4 KiB reservations are retained;
bootstrap stacks now also reserve their first 16 bytes as guards. Assembly
zeroes the full NOBITS span before selecting a native stack. Each hart checks
20 KiB of IRQ/task memory before use. `NIHOS_NATIVE_STACKS` requires exact
extents, owned frame/SP samples, initial zero checks and final completion.
Both full SRAM spans are checked against actual loader allocations. Sampled
frame minima are not complete peak-stack measurements. Total reserved SRAM
is 216 KiB; reports distinguish total static use from primary static use.

Task-owned size-class pools now offer 8..4096-byte objects under one parent
with an explicit equal cell quota for ten classes. Resize renews the ticket
within capacity; moving resize reserves first, copies with MIE enabled and
then commits. A full target class preserves the original object. Shrinks
retain their class; there is no larger-class fallback or automatic growth.
Each populated hart must report eight moves, four in-place changes, eight
rejections and 4208 copied bytes. Two additional retained parents are reclaimed
after checking their final 4 KiB payloads. Absent runs require zero. This is
a typed Zig API; the subsequent C boundary and host-only SQLite probe are described below. See
[ADR 0036](adr/0036-task-owned-size-class-pools.md) and its
[source-bound measurement](measurements/2026-10-26-native-size-pools.md).

Run all 93 Python tests with:

```sh
python3 -m unittest discover -s tools -p 'native*_test.py'
```

## Task-local C allocation and SQLite host probe

[ADR 0037](adr/0037-task-local-c-allocator.md) adds the bounded, prefixed API
in `include/nihos_allocator.h`. A task explicitly opens one pool, then allocates,
resizes, frees and queries capacity through C calls. Memory is eight-byte
aligned, limited to 4096 bytes per request and owned by the current task.
Capacity is fully usable and survives a moving resize, including after a
shrink. Submitted pointers are range/stride checked before metadata access.
Raw pointers cannot identify stale-address reuse; callers must respect lifetime.

All native profiles now link a C probe. Populated runs require two completed
C probes per hart, with retained C bytes checked at the same deferred parent
cleanup as the existing typed objects. Absent runs require zero C probes.
Copies/initialization remain preemptible; C metadata operations require task
context with MIE enabled. Closing clears the SRAM binding before reclamation.

`sh tools/run-c-allocator-probe.sh` exercises the C ABI on the host, including
foreign-task refusal and retirement. `sh tools/run-sqlite-memory-probe.sh`
fetches and verifies official SQLite 3.54.1, runs a host memory-only database
through that allocator, injects OOM at each baseline allocation and checks
retry/recovery. An optional first argument selects the uniform per-class quota
(default 64). The no-I/O test VFS supplies no persistent storage guarantee.
Ordinary native modes do not link SQLite. The opt-in native fixture below adds
library placement and execution; service ownership, bounded RPC, VFS fault
tests and physical validation remain separate gates. See the
[measurement](measurements/2026-10-26-native-c-allocator.md).

The subsequent [configured quota](adr/0038-configured-size-class-quotas.md) and
[C identity](adr/0039-runtime-c-task-identity.md) stages add an experimental
64 KiB SQLite profile and a runtime-scoped owner stamp. Profile 1 now uses
`24,12,64,64,64,4,8,12,8,1` cells for the ten classes; its requested parent is
57,104 bytes. It is a bounded fixture policy, not a production SQL budget.
`nih_task_identity()` includes hart, slot and generation and returns zero for
unavailable/inactive or interrupt-disabled contexts.

The [single-owner session prototype](adr/0040-bounded-single-owner-sqlite-session.md)
adds a host-qualified entry guard, finite scalar queries, progress budget and
atomic token cancellation. Its 321-point OOM/retry sweep and a real pthread
cancel test run through `tools/run-sqlite-memory-probe.sh`, alongside the original
308-point sweep. A normal build without injection hooks is also exercised.
That stage exercised only the C allocator and identity boundary in firmware.
Its [aggregate measurements](measurements/2026-10-26-sqlite-owner-session.md)
separate host, emulator and unperformed physical qualification.

## Opt-in native SQLite execution

`sh tools/build-native.sh device sqlite` builds a physical revision-1/2 image;
`sh tools/run-native-smoke.sh sqlite SIZE` executes the emulator profile.
SQLite, the session wrapper and the no-I/O VFS use a source/object-bound Flash
allowlist. Their code and constants join the diagnostic table in the stock
loader's second mapped segment. Kernel, interrupts, allocators, C string
helpers, compiler runtime and all mutable state remain in internal SRAM.
The SQL mode retains the integer ILP32 ABI and software REAL arithmetic.

After the full SMP/timer and IPI fixtures, CPU0's bootstrap opens and closes
two in-memory sessions and checks 26 scalar/DDL/transaction queries. Timers
are disarmed and the peer is quiescent during SQL; MIE stays enabled. This
does not yet place SQLite in a scheduled service or qualify interrupted SQL.
With no PSRAM the fixture reports a skipped SQL phase and still requires the
ordinary kernel gates. Populated cases check complete parent-heap recovery,
the executed open-function PC, allocation-class peaks and the bootstrap's
stack overwrite observation. The fixed workload observed 6,472 bytes in its
8 KiB reservation; this is not a general SQL stack limit.

[ADR 0042](adr/0042-native-sqlite-flash-execution.md) and its
[measurement](measurements/2026-10-26-native-sqlite.md) record the loader's
two-mapping restriction, quota failures and exact artifacts. Physical Tab5
qualification is required before publication; ordinary and Native CI remain
separate checks after publication. No device write or new CI was performed
for this local stage.
