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
- Window deactivation pauses animation and clears held keys. Resume explicitly.
- Cmd-Q or closing the window exits. Paused animation requests no further frames.

The fixed-step model is independent of GPUI, supplied clocks and input devices.
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
It does not create a GPUI window. The RV32 command links the pure clock/Canvas
probe with the integer soft-float ABI; it does not execute a device image.
Actual GPUI window/keyboard checks are recorded in the
[measurement report](../../docs/measurements/2026-10-31-xy-gpui-animation.md).

This is an additional prototype, not a replacement for the existing Cocoa
workspace's SQLite/source-editor lifecycle. Save/load, IME composition,
selection/clipboard, Scheme-driven animation, Wasm app hosting and native
Tab5 presentation of the animation remain unconnected. It does not implement
R7RS. See the [runtime roadmap](../../docs/planning/xy-animation-runtime.md).

Dependencies are pinned in Cargo.lock. GPUI is Apache-2.0; image is MIT/Apache-2.0.
The shared font assets retain their existing CC0/OFL provenance in src/xy/fonts
and src/graphics/ascii. No source was copied from MeOS or ibisOffice.
