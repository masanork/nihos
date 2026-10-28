# Demand-allocated graphics memory experiment

The latest stage also has an opt-in native P4 image: see
[`docs/native-graphics.md`](../../docs/native-graphics.md). It passes native
boot/task/timer execution in the emulator, uses the real task-owned PSRAM
ledger and audits both revision layouts. It uses temporary Flash font inputs;
native font-filesystem input and physical-device qualification remain pending.
Earlier sections below retain each experiment's original evidence scope.

This independent host probe tests the user's requirement that Japanese text
support acquire memory when needed, return client memory on close, and allow
multiple applications to stay open. It does not reserve the previous 2/6/8 MiB
design budgets at boot and does not add a GUI to native firmware.

Run from the repository root on macOS or Linux with CMake, a C++17 compiler,
Python 3 and curl:

```sh
sh tools/run-graphics-memory-probe.sh
```

The script downloads checksum-pinned sources, fonts and license notices into
ignored `build/graphics-probe/sources`, builds static libraries with ASan/UBSan
enabled by default, and writes `build/graphics-probe/report.json` only after
every check succeeds. A failed run removes the previous receipt. The binary
never reads a serial port, writes firmware, or modifies an SD card.

Optional controller-size compilation with an installed RV32 compiler:

```sh
NIHOS_GRAPHICS_RV32_CXX=/path/to/riscv32-esp-elf-g++ \
  sh tools/run-graphics-memory-probe.sh
```

That compiles `metadata_size.cpp` and records `sizeof(LazyPool)` for ILP32.
It neither compiles the POSIX backing implementation for nihos nor runs on P4.

To also run against the kernel buddy heap and opt-in extent groups in the
four-task, two-entry-per-task resource ledger:

```sh
NIHOS_GRAPHICS_KERNEL_BACKING=1 sh tools/run-graphics-memory-probe.sh
```

This bootstraps Zig 0.17.0 when needed; `NIHOS_GRAPHICS_ZIG` can name an already
installed 0.17.0 compiler. Combining the kernel option with the RV32 compiler
option also compiles the allocator and Zig bridge for RV32, without linking
or executing firmware. The runner compares glyph hashes and OOM point counts
between the POSIX and kernel variants before producing a receipt.

## What is exercised

- FreeType 2.14.3 and HarfBuzz 15.0.0 render real BIZ UD Gothic and Mincho
  glyphs with horizontal/vertical shaping and alternating 24 px body/12 px
  ruby-sized runs. This is glyph rendering, not ruby placement or paragraph
  composition. Script/language are fixed Japanese fixtures, not itemization.
- Two sessions remain open together. Closing one returns all its FreeType
  and source-cache backing while the other produces the same pixels and
  advances. Library calls run on one serialized worker; applications are
  not mutually exclusive. Parallel threads are outside this experiment.
- Every allocation attempt in a warm second-session open/draw/close workload
  is individually failed. Failure never publishes a candidate, the second
  client's backing returns to zero, and the surviving client still draws
  exactly the baseline result. The whole workload succeeds again afterward.
- An unrelated owner holds 1 MiB under the same 2 MiB global limit. Opening
  the second font session fails cleanly, the existing session and unrelated
  bytes survive, and releasing that allocation permits the session to reopen.
- Pool checks cover foreign/interior/invalid/double frees, 16-byte alignment,
  metadata exhaustion, quota refusal, positive realloc failure preserving
  all usable old bytes, and 3,000 interleaved allocate/resize/free operations.

## Allocation and lifetime rules

`LazyPool` requests backing in 64 KiB multiples only when no existing owned
span has a suitable gap. Empty spans are returned immediately. Requests are
16-byte aligned, and moved reallocs reserve the destination before releasing
the source. Fixed metadata authenticates an exact pointer before dereferencing
payload; the probe does not read a header through an arbitrary supplied pointer.
Pointers still cannot distinguish stale addresses after address reuse.

