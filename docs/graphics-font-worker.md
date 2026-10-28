# Font worker: stack and lifetime contract

Status: proposed native integration boundary, 2026-10-28. The executable
evidence is a standalone RV32 ISA fixture, not a running native service.

Update: the separate [native graphics fixture](native-graphics.md) also passes
native P4 boot/task/timer execution in the emulator and both revision-profile
image audits. Four client cycles now share one live task and service-owned
HB backing through a bounded request/reply fixture. Empty receives block in
the scheduler, and an explicit terminal acknowledgment precedes EXIT. The
[request-boundary decision](adr/0044-native-font-request-waits.md) limits this to
one dispatcher and a fixed qualification matrix; application routing,
cancellation and service restart remain unqualified. Native filesystem input and physical
qualification remain pending. The sections below retain the design and earlier
ISA evidence that led to that fixture.

## Ownership

One serialized worker owns FreeType/HarfBuzz calls and private mutable face
state. Multiple applications can keep sessions open simultaneously. Sharing
the worker does not require closing the reader to open an editor. The present
`HB_NO_MT` configuration does not permit concurrent library calls on two harts.

An application's immutable font instance identifies the source revision,
face, pixel size, OpenType features and hinting policy. Hinting must be part
of any glyph/metrics cache key: changing it can change both positions and
pixels. The worker may privately change a face's size between body and ruby
runs, but cannot expose that mutable size as shared public state.

Source caches and face allocations are client-owned and demand allocated.
The existing two-session allocator probe already checks failed opens,
allocation failure, surviving-client output and repeated close/reopen.
HarfBuzz's process-lifetime state belongs to the service, not its first
client. The worker stack likewise belongs to the service, not each session.
It is not included in the font-only PSRAM receipts.

The allocator's allocation-record capacity is a separate limit from its byte
quota. Auto-hint initialization can keep many small allocations alive across
both faces. A session must fail cleanly when either limit is reached. Merely
raising the byte quota cannot repair record exhaustion, and raising a record
array costs fixed controller memory even when most entries are unused.
The probe scans only the active record prefix, reusing interior holes and
trimming empty trailing records on release. Configuring spare capacity must
not force every allocation lookup to walk the entire spare array. This is
still a bounded linear allocator, not a real-time latency guarantee.

## Stack placement and release

The [extended RV32 measurement](measurements/2026-10-28-graphics-hinting-stack.json)
observed 3,824 B with default BIZ TrueType hints or no hinting, and 16,864 B
with forced auto-hint. Auto-hint rejects even a 16 KiB stack. Select **32 KiB
for the first native font-worker experiment**, retaining the 2 KiB raster
pool and 1024 allocation records. This is a candidate capacity for the pinned
fixture, not a bound for arbitrary fonts or the untested native IO call chain.
The integer context frame and guard leave 15,760 B beyond that observed peak.

The 1024-record controller itself is 17,224 B on RV32; the synthetic oracle's
total static writable data is 21,689 B. Adding the proposed stack gives
54,457 B, shared across clients and separate from their PSRAM backing.
These are explicit fixed costs, not a final native-image delta. A restricted
hinting profile could use less controller/stack space but must specify the
fallback and rendering policy rather than silently disable a hinter on OOM.

Keep the first native candidate's worker stack in internal SRAM. A PSRAM
stack would add cache availability, trap, shutdown and ownership requirements
that these font measurements do not qualify. Font source reads and raster
work must run in task context with interrupts permitted, never in an IRQ.

Do not enlarge every current 4 KiB task stack. The current six physical worker
slots and the separate 56 KiB stack bank have fixed, audited extents. A font
profile needs an explicit role/capacity and matching linker, context-frame,
guard, loader-collision and runtime checks. Bootstrap and IRQ stacks cannot
be borrowed for a persistent service.

`src/platform/native/memory.zig` currently exposes a monotonic internal-SRAM
arena: allocating a stack there on each service start would not reclaim it
on service stop. The PSRAM extent-group allocator does reclaim its pages,
but is not an internal-SRAM stack allocator. Lazy font allocation therefore
does not yet establish a lazy, reclaimable service stack.

For a first opt-in native fixture, a single explicit SRAM reservation is a
reasonable way to qualify scheduling, storage and guards. It must be reported
as resident SRAM even while the service is idle. Production on-demand stack
lifetime needs a reusable SRAM stack pool or allocator before claiming that
all service memory returns on last close. Neither policy is implemented by
this study.

## Native acceptance gates

1. Link a font-only profile with its explicit stack reservation and Flash
   placement. Audit real loader mappings, code, static SRAM, stack bytes and
   the retained internal-heap floor for both revision profiles. Synthetic
   library sizes are not the final firmware delta.
2. Execute on that stack through the real task entry/dispatcher. Exercise timer
   preemption during shaping/rasterization, verify saved frames and guards,
   then resume and compare output. Keep enough measured space for the complete
   configured context frame, including FP state if that task enables it.
3. Replace the memory source with the native read-at provider and measure its
   nested call chain. Include short reads, removal, revision changes and
   failure without publishing a partial result. The default libc file API
   remains unsupported.
4. Test two open clients, client cancellation and service stop/restart without
   releasing the live stack. Reclaim a stopped service's stack only after it
   cannot execute or resume, and after all callbacks have returned.
5. Retain exact-candidate emulator and physical Tab5 evidence separately.
   Arbitrary fonts, arbitrary sizes and worst-case stack depth need additional
   limits or tests; a finite fixture does not certify them.

These gates precede native service integration. Paragraph wrapping, ruby
placement, vertical layout, caret/selection and SDL remain separate framework
work; shaping body/ruby runs does not implement those features.

## Context-execution fixture

`tools/run-graphics-worker-probe.sh` now exercises the shared task runtime and
unchanged native trap/trampoline/return assembly with actual FreeType/HarfBuzz
work. The event source, dispatcher wrapper, heap initialization and mapped
inputs are still a standalone ISA fixture. It tests part of gate 2, including
another task progressing during a suspended library call; it does not complete
the native-image, native storage or task-resource binding gates.

The existing SD controller probe owns a boot-time controller and clock before
CPU1 release. Its `active_controller` is valid only during that boot probe.
It cannot simply be retained by a later font task. A native read-at provider
needs persistent controller ownership, task-safe timing/waits, source lifetime
and removal/revision handling. Yielding a synthetic read callback first checks
that the font call chain can survive a task switch without making native IO
or filesystem claims.

The [context receipt](measurements/2026-10-28-graphics-worker-context.json)
records 166 timer preemptions and 166 peer progress increments while the
auto-hinted font task runs, versus zero peer progress without preemption.
All 16 glyph/position/raster hashes match the control and sanitized host.
Source-callback yields independently let the peer progress 18 times with
timers disabled. Completed font/peer tasks exit and are reaped through the
common ABI, with both font clients' backing reclaimed.

Observed font stack is 16,880 B without preemption and 16,928 B including
an actual interrupt frame; IRQ stack peaks at 160 B. A 32 KiB reservation
therefore leaves 15,824 B beyond the observed peak and 16 B bottom guard in
this fixture. That interrupt frame is already included; do not subtract it
twice. Native storage, additional caller frames and real interrupt delivery
are still unqualified. The logical 16 KiB stack rejects at its guard.
