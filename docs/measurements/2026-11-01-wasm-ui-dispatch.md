# Wasm path in the normal UI dispatcher

The diagnostic UI now contains an opt-in Wasm branch using its foreground
ownership controller and the scheduled WAMR worker. It reserves display
ownership during open, cancellation and execution; routes application keys
before shell or camera commands; rejects camera preview while reserved; and
marks the shell dirty on stop or failure. Internal calls bridge the display
owner module to the same single registered worker.

The headless test profile gives the UI a private shell model and a pixel oracle
instead of its hardware framebuffer. The RV32 fixture executes the actual
`diagnostic_ui.sessionKey` for synthetic launcher Escape, `rust-app`, Enter
and `q`. A second launch executes `0 → 1 → 0 → Esc` through that dispatcher,
checks all 12,800 logical pixels at the substitute presenter, verifies the dirty
flag and repaint request after cancellation and stop, and checks exact heap
recovery. Synthetic camera-live state checks that input stops/drains it rather
than starting Wasm, and that keys while opening do not start the camera. This
does not operate camera DMA.

The existing six normal and failure cases, including worker open failure and
missing close acknowledgement, also run. Input is injected through the emulator
fixture; this is not an actual USB serial or keyboard session. Both harts'
timers advance. Debug/ReleaseSafe unit tests, static analysis and 501 Python
regressions pass; native-session device images with the option on and off pass
static image audits. The enabled native image reserves 49,344 bytes of SRAM
heap, 192 bytes above the unchanged 49,152-byte floor.

Current build guards allow the Wasm branch only with the emulator headless test
profile. They do not permit an interactive Wasm/display device image. The
hardware-backed UI, actual camera/network progress, scanout/cache behavior,
WAMR alignment decision, remote CI and physical Tab5 qualification remain open.
First frame and active-session close are synchronous.

The [identity record](evidence/2026-11-01-wasm-ui-dispatch/identity.json)
contains exact source, image and log hashes. Shell and presenter substitution
are test-only and do not establish live display output.
