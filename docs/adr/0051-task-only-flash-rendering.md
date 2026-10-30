# 0051: Task-only rendering code in mapped Flash

Status: accepted for host/native-emulator qualification, 2026-10-28.

The basic-prohibition fixture reaches the 48 KiB primary SRAM heap floor on
the device profile. Preserve that floor, region sizes, compiler runtime safety,
stack reservations and task quotas. Reclaim code space before adding ruby layout.

Split the native consumer into an SRAM wrapper and two explicitly placed Flash
functions: `native_surface.paint` and `native_surface.draw`. The wrapper checks
CPU0 bootstrap context with interrupts enabled, obtains the task-owned PSRAM
canvas, calls paint with borrowed canvas/raster storage, checks context, canvas and bootstrap/IRQ stack
guards again, and frees the allocation. Paint owns the finite three-pass
composition; draw owns checked glyph placement/blending. Neither Flash function
allocates, releases task memory, selects a task or handles an interrupt. Generic
surface/flow helpers may inline there; separately emitted helpers, allocator,
transport, dispatcher, trap/return and context checks remain in SRAM.

Place the two functions in a distinct RX/non-writable section immediately after
the pinned fonts, inside the existing second contiguous loader mapping. Keep
library text, font bytes and source identities unchanged. The image auditor
must accept exactly those two symbols in this span, reject non-graphics modes,
extra/missing/renamed functions, writable flags, invalid/overlapping/gapped
extents and redirection of kernel/libc helpers. Compare every merged mapped
byte with the ELF and retain the stock loader's two-mapping requirement.
This is an explicit placement exception, not a wildcard permission to move
kernel execution into Flash.

A separate SRAM timer hook may read only internal fixed metrics/context state.
It must reject renderer entry with MIE clear and must never read a Flash table
or PSRAM buffer in that rejection path. Record PC samples inside paint/draw,
context checks before/after the call, timer captures while paint is active and
captures with an interrupted PC in the rendering Flash extent. Require unchanged
matrix/raster/unwrapped/wrapped/prohibition hashes, all guards, explicit lease
retirement and complete final heap recovery. Audit both revision profiles;
execute the exact emulator image separately.

Rendering requires active Flash mappings/caches throughout the call. This finite
native fixture performs no runtime Flash writes/cache-off operation, and does
not establish cache-off rendering safety, a production update/renderer exclusion
protocol or physical cache/PSRAM/latency behavior. Runtime context checks are
qualification guards, not privilege isolation or a complete call-graph proof.
A production cache-off path must coordinate/exclude rendering before disabling
its mappings. Physical Tab5, scanout, dynamic font IO, ruby-base association and
service restart remain separate gates.

The first structural attempt found that the assembly trap had a global symbol
but no ELF function/size metadata. Add `.type`/`.size` around its existing body
so the auditor can bound it, preserving instructions, context ABI and region
policy. A later capture emitted the native pass but mixed an emulator diagnostic
into the CRT pass line; the unchanged strict parser rejected it. Preserve both
failed attempts. Capture UART stdout and emulator stderr separately, retain both
raw files and bind their digests; do not relax pass matching or filter the log.

Final observations: both revision-profile audits pass. The two rendering
functions occupy 2,816 B in Flash. Net primary SRAM recovery is 3,328 B on each
profile, including the new guards/observability; the device profile retains
52,480 B of primary heap versus 49,152 B before placement. Existing SRAM regions,
font stack/library reservations and PSRAM charges are unchanged. The exact native
emulator image records three paints/99 glyph draws, six task-context checks,
six active-call timer captures including four PCs inside the Flash rendering
span, and 7,336 IRQ entry rejections. All prior pixel/hash/control/cleanup gates
pass and original CPU0 free heap returns after archive release. No physical
hardware is accessed and no application-ready ruby or scanout claim is added.
