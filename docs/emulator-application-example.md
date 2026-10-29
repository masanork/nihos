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
