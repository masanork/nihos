# Camera integration on the current main snapshot

Base: `d824feaa8acc66dc16810fc9fa95887f5efc642d`, the locally observed `origin/main` on 2026-10-29. This isolated worktree imports three self-contained modules from `/private/tmp/nihos-camera-service-contract` at its uncommitted working-tree state: the single-frame ownership model, the two-slot streaming ownership model, and the Tab5 sampled-preview conversion/overlay lifecycle. Their unit tests are attached to `zig build test`. These modules are host-tested models and rendering helpers, not a wired device service, hardware DMA implementation or proof of continuous video. The older worktree and its exact-candidate physical evidence remain separate and unchanged.

## Integration boundaries

- The current UI routes serial and keyboard input through `Session.input` once `session_active` is true; pre-session diagnostic actions use a different parser. An overlay must consume its dismissal at the appropriate input layer without also opening the shell, changing the selected launcher entry, or submitting a shell command. Touch has a separate event path and needs its own explicit behavior.
- The current UI's `drawSession()` and boot-splash/detail render paths have different invalidation and redraw conditions. Overlay dismissal or failed painting must force the correct previous view to repaint, including the active session, and retain the pending state until its presentation succeeds. Fatal entry must abandon the overlay before any fatal-screen redraw can report recovery.
- The runtime has evolved independently in `main.zig`, `board_devices.zig`, `task_resources.zig`, the native build scripts and display/scanout code. Transfer the board-specific ownership, DMA, cache and sensor code by review against the current owners and reservations; do not overwrite these files wholesale. In particular the old diagnostic's pinned capture is not evidence that buffers can be returned or reused.
- The normal launcher should not advertise a functional camera until the new exact candidate has a bounded start/stop service and passes coexistence and device tests. No device filesystem or procfs is required by these host models.

## Acceptance evidence before advertising the camera

1. Host tests cover session-active and pre-session routing, consumed dismissal, unchanged launcher/shell state, serial escape sequences, touch policy, repaint failure and fatal abandonment.
2. Native image audit and resource accounting show the frame, DMA lease, display ownership, cache boundaries and shared I2C owner remain valid on the current base. Diagnose one capture first; frame/lease remain pinned until a separately evidenced retirement protocol permits reuse.
3. Physical Tab5 testing identifies and freezes the exact image, takes exclusive serial and write ownership, captures input/preview evidence, restores and verifies modified flash spans, and separates software framebuffer readback from panel/scene confirmation. Test physical keyboard and touch if claimed.
4. Continuous video remains future work requiring bounded backpressure, coherent multi-buffer ownership, cancellation, FIFO/IRQ drain, sustained capture and performance evidence. The stream model by itself is not that implementation.

## Session input boundary prototype

`src/console/camera_input.zig` connects the real session model and input decoders to the overlay lifecycle in host tests. A decoded event dismisses a visible overlay without reaching the session; additional events are suppressed while repaint or recovery is pending, and fatal abandonment suppresses them as well. After a successful repaint, later events go to the session normally. Tests cover serial Escape and arrows, HID Escape/Enter, a partially typed shell command, and CRLF after dismissal. In particular, the router preserves the existing serial decoder state across dismissal: resetting it can turn the LF of CRLF into a command submission.

The session key path in `diagnostic_ui.zig` now uses this router. A session-only `showCameraPreview` helper paints a caller-owned stable sampled copy and writes back its display span. Dismissal, including a recognized touch view-button action, invalidates the session renderer; pending recovery or dismissal forces `drawSession`, and completion is recorded only after successful presentation. CPU0 fatal entry abandons the overlay before choosing a fatal branch. Keys received during repaint are deliberately dropped, not replayed.

No camera service or diagnostic command calls `showCameraPreview` on this base yet, and no native physical trial has exercised this path. The normal native build compiles and passes image audit; unused helper code may be eliminated and is not evidence of a functioning camera. Pre-session overlay is deliberately rejected. A synthetic session fixture and then real camera integration must verify launcher and shell restoration, partial input, serial and physical keyboard, touch, failures, display cache behavior, and fatal transitions on the exact candidate.

A [synthetic launcher and shell preview trial](../measurements/2026-10-29-camera-session-ui.md) now verifies CPU framebuffer readback, serial dismissal and preservation of an unfinished shell command on one physical candidate. It does not exercise a camera or qualify the panel, keyboard, touch, fault handling or DMA retirement on this base.

[Camera ID integration on this base](../measurements/2026-10-30-camera-id-main.md) now runs through the existing CPU0 I2C owner behind an explicit default-off fixture. One physical Tab5 run confirmed the sensor ID, OFF register readback, launcher startup, and display/CPU progress. Capture, buffer retirement and real-camera preview remain unintegrated on this base.

[Sensor mode preparation on this base](../measurements/2026-10-30-camera-mode-main.md) now confirms one physical 1280×720 geometry and stream-off register readback, followed by expander OFF readback. It does not start CSI or capture; actual image output and retirement remain future work.

