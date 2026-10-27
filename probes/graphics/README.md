# Demand-allocated graphics memory experiment

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
  download cache. The only upstream source configuration change selects the
  autofit, TrueType, sfnt and smooth modules in `ftmodule.h`.
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
for the host and RV32. Python 3.9+, CMake, a host C++17 compiler and the pinned
Zig tool are needed. Unicorn 2.1.4 is installed into an ignored local virtual
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
a 4 KiB native task. The registered auto-hinter also has larger linked static
frames; forced auto-hint and arbitrary fallback fonts are not exercised.

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
