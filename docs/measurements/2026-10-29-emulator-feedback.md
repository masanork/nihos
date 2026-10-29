# Emulator feedback loop on the development host

On one Darwin arm64 host, the interactive RV32 Canvas fixture was measured using `python3 tools/benchmark-canvas-live.py --port PORT`: five press/release pairs over loopback HTTP, alternating contacts on the same 720 × 1280 image. The old server used source `c2a0483` and the new server used the conversion change at `36add06`. Both executed the same RV32 fixture. The two cases ran sequentially on separate live instances; this is a local exploratory measurement, not a controlled cross-device benchmark.

| Host event-to-response | Old median | New median |
| --- | ---: | ---: |
| All ten individual events | 1018.405 ms | 630.078 ms |

The host measurement includes HTTP, GDB transport, guest continuation, full framebuffer read, conversion and response. It excludes time for the browser to decode and display the image. The new server keeps a PNG only when the full RGB565 SHA-256 is unchanged and uses a lookup table for RGB565 expansion otherwise. A separate five-run host conversion measurement gave a 45.7 ms median after the change; the old implementation took 399.7 ms in a four-run measurement. These are warm-process timings for a cached frame. The new PNG matched the previous converter byte-for-byte for an actual emulator frame; all 65,536 possible RGB565 values were independently checked against the original rounding.

This is ESP-EMU and host tooling latency, not Tab5 timing or a frame-rate claim. One host, one static fixture, small samples and sequential runs do not establish behavior under other load. The full GDB framebuffer read remains in every event.

[Before samples](evidence/2026-10-29-emulator-feedback/before.json) · [After samples](evidence/2026-10-29-emulator-feedback/after.json)
