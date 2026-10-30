# RV32 deterministic pointer/frame replay

On ESP-EMU 0.50.0 on Darwin arm64, source commit `3c691bbb74a0189e432931e312946dacd85da586` recorded the checked-in eight-sample trace twice from independent emulator starts. Each report contains nine frames: one initial frame and one after each sample. All RGB565 SHA-256 values and input, event, click and event-kind counters matched. A negative control changed the fourth frame's digest in a copy of the reference; comparison rejected it as `frame 3 differs: pixel_sha256`. Python's trace tests also reject changed event state, incomplete reports, changed input and invalid samples.

After the emulator-only mailbox export fix, a new RV32 run at source commit `8f5208b30db57f406df877fcbb40123f7f9b7868` also matched all nine recorded frames and states against the original reference.

This establishes reproducibility of this fixed Canvas indicator fixture under the tested emulator. It is not an independent pixel oracle, editor or reader coverage, a physical-display test or a device timing result. The reports identify the image, ELF, merged Flash and source fingerprint for each recording.

[Reference](evidence/2026-10-29-emulator-trace/reference.json) · [Replay](evidence/2026-10-29-emulator-trace/replay.json) · [Mailbox-fix candidate](evidence/2026-10-29-emulator-trace/fixed-candidate.json)
