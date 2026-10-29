# nihos development simulator

Start the interactive normal UI in a browser:

```sh
sh tools/nihos-dev.sh ui
# Open http://127.0.0.1:8711/?app=normal
```

Use `sh tools/nihos-dev.sh card` for synthetic card workflows, or add `--port 8712` to either command. `sh tools/nihos-dev.sh check` runs the reproducible headless scenarios for both interfaces. See [the simulator guide](card-ui-simulator.md) for touch controllers, replay, fault injection, frame ownership and the limitations of each model. Python 3 and pinned Zig are sufficient for these host modes. No card, credentials or device transport is used.

Run the Canvas fixture as actual RV32 instructions under the pinned ESP-EMU:

```sh
sh tools/nihos-dev.sh canvas-rv32
```

`sh tools/nihos-dev.sh console-rv32` additionally runs a deterministic basic-face
console fixture on RV32, including a fixed header, scroll, exposed-band repaint
and view control. Pass `--font jetbrains` or `--font source-code` to exercise the
large-font decoder and incremental repaint; those faces do not use the basic
face's scroll-copy path. The command reads the full frame from emulated PSRAM and
compares it with both the same fixture on the host and an independent per-pixel
reference of the expected content. Reports and PNGs are under
`build/native-emulator/console-workload/<font>/`. This is not a full normal
application, panel/DMA model or physical timing test.

To capture the fixture's actual emulated PSRAM as a PNG:

```sh
sh tools/nihos-dev.sh canvas-snapshot
# Open build/native-emulator/canvas-snapshot/frame.png
```

This starts ESP-EMU halted under the ESP RISC-V GDB, breaks after the RV32 painter has completed, copies the RGB565LE framebuffer from emulated PSRAM, checks its length and FNV-1a, and converts those bytes to PNG. The receipt records hashes for the raw frame, PNG, app, ELF, Flash image, log, emulator and debugger. The command requires `riscv32-esp-elf-gdb` (set `NIHOS_GDB` if it is not on PATH or in the Espressif tools directory). It is a static frame and does not provide live input or panel/DMA emulation. The GDB stub is active during capture; run on a trusted host/network.

This command builds an emulator-profile image using ESP-IDF 5.4.4 and Zig, runs it with 32 MiB emulated PSRAM, and checks the audited application/ELF, merged Flash image, native SMP/heap qualification, Canvas framebuffer checksum, and a 16-byte guard after the frame. The result and exact image, log and audit live in `build/native-emulator/canvas-offscreen/`. The Canvas fixture reserves the same 2 MiB region as the display owner but does not initialize the Tab5 panel or DMA. The qualification command outputs a checksum; the separate snapshot command exports the actual framebuffer. The fixture flag is rejected for physical builds and is not the application-facing display API.

| Mode | What runs | What it can establish |
|---|---|---|
| `ui`, `card`, `check` | Host builds of production UI components with synthetic input and modeled display handoff | Interactive layout and input behavior; deterministic host regressions |
| `canvas-rv32` | Native RV32 firmware under ESP-EMU, with offscreen Canvas in emulated PSRAM | Target-instruction execution and memory/content checks in the emulator |
| Physical Tab5 | Device firmware, panel and peripherals | Hardware behavior under the measured conditions |

The interactive simulator currently has separate normal/card backends, and it is not running the full native kernel. ESP-EMU has a limited interactive Canvas fixture, but the normal native application has no integrated panel window or touch interaction in this workflow. Do not infer physical colors, cache/DMA behavior, timing, or device reliability from either simulator.

To improve the development loop, the next milestones are a shared display/input boundary used by applications and simulator backends; a streaming emulator framebuffer with checked frame identity; deterministic touch/keyboard event injection and replay into the native application; and fast one-command workflows for editor and reader scenarios. An export must read the actual emulated framebuffer, and tests must distinguish it from host-rendered previews. Keep real hardware checks for panel, DMA, timing and input-controller behavior.

## Interactive RV32 fixture

```sh
sh tools/nihos-dev.sh canvas-live
# Open http://127.0.0.1:8713/
sh tools/nihos-dev.sh canvas-live-check
```

The live fixture uses the same RV32 Canvas pattern and production `pointer.Stream` / `pointer.Button` logic. Press and release the top strip to toggle it. Each browser sample is written to a debugger mailbox while the emulated CPU is stopped at a frame rendezvous; the guest processes it, redraws if needed, and the host reads the resulting PSRAM frame. The input timestamp is recorded at the browser event, so debugger transfer latency does not become a long press. A single session shares one fixture; refresh retrieves its last simulated timestamp. Samples, pointer events, clicks and the RGB565 frame hash are shown. The deterministic check includes normal press/release, multi-contact cancellation and drag cancellation.

This is a deliberately narrow emulator fixture, not the normal OS application, a public host ABI, a real touch controller, or a live MIPI/DMA model. Each interaction halts the CPU and transfers an entire frame via GDB; it is not suitable for measuring interactive latency or frame rate. The GDB stub is active while the server runs; use a trusted host/network. Stop with Ctrl-C. In a failure, check `build/native-emulator/canvas-live/` logs.

To measure the local event-to-response loop against a running fixture, use `python3 tools/benchmark-canvas-live.py --port 8713`. This sends synthetic press/release pairs and changes the fixture state. The result is host tooling latency, not a Tab5 performance measurement. A single-host example and its conditions are recorded in [the feedback-loop measurement](measurements/2026-10-29-emulator-feedback.md).

The [executable application example](emulator-application-example.md) shows the current borrowed-frame and event boundary used by this fixture.
