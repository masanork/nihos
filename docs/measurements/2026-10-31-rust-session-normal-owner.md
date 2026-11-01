# Foreground Rust session: normal native UI and host Wasm parity

Code candidate: `a1784eaf8ff86b5a98597e764e74efe38feb946c`, on the isolated
`codex/rust-sdk-integration-20261030` branch. This report separates host execution,
headless ESP32-P4 emulator execution, device image construction and physical
qualification. No image from this report was run on Tab5, pushed or merged.

## Implemented ownership

`src/app/session.zig` owns one serialized foreground lifecycle. Its hooks acquire
a 32 KiB frame lease, open the backend, render Ready once, and present it. Each
`0` or `1` renders/presents one more frame and returns to the caller. Unsupported
input preserves the prior presentation. `q` and explicit cancellation revoke the
session before backend close, wipe the lease, then release it. Backend-open,
render, presentation and guard failures use the same cleanup path. Reentrant
start/input/cancellation is refused while a callback is active.

The C control interface in `include/nihos_app_session.h` is experimental OS
infrastructure, not a guest import or stable Rust SDK. It assumes one serialized
foreground caller and trusted ownership callbacks; it is not thread-safe or a
native pointer isolation boundary. Cancellation is synchronous between calls.
It cannot interrupt a stuck native FFI function or run destructors after forced
termination.

With `NIHOS_NATIVE_RUST_SESSION=1`, the normal device shell's `rust-app` command
uses this lifecycle through `rust_session.zig`. It allocates from the current
CPU0 task's reusable PSRAM heap, outside the console/service tail and scanout
buffer. The graphics adapter attaches only for a synchronous frame call and
detaches before presentation. The shared `app_presenter.zig` copies the 160x80
RGB565 frame into logical rectangle `(16,16)..(176,96)` in portrait scanout;
the existing display owner performs cache publication. No pointer into the
private frame becomes a DMA source.

The UI routes app input before storage/device command parsers, gives the app
exclusive foreground presentation, and restores the retained shell by invalidating
its renderer on quit or failure. Camera overlays, active/draining live capture
and pending snapshot presentation prevent app launch. Camera publication is
refused while the app holds presentation. Existing networking and storage still
receive their normal foreground service turns. Touch/keyboard device behavior
was not physically tested.

The option defaults off. The original isolated `RUST_DISPLAY` boot experiment
remains separate. The new session links only the graphics adapter, avoiding the
unused diagnostic fixture's 2 KiB buffer. Foreground-only lifecycle/copy/adapter
code uses a bounded Flash region; the image auditor checks its exact function
allowlist and rejects IRQ code or an out-of-profile span. The SRAM heap floor
remains 49,152 bytes. The ordinary device configuration still includes camera,
network and storage.

## Executable checks

`sh probes/rust-session/run-host.sh` uses the same Rust sample twice: native FFI
and WAMR 2.4.5 classic interpreter. Wasm comes from the root-signed trust journal
and Ed25519-signed package through the private-buffer admission ABI. The runtime
checks admitted graphics rights, matching instance, active owner and frame scope
before drawing or guest memory mapping. Each frame receives a 10,000-instruction
limit. Native and Wasm share the same Zig lifecycle, RGB565 adapter and rotated
display-copy implementation.

The host compares all 12,800 logical pixels against literal glyph/background
references, all 921,600 physical buffer pixels including the untouched area,
and presentation hashes across both backends for initial Ready and `0 -> 1 -> 0`.
It checks invalid input, `q`, cancellation, restart, reentrant control calls,
eleven startup fault cases and two failures after successful startup. Failure
cases include allocation/open/render/presentation refusal, end-guard corruption
and instruction-budget traps. Every acquired frame is wiped and released, and
the graphics adapter is detached. These are host buffer checks, not scanout.

`sh probes/rust-session/run-emulator.sh` builds the headless normal boot profile,
using the same native session backend with actual task-owned PSRAM allocation.
It receives at most one ROM UART byte per foreground turn, rather than spinning
in a blocking input loop. The unchanged image executes `0x10q`, no input and
early `q` cases. Each case checks expected status/counters, exact free-memory
recovery, and advancement of both hart timer counters after cleanup. This
fixture uses a headless presenter and does not execute the physical display
owner's cache/scanout path.

The normal device profile is independently built and audited with the option
enabled and disabled. The host SDK suite, Zig Debug/ReleaseSafe tests, static
analysis, Python regressions and the existing WAMR emulator/UART matrix are
also checked. The new CI steps are configured but remote CI has not been run.
The four regenerated keypad/font payloads are byte-identical; only their source
hash records change.

## Measured resources and retained evidence

On the 4 MiB PSRAM emulator profile, the requested frame lease is 32,768 bytes;
the current allocator charges 65,536 bytes. CPU0's reusable heap has 1,801,536
free bytes before launch and exactly the same amount after cleanup in all three
cases. The 25,600 pixel bytes and two 16-byte guards fit within the requested
lease. Requested size and charged capacity must not be treated as interchangeable.
The two hart timers advance by 7/7 ticks in the normal case, 53/53 with no input,
and 3/3 on early quit. These timings/capacities are emulator observations.

The linked device image reserves a 49,216-byte SRAM heap span with the session
enabled, versus 51,776 bytes with it disabled, under the same normal profile.
The enabled image is only 64 bytes above the 49,152-byte policy floor; future
resident growth must continue to pass that gate. These are static linker spans,
not measured free memory on a device. The private PSRAM allocation is additional.

Debug/ReleaseSafe, static analysis, all 491 Python regressions, the host SDK suite,
the normal-session emulator matrix and enabled/disabled device image audits pass.
The original WAMR emulator and its six UART negative cases also remain checks of
the separate boot fixture. Exact source/candidate/evidence hashes and logs are in
[the retained identity record](evidence/2026-10-31-rust-session-normal-owner/identity.json).

## Remaining gate

Wasm is not enabled in the normal RV32 UI. Its existing native fixture still
switches to a private 64 KiB stack before normal task execution. A real normal
backend must register that leased stack with the scheduler and interrupt-stack
validator, then return bounded frame results to the common session. The host
WAMR test does not qualify that execution path. WAMR alignment adoption remains
open before a device profile is permitted. Physical screen/input/stop tests,
production trust/counters and native persistent installation remain separate.

See the [finite landing checklist](../planning/rust-sdk-landing.md).