The 2 MiB global and 1 MiB per-client limits are refusal thresholds, not
reservations. The service owner has a 512 KiB cap. Two clients have independent
lifetimes and cannot free each other's allocations. Backing pages are not lent
between owners while live objects remain in them. These IDs are probe lifetime
tags, not native scheduler identities or memory isolation.

All HarfBuzz allocations use a long-lived service owner because some state
survives face/font destruction. FreeType callbacks and each 256 KiB stream
cache belong to their client. Closing a client destroys its library objects
before returning its spans. The service's remaining process-global allocations
are retained; forced service-task cleanup/restart remains unqualified.

The default host backend uses `posix_memalign/free`. The optional kernel
variant registers one bounded extent group in the task ledger. Up to 32 child
extents can be acquired and returned independently through that ownership
entry. Each buddy extent supplies its full safe payload to the suballocator.
The bounded metadata scan is a host prototype, not an interrupt-latency proof.
This implementation does not replace `nih_task_malloc` or any libc symbol.

## Measurement scope

The recorded 2026-10-27 fixture has these **host backing requests**:

| State | Backing |
| --- | ---: |
| Before first library use | 0 |
| One session open after body/ruby rendering | 640 KiB |
| Two sessions, normal-workload peak | 1,280 KiB |
| Two sessions, allocation-failure workload peak | 1,664 KiB |
| After closing the second session | 640 KiB |
| After closing both sessions | 64 KiB service backing |

The last 64 KiB holds 1,415 requested live library bytes in this fixture;
it is not claimed to be entirely returned or bounded for arbitrary languages,
font collections, and features. Fixed controller storage, libc FILE buffers,
stack, code/rodata, OS file cache, and sanitizer overhead are outside this table.
The controller is separately reported for host and optionally RV32.

No application glyph bitmap cache, layout snapshots, document/undo data,
candidate RGB565 frame, SDL backend or display scanout is included. These
measurements cannot establish the complete reader/editor footprint, native
RAM use, SD latency, or physical-device qualification.

The receipt, including exact source hashes, is retained in
[`docs/measurements/2026-10-27-graphics-demand-memory.json`](../../docs/measurements/2026-10-27-graphics-demand-memory.json).

## Extent groups: current kernel-backed experiment

`ResourcesWithGroups` opts into a fixed registry of groups and child handles.
The graphics fixture provisions one group with at most 32 extents. The default
`Resources` factory retains zero group slots. The two-entry per-task ledger
limit remains; one group consumes one entry, leaving the other available.

The group root is a 64-byte ownership anchor costing a raw 256-byte buddy
block. Canonical child handles live in trusted control metadata, not in that
root's writable payload. `allocExtent`/`freeExtent` authenticate the current
key, group token and exact child handle before accessing heap metadata. An
arbitrary C pointer is looked up in the canonical registry before use. Raw C
addresses still cannot distinguish a stale address after later address reuse.

A live group cannot be freed through the generic root-free API. Task close
forbids new allocations, then `drainOne` frees at most one child per call and
finally the root; slot reuse waits until the group and other task resources
have drained. A heap error retains the handle and faults the slot. Host unit
tests cover registration rollback, extent quota, OOM, forged/stale/foreign
children, root payload corruption, peer survival, bounded drain and faulted
cleanup. These are opt-in kernel APIs; the native font task is not installed.

The suballocator charges the physical buddy block size against client and
global limits. A block supplies `raw size - 128` usable bytes, avoiding the
previous policy's large unused shared parent. Empty extents return directly
to buddy; live extents and library pointers are not relocated. Partially used
extents remain allocated, and the 256-byte root remains until the last child
is freed. The fixture's host **kernel raw occupancy** is:

| State | Raw buddy occupancy |
| --- | ---: |
| Before first library use | 0 |
| One client after drawing | 640 KiB + 256 bytes |
| Two clients, normal peak | 1,280 KiB + 256 bytes |
| Two clients, OOM stress peak | 1,664 KiB + 256 bytes |
| Second client closed | 640 KiB + 256 bytes |
| All clients closed | 64 KiB + 256 bytes |

