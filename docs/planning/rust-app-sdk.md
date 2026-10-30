# Rust application SDK: first experiment

Status: experimental Rust SDK, host surface integration, and native emulator fixture.

For the current integration base, reproducible checks and the remaining finite
landing gates, see [experimental SDK landing](rust-sdk-landing.md). The reports
below retain their original candidate identities and qualification limits.
This is not a stable SDK, a native application loader, or an on-device
display/input integration.

## Boundary and experiment

`nihos-app` is `no_std` and its `Services` trait is the common source-level
boundary. The probe application `draw` uses logical coordinates and RGB `0x00RRGGBB`;
`selected` models an input state supplied by the embedding host. It is not an
input service. The native implementation calls the functions declared in
`include/nihos_app_probe.h`. The C host records calls and checks both states,
error propagation, and invalid state rejection. Run:

```sh
sh probes/rust-app/run-host.sh
```

The native text pointer is borrowed only during the synchronous call and the
host must neither retain nor mutate it. Zero means success and nonzero is
propagated unchanged; `-1` is used by the probe for invalid state and an
unrepresentable text length. The backend is trusted: this interface cannot
validate arbitrary native pointers or isolate native applications. An error in
one drawing operation stops the frame; earlier operations are not rolled back.
No allocation, file access, display presentation, timing, or cancellation is
provided. The panic handler in the probe spins and is not a production policy.

`src/graphics/rust_app_probe.zig` is a single-owner adapter to the existing
RGB565 surface and basic ASCII font. It clips rectangles and glyphs, supports
printable ASCII only, rejects unsupported text before writing, limits text to
128 bytes, and never retains the incoming text pointer. The owner must provide
valid exclusive surface memory, serialize calls and detach before releasing it.
This experiment does not present to a physical screen. Its host test checks
pixel values, clipping, padding, invalid text and attachment lifetime:

```sh
NIHOS_ZIG=/path/to/zig-0.17.0/zig sh probes/rust-app/run-surface.sh
```

The same script builds the Rust and Zig sources into a freestanding RV32 ELF
using `riscv32imac-unknown-none-elf` and the soft-float `ilp32` ABI, matching
the native integer build. It is a link fixture with no board startup or
execution. The previous `riscv32imafc` archive uses `ilp32f` and must not be
linked into that integer build.

The common API and C ABI are provisional. Clipping, bounds, font and text limits,
input events, frame ownership/presentation, cancellation, version negotiation,
resource quotas and cleanup must be specified and tested before stabilizing it.
In particular, call success here does not promise physical scanout.

The opt-in native boot fixture uses the same Rust application and adapter on a
private offscreen surface, checks both states and glyph pixels, then releases the
surface. `sh probes/rust-app/run-emulator.sh` builds and checks the native
emulator image; see the [recorded run](../measurements/2026-10-29-rust-app-emulator.md).
It does not launch a task, accept input, or use a physical display.

## Display-owner experiment

`NIHOS_NATIVE_RUST_DISPLAY=1` enables an isolated opt-in device build. The
CPU0 diagnostic display owner translates serial bytes `0` and `1` into the
probe state, renders via Rust and Zig into a private 160x80 scratch surface,
rotates it into logical rectangle (16,16)..(176,96), and publishes cache
lines with the existing display-owner mechanism. Consecutive inputs before a
service turn can coalesce to the latest state. This is a fixed sample, not an
application event API, task, general compositor or privilege boundary. There is
no touch or hardware-keyboard integration. The single optional display-tail
reservation is exclusive: network, devices, storage and other optional
services are rejected in this profile. Normal builds leave the option off.

The host test drives `0 -> 1 -> 0`, checks RGB565 and glyph pixels in the
rotated physical geometry, checks the adjacent region, and rejects overlapping
buffers and undersized storage. The device build and static audit pass. A physical capture verified the exact
candidate, serial-driven state transitions and display-owner publication; it
then restored and verified the prior Flash. Optical output, touch and keyboard
input remain unverified. See [candidate report](../measurements/2026-10-29-rust-display-candidate.md).

