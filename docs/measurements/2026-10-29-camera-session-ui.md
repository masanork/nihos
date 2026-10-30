# Synthetic preview in launcher and shell (2026-10-29)

Base `d824feaa8acc66dc16810fc9fa95887f5efc642d` plus this uncommitted camera-integration worktree. A diagnostic-only `NIHOS_NATIVE_CAMERA_UI_FIXTURE=1` build, separate from the default build, intercepts Ctrl-L in a ready session to show a synthetic 80×45 grayscale pattern. It does not use a camera. The preview paints a 320×180 RGB565 rectangle, writes back and invalidates its display span, and compares all pixels from the CPU-visible framebuffer. The native UI consumes the dismissal event and redraws the previous session after success.

One Tab5 ESP32-P4 rev 1.3 trial, MAC `e8:f6:0a:e2:e8:9c`; application SHA-256 `056b777bec330e8718a7c0e16e537792cddf471fd0cbc9673a84902d519b1c29`, ELF SHA-256 `e3b34ad0e68529bea9f2431334bdbd64943defe7132a3ab718f41060f689b673`. [Receipt and image audit](evidence/2026-10-29-camera-session-ui/).

1. In launcher view, synthetic preview reported zero mismatches for the 57,600 pixels. Serial Escape dismissed it; successful session repaint retained launcher view and selection 0.
2. A later Escape opened the shell. With `exit` typed but not submitted, a second synthetic preview also reported zero mismatches. Serial Escape dismissed it, and the repaint record retained shell view and four input bytes. Sending Enter then executed `exit` and returned to the launcher.

The records are CPU/framebuffer and software repaint evidence. The trial did not compare what the display DMA fetched or visually inspect the panel, use a real camera, inject failure, or test physical keyboard/touch. Suppressed keys during repaint are dropped. The manual fixture transaction script at `/private/tmp/nihos-camera-ui-fixture-run.py` reused the prior worktree's flash transaction/exclusion helpers; it is not a general packaged qualification tool. Both candidate loader and app were verified before and after capture. The original erase spans (24,576 and 151,552 bytes) were restored and fully read back, then a hard reset was issued; restored-system boot was not captured. Logs remain private.

Normal and fixture native builds passed image audit. Host Debug tests passed, including serial/HID routing and partial input. This does not qualify continuous capture, DMA retirement, camera integration on this base, or physical input/optical appearance.