The last child contains the service's 1,415 requested live HB bytes in this
fixed workload. These totals exclude controller state, stack, libc stdio,
code/rodata, OS file cache and sanitizer overhead, as in the earlier table.
They do not measure paragraph layout, glyph bitmap caches or framebuffers.

The largest contiguous block required by the normal two-font fixture is
512 KiB. A second run holds another task's 8 MiB and 4 MiB allocations before
opening fonts, leaving no contiguous 2 MiB block. Both font sessions still
open and render identical body/ruby-sized glyphs. Both normal and fragmented
runs inject all 547 OOM points, retain the first client, and reopen 32 times.
The fragmented run skips the separate 1 MiB quota-pressure stage because the
12 MiB peer is already active; that stage still runs in the normal fixture.
This is one demonstrated fragmented geometry, not arbitrary-fragmentation
or arbitrary-font qualification.

The backing fixture separately fills the 32-extent quota, drains through the
real task ledger while a peer survives, checks full heap recovery, and shows
that a 512 KiB extent succeeds while a 2 MiB request fails in the fragmented
geometry. No child list is trusted from client-writable payload memory.

RV32 compile-only checks cover the C++ allocator and Zig bridge. Their control
size sum is 6,685 bytes (4,920 allocator + 1,765 bridge), before independent
static alignment padding and stack. The host uses a separate 15,596,992-byte
array to emulate the current 32 MiB layout's CPU0 heap. A native port must
borrow from the already-initialized per-hart heap and bind the real task key;
it must not initialize another heap over live allocations.

The current receipt is
[`docs/measurements/2026-10-27-graphics-extent-groups.json`](../../docs/measurements/2026-10-27-graphics-extent-groups.json).
The earlier two-parent policy and its failure are retained below for comparison.

## Historical coarse-parent baseline (702082f)

Commit `702082f` used the actual `buddy_heap.zig` and `task_resources.zig`
without changing either. A host array models the 15,596,992-byte CPU0 heap
backing left by the current 32 MiB layout. Its payload after buddy metadata
and guards is 15,072,576 bytes. The array represents available kernel memory,
not an allocation reserved exclusively for graphics.

The bridge models one font service task. It loans 64 KiB multiples to
`LazyPool` from at most two canonical task-ledger entries. Every application
session uses the same service backing, with independent logical quotas and
lifetimes. One raw 128 KiB parent holds the shared-library span. A raw 2 MiB
parent is acquired when the small parent cannot satisfy a request and is
returned when its last loan is released. Requested parent payloads leave
128 bytes for buddy header/alignment, avoiding power-of-two boundary doubling.

The current two-parent limit has a measurable price:

| State | Kernel raw block occupancy |
| --- | ---: |
| Before library use | 0 |
| Only retained service state | 128 KiB |
| Sessions active in this fixture | 2,176 KiB (2.125 MiB) |
| Both sessions closed | 128 KiB |

The 2 MiB logical loan threshold and 1 MiB client thresholds still apply to
the suballocator. Kernel occupancy includes the unloaned parent capacity and
can therefore exceed the loan threshold. The active parent is shared between
sessions, not reserved separately per application. Returning one client's
loans can make them available to another without returning the whole parent
to the kernel yet. This is the current two-entry compatibility baseline;
smaller incremental kernel returns need a different backing/ledger policy.

Both backends pass the same 547 injected OOM points and 32 reopen cycles with
identical glyph/advance hashes. Additional backing checks exercise canonical
loan validation, buddy coalescing, service retirement through bounded
`drainOne`, full capacity recovery, and a separate ledger task surviving
service retirement with its bytes intact. These retirement checks contain no
HarfBuzz objects and do not qualify restarting process-global library state.