The qualification emulator now registers a Rust function as the CPU0 native
lifecycle task entry. That task exercises drawing and SDK scalar task calls,
including an invalid sleep, then returns and is reaped. A separate host Wasm
probe uses the same app source and tests both input states, error propagation,
and linear-memory/UTF-8 rejection. See the [task and Wasm evidence](../measurements/2026-10-29-rust-native-wasm-sdk.md).
These fixtures do not provide a general task loader. A later opt-in emulator
fixture runs the Wasm build in WAMR, but it is not enabled in the normal OS
profile and is not yet a production nihos runtime.

## Native integration gate

Compile the same app for the actual P4 instruction and floating-point ABI;
link its static archive into a finite native fixture. The display owner must
serialize access, translate the API onto the existing RGB565 surface and text
renderer, present damage with the existing cache/scanout protocol, and route a
bounded input event. Establish lifecycle, panic/failure and task-owned cleanup
without relying on `Drop` after forced termination. Test on a host first, then
emulator where applicable, then an identity-matched physical image. The
existing diagnostic display is an owner-specific fixture, not yet a general
concurrent app service.

## WAMR host experiment

The fixed upstream WAMR 2.4.5 classic interpreter has run the same application
with host imports and instruction metering. A malicious import pointer, bad
text, an infinite loop, a small runtime pool and truncated module are tested.
See the [host evidence and memory accounting](../measurements/2026-10-29-wamr-host.md).
The later native emulator fixture links that interpreter into an ESP32-P4 image
with fixed buddy arenas, a private stack and a CPU0 owner. It now parses and
admits the signed package before copying its authenticated Wasm payload into the
runtime-owned buffers.
See the [native WAMR boundary](wamr-nihos-port.md). This remains a candidate
evaluation, not a production runtime selection decision.

## RV32 preparation

A separate [host journal-to-runtime fixture](../measurements/2026-10-29-journal-wamr-host.md)
now builds the actual Rust Wasm, signs it, prepares trust/package journals, reopens
them in a fresh boot-admission process, compares its recovered payload with the
build bytes, and executes that file in WAMR. Wrong-root and damaged-package
inputs produce no payload file. The handoff is a runner-owned host file; the
production admission-to-execution interface remains open.
The later [same-process host path](../measurements/2026-10-30-journal-wamr-buffer-host.md)
reads journal snapshots once, admits through a Zig C ABI and loads the private
payload buffer directly into WAMR. All repeated loads use owner-held copies.
Corrupt media, wrong roots and unsealed counters stop before runtime
initialization. This removes the exported-file handoff for that host fixture.
The same ABI now receives platform service grants and returns only the signed
package's admitted services. The runtime owner binds them to a specific WAMR
instance; graphics imports require an attached active matching owner and the
effective graphics bit. Zero grants reject the signed graphics app before
runtime initialization. Host probes also reject inactive, mismatched and
detached owner contexts without drawing or mapping guest text.
These four import-entry checks now also execute on
[RV32 in the native emulator](../measurements/2026-10-30-wamr-native-owner.md).
Each of two WAMR instance lifecycles receives the signed package's graphics bit
and a distinct owner context, deactivated and detached before destruction.
The existing allocator recovery and dual-hart/timer soak still complete.
The [next native fixture](../measurements/2026-10-30-wamr-native-surface.md)
routes those imports into the existing native RGB565/ASCII adapter. It checks
clipped offscreen rendering for both app states, exact first-glyph R/P pixels,
unchanged frame checksums on rejected calls, padding/guards and adapter detach.
The surface stays private to the synchronous owner; physical presentation and
event routing remain later integration stages.
The [bounded owner-dispatch extension](../measurements/2026-10-30-wamr-native-events.md)
now accepts synthetic `0`/`1` inputs before synchronous frame calls, verifies
`Ready -> Pressed -> Ready`, and rejects invalid/busy/stopped operations without
changing state or drawing. Graphics imports require an owner call scope, which
clears on return and trap. Driver-backed input and scanout remain open.
The later [UART fixture](../measurements/2026-10-30-wamr-native-uart.md)
receives external emulator-injected `0`, `x`, `1`, `0`, `q` through the existing
ROM console RX ABI. It renders three additional frames, rejects the unsupported
byte, stops on quit, and proves no-input timeout still releases all resources.
It exercises emulated UART RX; touch/keyboard, the diagnostic USB console and
scanout remain separate integration work.
The [UART failure matrix](../measurements/2026-10-30-wamr-native-uart-matrix.md)
also checks no input, partial input, early quit, overflow, wrong order and a
fourth frame request. All six stop with exact expected counters and complete
owner/surface/arena cleanup on the unchanged emulator candidate.
The [full-surface fixture](../measurements/2026-10-30-wamr-native-full-surface.md)
then moves rendering off the native stack into a separate 32 KiB owner segment.
Its 160x80 RGB565 frame is checked pixel by pixel, including all Ready/Pressed
glyphs, background, padding and guards. The requested lease is now 488 KiB;
private-stack high-water is 23,692 bytes. Presentation remains separate.

