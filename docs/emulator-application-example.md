# First application boundary: an executable example

The emulator input fixture includes a small application in [`canvas_demo_app.zig`](../src/platform/native/canvas_demo_app.zig). It owns a button state, not a display, timer, input controller or frame allocation. The host owns the frame and the input stream; it calls `onEvent` with a logical pointer event and calls `render` with a borrowed frame when the visible state changes. The example draws one indicator through the shared Canvas. The fixture paints the surrounding diagnostic pattern.

```zig
var app = App{};
if (app.onEvent(event)) {
    if (!app.render(frame)) return error.InvalidFrame;
}
```

`onEvent` accepts `pointer.Event`, whose coordinates are in the existing landscape logical coordinate system. `render` currently accepts the fixture's 720 × 1280 portrait RGB565LE byte slice and draws only the indicator. The host must serialize access, keep the slice valid for the call and own any publication, cache synchronization and DMA lifetime. The app does not retain the slice. Input samples are converted to events by the host's existing `pointer.Stream`; the example's `pointer.Button` decides whether a release completes a click. The coordinate transform and partial repaint are specific to this fixture.

The same example is host-tested and runs in the ESP-EMU native image with `sh tools/nihos-dev.sh canvas-live` or the deterministic `canvas-live-check`. The test exercises state changes, a cancelled gesture, and the RGB565 output; the emulator check exercises the debugger input adapter, real RV32 event processing, frame readback, multi-contact and drag cancellation. See [the development simulator guide](development-simulator.md).

This is an example and an executable boundary probe, not a stable application ABI, loader, task isolation, production display service or present contract. Text layout, dynamic sizing, editor/reader document state and persistence remain separate. Future native and Wasm applications need explicit ownership and cleanup, checked memory/handle lifetimes, errors, input routing and a display publication contract. A Wasm linear-memory pointer is never a native pointer, and emulation does not prove physical cache, DMA, touch or timing behavior.

## Bounded edit and redraw scenario

The separate `console-rv32` fixture now applies synthetic insertion, cursor movement and deletion to one ASCII row after scrolling. Each content mutation uses the console renderer's incremental path. The host test compares each incremental frame against a full repaint; RV32 reads the final frame and compares every pixel with both the host fixture and an independent reference. Run `sh tools/nihos-dev.sh console-rv32 --font basic-light`, `--font jetbrains`, or `--font source-code`.

This is a bounded rendering experiment, not an XY editor or a keyboard integration: the actions are predetermined, the cursor is not drawn, and there is no Unicode editing, file I/O, input routing or persistence. It provides a reproducible exercise of edit-driven partial redraw to build on.

## Using this for rendering work

Keep a fixed input trace and compare output frames and errors before and after a Canvas change. The emulator executes the target code and can expose target-only correctness issues; its elapsed time is a developer-feedback measurement, not a prediction of P4 PSRAM or scanout performance. The current fixture has no general frame-by-frame differential test or native application loader. Add representative editor scrolling, text layout and indexed-frame traces before claiming coverage of XY, Aozora or Quake. Measure physical rendering, cache writeback and display publication separately when Tab5 is available.

### Record and compare a deterministic RV32 trace

```sh
sh tools/nihos-dev.sh canvas-trace-check
python3 tools/emulator_trace.py record probes/emulator/canvas-trace.json build/my-reference.json
# Change the implementation, then record to a new path:
python3 tools/emulator_trace.py record probes/emulator/canvas-trace.json build/my-candidate.json
python3 tools/emulator_trace.py compare build/my-reference.json build/my-candidate.json
```

Each run starts a new emulator fixture. The versioned trace contains synthetic portrait touch samples and virtual microsecond timestamps. The report retains a checksum of the trace, a source fingerprint, app/ELF/Flash hashes, and for the initial frame and every sample the complete RGB565 framebuffer SHA-256 plus input/event/click counters. Comparison rejects incompatible traces, incomplete reports and any differing frame or counter. The fixed sample covers a valid click, multi-contact cancellation and drag cancellation. The output path must be new, so a failed run cannot accidentally pass using an earlier receipt. Never put real PIN or credential data in these traces.

Matching two runs establishes determinism for this fixture, not independent proof that the expected image is correct. Pair comparisons with known-pixel/negative-control tests. The source fingerprint is local change detection, not a signed build attestation. The emulator still stops at each event and has no panel, DMA or physical timing model.


### Independent RV32 workload comparisons

`sh tools/nihos-dev.sh canvas-workloads` executes two deterministic 320 × 200 RGB565 workloads in the target emulator and reads their frames from its PSRAM. A separate Python reference computes each expected pixel without calling Canvas; every byte is compared. The first draws synthetic editor-like rows and a selection, then scrolls with `copyRect` and clears the exposed area. The second expands a synthetic 160 × 100 indexed frame with a 256-color RGB565 palette. Reports and PNGs are written under `build/native-emulator/canvas-workloads/`.

These are graphics primitives, not the XY editor, text layout, a Quake port, a live display or a physical performance test. Retain the same input and compare output before and after an optimization; separately measure target timing, PSRAM, cache writeback and scanout on hardware. GDB is required, and the debug stub is active during capture; run on a trusted host/network.