The fragmentation fixture leaves 2,358,592 bytes free with a largest block of
1 MiB. Acquiring the active 2 MiB parent fails cleanly despite the aggregate
free space. Releasing another task's 4 MiB allocation permits a retry. This
is a demonstrated limitation of the coarse-parent policy, not a guarantee
that enough aggregate free memory always permits opening a session.

RV32 compilation reports 4,920 bytes for `LazyPool` and 1,749 bytes as the sum
of bridge control-state sizes, before independent-global alignment padding.
Their 6,669-byte sum plus 64-byte padding allowance fits the earlier 8 KiB
control target. This excludes stack and is not a final native linked footprint.

The kernel variant still executes on the host: no native scheduler task,
interrupt masking, physical PSRAM, SD, Flash layout or display integration is
qualified. This fixture initializes its own heap; native integration must
borrow from the already-initialized per-hart heap and bind the real task key.
It must not initialize another heap over live PSRAM allocations.
C/C++ and third-party libraries run under ASan/UBSan; the Zig bridge
uses ReleaseSafe checks. The emulated heap's internal object lifetimes do not
have independent ASan redzones, so canonical records and canary tests remain
essential. The kernel receipt is
[`docs/measurements/2026-10-27-graphics-kernel-backing.json`](../../docs/measurements/2026-10-27-graphics-kernel-backing.json).

## Sources and attribution

All upstream revisions, downloads and SHA-256 pins are in `sources.json` and
the repository `provenance.toml`. No MeOS driver source is imported.

- FreeType is used under the FreeType License (FTL). Portions of this software
  are copyright © 2026 The FreeType Project (www.freetype.org).
  All rights reserved. The original license and source files remain in the
  download cache. The module configuration selects autofit, TrueType, sfnt and
  smooth in `ftmodule.h`. The tracked local
  [`autofit patch`](patches/freetype-autofit-map-error.patch) propagates reverse
  character-map initialization failure instead of allowing a later null
  dereference. `fetch_sources.py` restores the pinned archive before applying
  it; no SDK or system FreeType installation is modified.
- HarfBuzz is MIT licensed; its source and `COPYING` are retained. The custom
  configuration keeps Unicode, GSUB/GPOS and vertical support for static
  TrueType fonts. CFF, variable fonts, AAT, Graphite, color, SVG and math are
  outside the profile. `HB_NO_MT` requires the single-worker discipline.
- The unmodified BIZ UD Gothic and Mincho fonts are OFL-1.1 licensed. Both
  original OFL notices are downloaded and retained beside the font files.

The next native gate is backing ownership, RV32 allocation/stack behavior and
library lifetime under failure, followed by shared layout and presentation.

## RV32 instruction-level stack and link oracle

Run the separate ISA study with the ESP RV32 GCC installed:

```sh
NIHOS_GRAPHICS_RV32_CXX=/path/to/riscv32-esp-elf-g++ \
  sh tools/run-graphics-rv32-probe.sh
```

This first runs the existing memory probe, then builds a memory-stream oracle
for the host and RV32. Python 3.9+, CMake, a host C++17 compiler, POSIX `patch`
and the pinned Zig tool are needed. Unicorn 2.1.4 is installed into an ignored local virtual
environment from checksum-pinned binary wheels; no global Python installation
or hardware state is modified. The native host runner uses the Unicorn C API.

`generate_link_oracle.py` derives the Session directly from `font_probe.cpp`,
replacing only file opening and cache-fill reads with a read-only memory
source. The 256 KiB stream cache, allocator, size changes, shaping, glyph
rasterization and result hashing remain the tested implementation. A source
hash and generated source are retained. Full original TTF files are supplied
as external mapped test input; their 10.8 MB is not included in code/heap
footprint numbers and does not model native SD storage consumption.