The test module can be built with one 64 KiB page, no growth and a 16 KiB stack.
The initial WAMR compile-only RV32 integer archive identified its platform and C
dependencies. The later native fixture closes those symbols and executes in the
emulator, while the general platform obligations remain open. See the [compile
evidence](../measurements/2026-10-29-wamr-rv32-compile.md) and [platform
obligations](wamr-nihos-port.md).

## Wasm acceptance gate

Reuse the application and source API with a separate Wasm backend. Define an
import ABI, validate linear-memory ranges and UTF-8 before use, bound resources,
handle traps and execution interruption, and test invalid and overflowing
ranges. Match the native observable drawing/error behavior for the same input
sequence. Measure runtime code, resident memory, per-instance memory, stack,
startup and input/draw latency on the device. A Wasm compile or a Node run is
not evidence that a selected embedded runtime supports the module, nor does a
runtime alone implement rights, quotas or isolation of host services.

The experimental [application package boundary](nihos-app-package.md) defines
one canonical signed byte sequence and connects verifier-owned key, revocation,
and rollback results to the existing application policy. A strict Ed25519
adapter and package-only WAMR path run on RV32 in the emulator. A separate
two-slot host model now fixes install ordering and sequence/trust-epoch commit
semantics. A second host model fixes authenticated trust-snapshot ordering
relative to an external monotonic epoch. An experimental canonical key/revocation
snapshot and Ed25519 root adapter now close the host chain into package
admission. A 468-cut integration model also carries root rotation and package-key
revocation through persistent recovery, while production roots, a real
protected counter/storage adapter,
consent, and physical qualification remain open. Installation is an
OS-owned control path, not an application SDK service: Rust applications do not
choose trusted keys, advance their own rollback floor, or mark themselves
verified.
Normal and offline-recovery root roles are now cryptographically separated in
the snapshot header. A dedicated OS-owned recovery replacement and subsequent
new-normal-root handoff now pass host crash matrices; neither is an SDK escape
hatch or permission exposed to applications.
The package/trust storage callbacks also pass a host `pread`/`pwrite`/`fsync`
close-and-reopen probe. This remains OS infrastructure, not Rust application
file access or physical durability evidence.
The root-signed trust journal, monotonic-counter fixture and Ed25519 package
journal additionally pass a ten-process host sequence through the boot
coordinator: commit sequence 1, kill the sequence-2 writer with parent-issued
`SIGKILL` before its commit record,
recover sequence 1 after process restart, retry, and recover sequence 2 after
another restart. Subsequent processes commit epoch-2 key revocation and exit
immediately with `_exit(86)` before counter advancement, stop before package
reads if sealing fails again,
seal the lagging counter on restart, reject
boot/reinstall of the package, and reject the saved epoch-1 trust journal against
counter floor 2.
Four additional package cuts use parent-issued `SIGKILL` during invalidation,
partial payload/record writes, and after commit sync. Each has a separate boot
recovery process and exact old/new package-byte comparison.
Committed-payload corruption and substitution with the old signed package also
reject boot/reinstall without falling back to the healthy old slot. Reversing
the changed package bytes restores sequence-2 recovery in separate processes.
An OS-owned boot coordinator now seals trust first, reconstructs the package
trust provider, and re-admits the installed package before returning bytes to a
runtime. It distinguishes unprovisioned, no-package and recovery-maintenance
states and rejects concurrent owners. This path is host-executed and RV32
compile-checked. It is now the native emulator's WAMR load source through a
private mutable copy of build-generated journal fixtures. The OS path recovers
sequence 1, proves an interrupted commit still recovers sequence 1, retries
sequence 2, replaces the coordinator and recovers sequence 2 before WAMR entry,
while remaining infrastructure outside the Rust application
SDK. The separate host-file probe is process-restart evidence; the emulator
fixture itself is not persistent Flash or process-restart evidence.
