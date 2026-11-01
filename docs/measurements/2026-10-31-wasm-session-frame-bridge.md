# Common session to scheduled Wasm frame worker

The same OS-owned `src/app/session.zig` lifecycle now drives a real RV32 WAMR
worker through open/render/close requests. This replaces the monolithic test
runner for the new session fixture. Existing native and boot/task fixtures
remain available independently. It is a headless emulator integration, with
no device Wasm profile or physical display claim.

## Ownership and execution

`src/platform/native/wasm_session.zig` implements the common Session hooks.
The foreground owns a 32 KiB frame lease and a separate pinned 488 KiB engine
lease. Its registered child uses the engine lease's 64 KiB native stack.
Only that child enters WAMR, verifies the signed boot journal, loads the module,
and executes guest frames. The engine remains initialized between frames.

A single-caller/single-worker mailbox carries a bounded operation, sequence,
selected state and native frame extent. Publication/collection use release and
acquire ordering. Busy requests cannot be replaced and replies must match the
in-flight sequence. The mailbox clears the frame address before a render
callback returns. Host tests cover premature/stale acknowledgements, duplicate
consumption, pointer clearing and sequence exhaustion. A mailbox is reset only
after its previous worker has been reaped.

The foreground waits by yielding to normal scheduling; the worker parks on
task events between requests. Interrupts remain enabled during guest execution.
This is a synchronous session API: other tasks and both hart timers continue,
but the foreground network/camera service loop is not pumped inside a request.
The guest has the signed package's instruction budget. Native engine faults
and forced asynchronous termination are outside this contract.

For each frame the worker attaches only the Session's 160x80 RGB565 buffer,
opens the matching instance's admitted graphics scope, calls Wasm, closes the
scope and detaches the adapter before replying. Calls outside the scope are
refused before guest text mapping. The presenter also verifies that the
mailbox retained no frame address and that the adapter has been detached.
Presentation stays with the foreground.

Session shutdown sends close, waits for engine/arena teardown and task exit,
reaps the task, checks the stack guard, wipes the engine extent and releases its
pin. Only then does the common Session wipe and release the frame. Partial-open
failure follows the same reap-before-release path.

## Reproduction and evidence

With the pinned toolchains and emulator loader prepared:

```sh
sh probes/wamr-native/run-session-emulator.sh
```

The script sets `NIHOS_NATIVE_WASM_SESSION_TEST=1` with headless
`WASM_TASK=1 BOOT_TEST=1`. Other profiles are rejected. The image audit checks
the session entry, runtime/import functions, package journal and Flash extents;
the boot-only SP-switch symbol must be absent. Every case runs unchanged ELF
and Flash image bytes.

Six first-round cases use external UART input or timeout: normal `0x10q`,
no input, early `q`, cancel, instruction-budget trap and presenter failure.
Each then performs an injected partial-open failure after module load, followed
by a successful restart using synthetic `0x10q`. The three launches have
distinct task generations. Every successful presentation compares all 12,800
logical pixels against literal glyph/background references. Rejected input
does not draw; import counts are checked exactly.

Across all cases the frame and engine requests total 532,480 bytes (520 KiB).
The buddy allocator charges 589,824 bytes (576 KiB); every exit restores that
entire charged capacity. Observed worker stack use is 23,632 bytes in both
rounds, within 65,536 bytes. Both hart timers
advance, and workers take timer interrupts and block on event waits. These
are emulator observations, not physical timing or memory qualification.

The integration reconciles main through
`980f522a3575c3922b956bf97f46a228b557070d`, retaining its continuous-camera
changes while leaving the dirty main checkout untouched. The imported camera growth exposed
the native session image's SRAM floor. Foreground console handoff/usage and
Session guard checks now share its audited Flash extent; IRQ and cache-control
routines remain resident. Native-session device images reserve 49,216 bytes of
primary SRAM heap enabled and 50,496 disabled. The 49,152-byte floor is unchanged;
the enabled profile has only 64 bytes above it. These are linked reservations,
not measured free device memory.

The manual emulator CI job includes the new runner. Debug/ReleaseSafe, static
analysis, Python regressions, host SDK checks, the previous scheduled task and
boot UART matrices, native session emulator cases and device ON/OFF image audits
are retained with the [candidate identity](evidence/2026-10-31-wasm-session-frame-bridge/identity.json).
Remote CI and physical verification have not been run.

## Remaining work

Connect the normal shell's backend selection/input routing to this backend and
the existing rotated presenter, preserving camera/console exclusion and repaint.
This fixture does not execute that UI route or physical scanout/cache path.
WAMR alignment adoption must be resolved before a device image is enabled.
Production trust/counters, native persistent installation, arbitrary forced
kill, concurrent apps and a stable public SDK remain outside this experiment.
Publication/merge still requires the agreed exact-candidate physical check and
required CI.