The target links the real C++ allocator, opt-in kernel extent groups,
FreeType and HarfBuzz. Default FreeType file/memory allocation entry points
are explicitly unsupported, environment-variable properties are disabled,
and callbacks are mandatory. Newlib has a single fixed reent context and
bounded allocator hooks. Unused nosys stubs can remain in the image; the
runner stops if any selected unsupported syscall, abort or assertion entry
is executed. Both configurations' successful runs execute none of those
paths and make zero fallback libc allocator calls.

The linker uses synthetic code/data windows, not ESP32-P4 Flash partitions,
MMU mappings or boot images. The result has no dynamic C++ initializer and no
unresolved symbol. Newlib syscall warnings remain recorded: a successful ISA
fixture is not a general native C runtime port.

The instruction hook observes SP before every target instruction without
inserting calls into the target. It stops at the logical 16-byte stack guard
before an out-of-range stack access. A deliberately 128-byte stack is the
negative control. Two fonts, 12/16/24/32 px body with half-size ruby runs,
horizontal/vertical shaping give 16 cases per profile. Full pixel/glyph/advance
hashes must match the corresponding host run and each other.

| FreeType render pool | Observed RV32 stack peak | Stack cases |
| --- | ---: | --- |
| Upstream 16 KiB | 18,144 bytes | 4/16 KiB reject at guard; 32 KiB completes |
| Experimental 2 KiB | 3,808 bytes | 4/8 KiB complete with identical hashes |

The large frame is `gray_convert_glyph`: compiler stack-usage records show
16,688 bytes in the upstream configuration, reduced to 2,352 bytes by the
2 KiB pool. This uses FreeType's existing raster banding, not a static shared
scratch buffer. Only the standalone oracle selects this experimental option;
the existing memory probe and native firmware retain their settings.

The smaller pool processes more bands. The fixed fixture executes about
1.6% more RV32 instructions; that is not a Tab5 timing result. At 3,808 bytes,
a 4 KiB stack leaves 144 bytes after the current 16-byte guard and 128-byte
context frame, before native caller or SD/VFS overhead. It is not approved as
a 4 KiB native task. The initial receipt did not exercise forced auto-hint or
arbitrary fallback fonts. The extended hinting study measures forced
auto-hint separately.

The oracle's Session state is local to the entry function, matching this
probe's lifetime style; a production service's context placement is still
undecided. Interrupts, timer preemption, native storage calls, task teardown,
actual Flash placement and physical display are all outside the ISA fixture.
Static per-function stack sizes are not whole-call-chain upper bounds.

Each profile retains its ELF, map, compiler stack records and every failed
stack attempt under `build/graphics-rv32/profiles`. The receipt is
[`docs/measurements/2026-10-28-graphics-rv32-stack.json`](../../docs/measurements/2026-10-28-graphics-rv32-stack.json).
It records code/static RAM separately from stack, external font input and the
runtime PSRAM heap. These sizes cannot be treated as the final native-image
delta; the current Flash mapping and library/runtime overlap still need work.

## Hinting paths and a dedicated worker stack

The extended study in
[`2026-10-28-graphics-hinting-stack.json`](../../docs/measurements/2026-10-28-graphics-hinting-stack.json)
uses the same script. It adds immutable per-session load flags, used by both
HarfBuzz metrics and explicit FreeType glyph loading. Each mode has 16 cases
with exact host/RV32 hashes. The three modes must produce distinct hash
matrices; instruction-entry counters also require the intended hinter path.
This prevents an ignored flag from appearing to pass on both platforms.

With the 2 KiB raster pool and 1024 allocation records:

| Hinting policy | Observed RV32 stack peak | Measured record peak | Executed path |
| --- | ---: | ---: | --- |
| Default, pinned BIZ TrueType hints | 3,824 B | 195 | TrueType interpreter |
| Forced auto-hint | 16,864 B | 694 | CJK and Latin auto-hint metrics; no TrueType interpreter |
| No hinting, including auto-hint | 3,824 B | 184 | Neither hinter |

