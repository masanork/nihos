# nihos emulator window (experimental)

The GPUI app opens a screen-focused emulator window with Portrait/Landscape,
Pause/Resume, Power and Reset controls, plus New session (Cmd-N). The screen scales to the window.
Pause stops guest execution while retaining RAM and the last frame; key input is
ignored while paused. Reset clears the guest while preserving the paused state.
Control-letter keys are sent to the guest as terminal control characters; for
example, MeOS uses Ctrl-S to save and Ctrl-Q to leave its editor. macOS Command
shortcuts such as Cmd-Q and Cmd-N remain application shortcuts.
Cmd-V pastes text into the guest (Ctrl-Shift-V on Linux), up to 4096 UTF-8 bytes
per paste. Line endings become Enter; other control characters are rejected.
Each new session is a separate process with its own CPU, RAM, input, display,
and power/reset state; the title shows its process ID. It inherits the current
working directory and loads the same firmware. Closing one session leaves the
others running. No document or flash persistence is implemented. Each active
session consumes CPU, so concurrent sessions can run more slowly; pause a session
to stop its CPU work without discarding its state. Portrait rotates the
host display counterclockwise; it does not change the guest's display orientation or
input coordinates. Mouse press, drag and release on the screen simulate one
ST7123 touch contact; coordinates follow the displayed rotation. The Tab5
keyboard I2C bus is modeled as disconnected, so firmware can detect its
absence. The host rotation control remains manual. Input is
released on focus loss, rotation, pause, power off, or reset. Power off stops CPU execution and blanks the screen; power on
and Reset reload the ELF into a new emulated machine. This model does not yet
preserve flash or other storage across power cycles.
If guest execution stops on an emulator error, the last frame remains visible
with the reason underneath; Reset reloads the firmware and resumes execution.
When manually paused, Reset instead keeps the new machine paused. If firmware
could not be loaded at startup, correct the file and use Reset or Power on to
retry without restarting the app. An explicitly configured firmware path remains
authoritative even when the file is missing.

The RV32 CPU and peripheral model is experimental, not a complete Tab5 emulator.
The GPIO 31/32 bit-banged bus has separate register-file fixtures at expander
addresses `0x43` and `0x44`; the latter can be used by board power setup. These
fixtures do not model electrical pin effects or the expanders' complete reset
and GPIO semantics, and their presence does not establish MeOS compatibility.
Firmware is selected by `NIHOS_EMULATOR_ELF` if explicitly set, otherwise
from the app bundle, then from `build/xy-emulator-firmware/nihos-native.elf`
relative to the current directory. The packaging script bundles the fixture when
present, so the resulting app can be started from Finder. Missing or invalid firmware is shown in the window. A candidate xy
firmware has booted to its home and RAM document; ASCII navigation and editing
have been demonstrated. Single-contact touch is modeled; IME, persistence,
multi-touch, full peripherals and physical
Tab5 equivalence remain unqualified. Build and launch from the repository root.

The MeOS probes in `tools/run-meos-emulator-probe.sh` are test-only direct-app
experiments using an explicitly supplied MeOS image, ROM and synthetic devices.
The default GPUI build does not select MeOS. The fixtures do not implement a
real bootloader, persistent flash, or the ST7123 LCD driver. The alternate ST7121 probe changes
only the synthetic touch identity and does not qualify a physical panel.
The interrupt model currently defers all other hardware interrupts until the
active handler executes `mret`; CLIC priority and nesting are not modeled.

An opt-in development build can launch the pinned MeOS fixture in the GPUI
window. From the repository root, run:

```sh
tools/run-meos-gpui.sh
```

The command finds the repository's MeOS reference or a sibling
`MeOS-shi3z-latest` checkout and the standard ESP-IDF ROM. Run
`tools/run-meos-gpui.sh --help` to supply different paths. The image and ROM
must match the exact hashes used by the probes.

The window identifies the session as experimental and volatile. Reset creates
fresh fixture flash; no guest data is retained. This uses the synthetic ST7121,
ROM, clock and USB fixtures, not a real bootloader or ST7123 panel. It supports
only the identified image and ROM, not arbitrary MeOS builds.

## Boot investigation

Build the fixture and app with ESP-IDF 5.4.4 and the pinned Zig toolchain:
no device is accessed or flashed. The workflow builds the same fixture and
runs the splash, touch, edit and dual-session tests on each relevant pull request:

```sh
sh tools/build-xy-emulator-fixture.sh
sh tools/build-xy-gpui.sh
open build/xy-gpui/xy-gpui.app
NIHOS_EMU_TEST_ELF="$PWD/build/xy-emulator-firmware/nihos-native.elf" \
  cargo test --locked --manifest-path apps/xy-gpui/Cargo.toml firmware_reaches_splash -- --ignored --nocapture
```

The splash integration gate reaches `NIHOS_NATIVE_UI_START` and checks that
the guest has completed at least two DMA frames and that the captured scanout
contains multiple colors. The actual GPUI window has shown the splash and its
progress on macOS. The model accepts a single valid 720x1280 RGB565 DW-GDMA
descriptor targeting the DSI FIFO, snapshots its source, and supplies a delayed
completion interrupt. Linked descriptors, other formats and peripherals are not
implemented. DMA/DSI timing, FIFO depth and PHY lock are functional approximations,
not hardware timing or qualification.

On Linux, install Rust 1.98.1 and the X11, Wayland, Vulkan and font development
packages. For Ubuntu, install them with:

```sh
sudo apt install build-essential clang cmake pkg-config libfontconfig1-dev \
  libfreetype6-dev libx11-dev libx11-xcb-dev libxcb1-dev libxcb-render0-dev \
  libxcb-shape0-dev libxcb-xfixes0-dev libxkbcommon-dev libxkbcommon-x11-dev \
  libwayland-dev libvulkan-dev libssl-dev libasound2-dev libudev-dev
sh tools/build-xy-emulator-fixture.sh
sh tools/build-xy-gpui.sh
./build/xy-gpui/xy-gpui
```

The window requires an X11 or Wayland session and a working Vulkan driver.
The build places the firmware and optional dictionary in `build/xy-gpui/Resources`
beside the executable, so it can be started from another working directory.
`NIHOS_EMULATOR_ELF` still overrides the packaged firmware.

The optional `two_sessions_boot_edit_and_reset_independently` integration test
boots two guests concurrently, edits different documents, and verifies that a
reset of one leaves the other's frame unchanged; it also checks that a paused
machine does not execute instructions. In macOS window checks, two independent
processes displayed `aa` and `bb` in separate documents, and resetting the
second left the first unchanged. For the automation surface only, identical app
binaries were placed in test bundles with distinct identifiers so the windows
could be selected independently. Cmd-N was separately confirmed to launch a
second process from the ordinary app. Pausing one session retained `bb`, ignored
input while paused, and reported 0.3% CPU in one `ps` sample while the other
running session reported 102.6%; this is a snapshot, not a benchmark.

The optional `firmware_reaches_xy_ready` integration test reaches the xy home,
sends `n` to open the document, and sends `X`, asserting that the guest consumes
both bytes and that each action changes the DMA frame. On macOS, the window also
showed the home and `abc` entered in the RAM document. Timer, IPI and CLIC models
are bounded approximations, and the test does not qualify arbitrary input or
other peripherals. Run it explicitly with the same environment variable above
and replace the test filter with `firmware_reaches_xy_ready`.

For the same candidate and 152 million CPU0 instructions on this host, a debug
interpreter took 16.4 seconds to `XY_READY`; compiling just this crate with
`opt-level=2` took 4.2 seconds. These are individual headless measurements, not
an emulated-time or device-speed comparison. The dev profile now uses that
crate-level optimization. CPU execution and frame conversion run on a dedicated worker thread; the UI
receives the latest frame and sends input and control commands asynchronously.

Unsupported major opcodes, compressed opcodes and unmapped ROM calls stop the
emulator with an address. This is not a complete ISA validation: some instruction
subfields, CSRs and MMIO are still partial, and this must not be treated as a
security boundary. The loader rejects malformed, out-of-range or overlapping ELF
LOAD ranges rather than corrupting the image. The local MeOS Tab5 ELF uses overlapping virtual flash ranges and needs
an ESP-IDF bootloader/flash MMU model; it is not bootable with this loader.
A dynamic MeOS scanout and its descriptor formats also require validation.
The original timing investigation used ELF SHA-256
`6ad80119ae99d786456adcfbe32f2c9e6a201c92eaf7a48a2303bad1025e29f0`;
the later main-based local fixture had SHA-256
`aa56db600dc70de93c7ae1025bc679aa6402d6d9db341a5f74ec17bca7b8411d`.
ELF hashes may differ by build path/toolchain; CI builds and tests its own image.

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
./build/xy-gpui/xy-gpui.app/Contents/MacOS/xy-gpui
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
