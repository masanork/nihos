# xy GPUI shared graphics prototype

This is a real GPUI 0.2.2 window with two panes: an editable RAM xy buffer and
an animated plot. The window, focus, buttons and event delivery belong to GPUI.
All text (including controls), graph geometry, font resolution and rasterization
use the shared Zig Canvas/Surface/TrueType pipeline. GPUI receives completed
BGRA images expanded from canonical RGB565; it never shapes the content text.
There is no SDL dependency or application-specific Cocoa source in this host.
GPUI uses its own native macOS/Metal platform implementation.

```sh
sh tools/build-xy-gpui.sh
open build/xy-gpui/xy-gpui.app
```

Validated with Rust 1.98.1 and the repository-pinned Zig compiler on macOS.
The build uses Cargo.lock and exact GPUI 0.2.2. Xcode's Metal compiler is needed;
if `xcrun -f metal` reports a missing toolchain, install Apple's component with
`xcodebuild -downloadComponent MetalToolchain`.

- Click a pane or press Tab to choose Editor or Graph.
- Editor: committed key text, Left/Right, Backspace, Enter, Ctrl-Z / Cmd-Z undo.
- Graph: Space pause/resume, Left/Right speed, R reset; buttons work in either pane.
- Run / Ctrl-Enter / F5 evaluates the RAM buffer as Scheme in the editor's VM.
  The initial buffer is an editable example that animates the plot amplitude.
- Stop / Ctrl-C pauses and removes the Scheme callback. Pause retains it.
  A Scheme error rolls back that evaluation, removes the callback and pauses;
  edit/Undo, then Run again to recover. Error text appears in the editor status.
- Window deactivation pauses animation and clears held keys. Resume explicitly.
- Cmd-Q or closing the window exits. Paused animation requests no further frames.

The fixed-step model is independent of GPUI, supplied clocks and input devices.
The host now uses the native v1 [event/frame contract](../../include/nihos_app.h)
for version/limit discovery, open, input, snapshots and frame delivery. The
previous unversioned animation exports have been removed. Editor insertion and
label rendering remain prototype helpers, outside the common app contract.
It bounds catch-up to four steps and drops excess elapsed time. Speed changes
preserve phase. Rendering reuses cached axes/labels, and old GPUI atlas images
are retired after the current frame instead of accumulating frame history.
The panes use 512x360 logical points and up to 2x backing resolution. Dynamic
reconfiguration when moving between monitors and arbitrary pane resizing are
follow-ups.

## Verification

```sh
sh tools/check-xy-animation.sh
build/xy-gpui/xy-gpui.app/Contents/MacOS/xy-gpui \
  --snapshot-dir build/xy-gpui/snapshots
cargo clippy --locked --manifest-path apps/xy-gpui/Cargo.toml --no-deps -- -D warnings
```

The snapshot check compares all 737,280 pixels of a 1024x720 RGB565/BGRA frame,
checks motion, paused pixels, resume without catch-up, held input/focus loss,
editor undo pixel restoration, label visibility and invalid buffer rejection.
It also checks version/size/reserved-field rejection without state/output writes,
all 32 key slots, terminal/idempotent cancellation and fresh reopen, both panes
in both formats with odd row padding, and caller-owned frame lifetime. Native
C, Rust and Zig record layouts are checked; the Zig layouts also compile for
RV32. See [the API report](../../docs/measurements/2026-10-31-xy-app-protocol.md).
It does not create a GPUI window. The RV32 command links the pure clock/Canvas
and actual Scheme callback probes with the integer soft-float ABI; it does not
execute a device image. Callback tests cover 600 updates across request GC,
coalesced updates, document/definition/plot rollback, bounded evaluation errors,
stop/cancel and reopen. See [the Scheme report](../../docs/measurements/2026-10-31-xy-scheme-animation.md).
Actual GPUI window/keyboard checks are recorded in the
[measurement report](../../docs/measurements/2026-10-31-xy-gpui-animation.md).

This is an additional prototype, not a replacement for the existing Cocoa
workspace's SQLite/source-editor lifecycle. Save/load, IME composition,
selection/clipboard, Wasm app hosting and native
Tab5 presentation of the animation remain unconnected. It does not implement
R7RS. See the [runtime roadmap](../../docs/planning/xy-animation-runtime.md).

The application extensions are `app/on-frame!`, `app/pause!`, `app/resume!`,
`app/stop!`, `app/speed!`, `app/ticks`, `plot/set!`, `plot/get`, `plot/sine`.
They are enabled by the GPUI app bridge, not by ordinary Cocoa/Tab5 editor VMs.
This is not an R7RS `define-library` / `import` implementation. A callback takes
one integer tick argument (modulo 2^31) and runs once per accepted event that
changes ticks while running, including coalesced catch-up and reset. Its return
value is ignored. Rendering never evaluates Scheme. Plot parameters are
`#:amplitude` (0..100 percent of half-height), `#:phase` (0..255), `#:color1` and
`#:color2` (RGB24). `plot/sine` takes integer phase (one cycle = 256) and amplitude
0..100, returning a signed integer. It is a fixed-point helper, not Scheme's
standard real-valued `sin`.

Frame evaluation permits 256 evaluator steps, recursion depth <24 and reserves
64 of the 256 cells for recovery requests. Ordinary evaluation keeps its 1024
step limit. These are work/storage bounds, not a measured deadline. There is no
suspended continuation: Ctrl-C is handled between synchronous callbacks, and an
over-budget callback aborts and rolls back. No foreign pointer or UI closure is
stored in the VM; the Scheme closure and environment are explicit GC roots.

Dependencies are pinned in Cargo.lock. GPUI is Apache-2.0; image is MIT/Apache-2.0.
The shared font assets retain their existing CC0/OFL provenance in src/xy/fonts
and src/graphics/ascii. No source was copied from MeOS or ibisOffice.