Forced auto-hint rejects 4/8/16 KiB stacks and completes with 32 KiB. Both
other modes complete with 4/8 KiB, but a 4 KiB native stack leaves only 128 B
after the 16 B guard and 128 B integer context frame, before native caller/IO
overhead. It remains unsuitable for integration on the existing worker stack.
The upstream 16 KiB raster pool still rejects 4/16 KiB and completes with
32 KiB, with an observed 18,160 B peak in the extended entry function.

The first auto-hint attempt exhausted the allocator's 256-record capacity,
not its byte quota. Pinned FreeType 2.14.3 ignored a failed reverse-character
map initialization in `af_latin_metrics_init`, then dereferenced its null map
from `af_latin_hints_apply`. The captured host UBSan failure is retained in
[`graphics-autofit-failure.txt`](../../docs/measurements/2026-10-28-graphics-autofit-failure.txt).
The local tracked patch propagates that error through the existing cleanup
path. Both 256- and 512-record configurations now refuse auto-hint safely on
host/RV32, append no hash for a failed draw, free both clients and retain only
65,792 B of service backing. The successful 1024-record profile keeps the
original 2 MiB total and 1 MiB/client byte quotas.

| Allocation records | RV32 allocator controller | Synthetic static writable data | Synthetic Flash payload |
| --- | ---: | ---: | ---: |
| 256 | 4,936 B | 9,401 B | 587,125 B |
| 512 | 9,032 B | 13,497 B | 591,221 B |
| 1024 | 17,224 B | 21,689 B | 599,413 B |

Only the ISA oracle's successful 2 KiB-pool profile selects 1024 records. The
ordinary memory probe retains 256 records and its 8 KiB controller ceiling.
The larger record array has a fixed cost: it is not demand allocated. The
allocator now scans its active prefix, reuses interior holes and trims empty
trailing records, so unused configured capacity does not lengthen every lookup.
The 3000-operation ownership/realloc/churn checks cover that behavior.

All three successful RV32 modes peak at 1,310,976 B of actual buddy backing
for two open clients and retain 65,792 B after closing them. The 64-bit host
auto-hint run peaks higher, at 1,442,048 B. Those backing measurements exclude
the controller, static library data, stack and external full TTF inputs.
Mode selection retains the same linked modules; it does not measure a build
with the auto-hinter removed. Instruction counts are ISA work observations,
not hardware timing or a rendering-quality comparison.

The next native candidate is one serialized font worker with a 32 KiB internal
SRAM stack and the explicit 1024-record profile. Multiple clients share that
stack and controller. Static writable data plus the proposed stack sum to
54,457 B in this synthetic budget; that is not a final firmware SRAM delta.
Native task entry, storage callbacks, preemption, Flash/loader placement and
physical Tab5 qualification remain pending. The
[`font-worker contract`](../../docs/graphics-font-worker.md) records lifetime,
reservation/reclamation choices and acceptance gates; this commit does not
resize or start a native worker.

## Shared task runtime and native context execution

Run the next, independent context study with:

```sh
NIHOS_GRAPHICS_RV32_CXX=/path/to/riscv32-esp-elf-g++ \
  sh tools/run-graphics-worker-probe.sh
```

This executes `src/arch/riscv32/task_runtime.zig`, the shared scheduler and
task-call ABI, and the **unchanged** integer trap/trampoline/return assembly
from `src/platform/native/start.S`. A small test dispatcher selects captured
task frames using that runtime. It is not the full native P4 dispatcher and
does not execute the P4 boot entry. Task runtime now publicly exposes its
existing context types so the fixture uses the same types without duplicating
their module or ABI definitions.

The fixture runs bootstrap, font and peer tasks on separate stacks. The font
task owns one 32 KiB stack and runs the real two-session FreeType/HarfBuzz
fixture. The peer checks a stack canary and increments progress. IRQ handling
uses its own 8 KiB stack with MIE clear, validates every frame's saved SP and
all bottom guards, then executes the native restore/MRET path. Completed
tasks are reaped from bootstrap after both exit through the actual task-call
ABI. No production native stack layout or linker whitelist is changed.

