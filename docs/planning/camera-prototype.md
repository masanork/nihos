# Camera snapshot prototype

Build the normal interactive image from this integration worktree:

```sh
sh tools/build-native.sh device
```

The default image includes camera with network and normal storage, and omits
detailed camera diagnostics. Its [normal-profile trial](../measurements/2026-10-30-camera-normal-profile.md)
records the latest-main integration, resource placement and physical limits.
For the earlier standalone diagnostic profile, explicitly use
`NIHOS_NATIVE_CAMERA_ID=1 NIHOS_NATIVE_NETWORK=0 NIHOS_NATIVE_NORMAL_STORAGE=0`.

After installing the resulting candidate, press Escape to enter the shell, then type `camera` and Enter. A request captures one frame and displays an 80×45 grayscale sample enlarged to 320×180. Press a key to close it and return to the shell. Type `camera` again to take another picture. `help` lists the command. Builds without camera support report that it is unavailable.

Use `camera-live` to update the picture automatically while it remains open. Press a key to stop. A capture already in progress finishes without being displayed; camera requests become available after that drain. This is a slow preview, updating on the order of a few seconds. The [physical workflow](../measurements/2026-10-30-camera-live.md) verified five automatic updates, stopping while visible and during initial loading, and subsequent snapshot/shell use. A [reset-recovery policy](../measurements/2026-10-30-camera-reset-recovery.md) now checks for retained CSI at boot and requests a full reset when needed after USB reset. Its shared reset function passed a prepared-CSI fixture and subsequent live workflow; naturally triggering the automatic boot branch on that final candidate remains unobserved.

This is a usability prototype. The existing frame and started channel remain retained until reset. Three repeated capture/display cycles succeeded in the [retake trial](../measurements/2026-10-30-camera-retake.md), and automatic updating is now implemented. Next work is reset/recovery reliability and faster, clearer preview images. Scene identity, panel appearance, image quality and sustained repeated DMA use need direct testing as the prototype develops.

The camera-enabled native image passes the SRAM floor and image audit. The command is exposed through the normal session registry and help. Cache preparation batches at most 16 KiB per foreground poll. Ordinary `camera` requests suppress raw sampled-pixel serial logs; explicit diagnostic commands retain them.

The initial snapshot-only implementation was physically tested on 2026-10-30 on Tab5 ESP32-P4 rev 1.3 (MAC `e8:f6:0a:e2:e8:9c`): it entered the shell with serial Escape, typed `camera`, captured and rendered a snapshot with 57,600 matching CPU framebuffer pixels, and dismissed it with serial Escape back to shell view 1. App SHA-256 `447f81ed65ac49a40813b3b5a526073ea5b63a89ae4f074cc3521f691629e2d9`; ELF SHA-256 `276a6b5cb19e125c09fd798b49f82ac4aaa218c7056e24acfe112bd42619659e`. The [receipt and audit](../measurements/evidence/2026-10-30-camera-shell/) confirm candidate verification and restoration of both prior erase spans with full readback, followed by hard reset. No restored-system boot was captured. This trial used automated serial input; optical appearance and physical keyboard operation were not confirmed. The app is a camera-enabled prototype build, not the default build or a main landing.

The initial trial reached the same shell repaint, but its old diagnostic-view checker rejected the session repaint record. Its flash transaction restored both spans; post-capture candidate verification was skipped by that checker exception. The retained initial log is `/private/tmp/nihos-camera-shell-20261030/serial.log`. The successful retry used a session-aware checker in `/private/tmp/nihos-camera-shell-tools/tools`, with unchanged board identity and flash-transaction checks. It requires a nonzero dismissal sequence, shell view 1 and empty input after verified preview. Raw scene logs remain outside the repository.