[Sensor stream register diagnostic](../measurements/2026-10-30-camera-stream-main.md) now confirms stream-on, stream-off and expander OFF readbacks on one physical trial. CSI and DMA were not enabled, and no image output was verified.

[CSI receiver preflight](../measurements/2026-10-30-csi-preflight-main.md) now has a host register replay and one physical preparation/stop readback on the current base. Sensor streaming, CSI signals, ISP, DMA, cross-core RCC concurrency and frame capture remain unverified by that trial.

[Host pin and pre-DMA workspace integration](../measurements/2026-10-30-camera-pin-main-host.md) adds task-close-safe pinning alongside extent groups and the 921,600-byte diagnostic prepare/erase/release path. A physical trial could not start because the Tab5 serial device was absent; started-DMA retirement remains a separate unproven gate.

[Physical pre-DMA workspace trial](../measurements/2026-10-30-camera-memory-main.md) confirmed one allocate/cache-prepare/erase-writeback/release sequence while display and CPU counters progressed. It did not start DMA or independently read back every zeroed byte.

[Shared DMA domain admission](../measurements/2026-10-30-camera-domain-main.md) now allows the display owner and a camera channel lease to coexist; one physical trial acquired and released an unused camera lease while display/CPU counters advanced. A started channel is deliberately pinned; no transfer or safe retirement was demonstrated.

[SRAM-to-SRAM DMA diagnostic](../measurements/2026-10-30-camera-dma-sram-main.md) now confirms one 64-byte transfer on the camera channel while display/CPU counters advanced. The started lease stays pinned until reset; PSRAM DMA, CSI capture and safe reuse remain separate gates.

[PSRAM DMA diagnostic](../measurements/2026-10-30-camera-dma-psram-main.md) now confirms one 64-byte SRAM-to-pinned-PSRAM transfer on the camera channel. Frame and started channel remain pinned until reset; CSI capture, full-frame transfer and safe reuse remain unqualified.

[One-frame CSI DMA diagnostic](../measurements/2026-10-30-camera-first-frame-main.md) now reports one completed frame on the current base with the frame and DMA lease retained until reset. No image bytes were inspected; display of real camera content and safe reuse remain future gates.

[Real camera sampled preview](../measurements/2026-10-30-camera-real-preview-main.md) now reaches the current session framebuffer after two matching 80×45 sample passes; one physical run confirmed 57,600 CPU-visible RGB565 pixels and a separate run confirmed automated serial Escape returns to launcher. The panel and actual subject have not been optically confirmed, and DMA/frame reuse remains unsafe.

[Low-exposure comparison and recovery](../measurements/2026-10-30-camera-low-exposure-incident.md): two sample trials completed, then USB loss interrupted a low-exposure screen trial's post-capture verification and restoration. On reconnection, both backed-up spans were restored and full readback verified; the interrupted candidate's post-capture identity remains unverified.

[Low-exposure screen retry](../measurements/2026-10-30-camera-low-screen-retry.md) subsequently completed candidate verification, launcher dismissal and full flash restoration on a fresh physical run. The earlier interrupted run remains an incomplete separate attempt.

[Full-frame stability diagnostic](../measurements/2026-10-30-camera-frame-scan-main.md) compared two complete scans of one retained 921,600-byte frame on a physical candidate. The per-chunk values and full-frame SHA-256 matched. This does not establish safe reuse, scene correctness or streaming.

[Full-frame negative control](../measurements/2026-10-30-camera-frame-scan-control.md) intentionally changed one byte between scans of a normally completed frame. A separate physical candidate detected one changed chunk and a SHA-256 mismatch; the frame and channel remained pinned until reset.

[Interactive snapshot prototype](camera-prototype.md) exposes `camera` through the shell. The [retake trial](../measurements/2026-10-30-camera-retake.md) completed three new captures and shell returns using the same retained frame/channel, with three different sample hashes and zero framebuffer mismatches. The final candidate's observed capture-to-result times were 3.3 seconds initially and 2.3–2.4 seconds on retakes. Live preview, optical correctness, sustained restart and general resource release remain future work.

[Automatic preview prototype](../measurements/2026-10-30-camera-live.md) now exposes `camera-live`: five automatic updates, visible and initial-loading stops, a later manual snapshot and resumed shell operation passed on one physical candidate using a watchdog reset. A USB-reset trial stopped after three updates and its successor found receiver clocks already enabled; USB-reset/recovery remains unresolved. Sustained operation, optical correctness, video and general resource release remain future work.

[Reset recovery](../measurements/2026-10-30-camera-reset-recovery.md) adds a pre-allocation check and a full-reset policy for CSI residue after USB reset. The common recovery function was physically exercised from a prepared-CSI fixture, followed by five live updates, both stop cases, a manual snapshot and shell use. Natural triggering of the automatic boot branch on that exact candidate and the earlier runtime failure's cause remain unqualified.