The Unicorn host runner supplies synchronous ECALL entry and timer-entry CSR
effects. It injects timer traps only at instruction boundaries with MIE set,
including inside HarfBuzz and a deep FreeType call chain. The target performs
all integer-register stores, stack switching, scheduling, restores and MRET.
The software event source does not establish P4 timer/CLIC behavior, nested
interrupt support, hardware latency or an SMP result; only hart 0 executes.

The controls distinguish scheduling mechanisms:

- Without timers or callback yields, the peer must make zero progress while
  the font call runs, then both tasks must exit and be reaped normally.
- With timer injection and no callback yields, the peer must progress, both
  targeted library interrupts must occur, and all 16 auto-hinted hashes must
  match the non-preempted control and sanitized host reference.
- With timers disabled, a yield after every 32 source-cache fills tests
  suspended FreeType/HarfBuzz callback frames. All 16 default-hinted hashes
  must match the host and the peer must progress.
- A logical 16 KiB font stack must stop at the guard. The ISA runner also
  replays the earlier single-stack default fixture after extracting its ELF
  reader into `isa_image.h`.

Full original TTFs still reside in external read-only test mappings. Callback
yields do not read an SD card or model native asynchronous IO. The buddy
bridge still initializes an isolated modeled heap and ledger; binding it to
the native OS task owner, existing live PSRAM heap and shutdown semantics is
pending. Client-session memory is recovered, but HarfBuzz's service backing
remains. Reaping the fixture task does not qualify service teardown/restart.

The synthetic linker reserves 96 KiB of NOLOAD stack address space: two 8 KiB
bootstrap and two 8 KiB IRQ spans, one 4 KiB peer span, 28 KiB alignment gap
and the 32 KiB font span. The gap keeps the logical undersized-stack control
from aliasing another valid stack. This is not a proposed production SRAM
reservation or a native loader collision audit.

Artifacts and receipts are retained under `build/graphics-worker`. The next
integration boundary remains native image/Flash placement, live-heap ownership
and a task-safe native read-at provider, followed by physical qualification.

The source-bound receipt is
[`2026-10-28-graphics-worker-context.json`](../../docs/measurements/2026-10-28-graphics-worker-context.json).
Its successful cases observed:

| Case | Peer progress during font work | Font stack peak | IRQ stack peak |
| --- | ---: | ---: | ---: |
| No preemption, forced auto-hint | 0 | 16,880 B | 160 B |
| Injected timer traps, forced auto-hint | 166 | 16,928 B | 160 B |
| Source-callback yields, default hinting | 18 | 3,872 B | 160 B |

The preempted case executes 166 injected timer entries and 501 total context
switches. Its deepest observed font-stack point is in `nih_native_trap`, so
the 16,928 B includes an actual saved integer frame. HarfBuzz entry and a
deep allocation inside the FreeType auto-hint call chain are interrupted
explicitly. All 16 hashes match the sanitized host and no-preemption control;
both clients close and both task images are reaped. All successful cases
retain only 65,792 B of service backing, with zero fallback libc allocations
or selected unsupported runtime calls.

The final synthetic worker link contains 441,152 B text, 153,817 B read-only
data and 19,072 B initialized data: **614,041 B of loadable code/data**, plus
3,017 B BSS and the separately reported 96 KiB NOLOAD stack span. There are
no unresolved symbols, dynamic C++ initializers, F/D ISA attributes or hardware
FP instructions. This remains a synthetic link, not a firmware image size.

An initial single-section Zig object retained unused compiler-rt routines,
making its loadable code/data 1,038,769 B. Enable function/data sections so
the linker can discard them, and use the same trapping `std.debug.no_panic`
root as the native program. ReleaseSafe checks remain enabled. This removed
424,728 B of incidental link overhead; the final candidate reran all controls
and comparisons. The original ELF/map/report remain in the ignored build
directory and their identities and sizes are recorded in the receipt.
