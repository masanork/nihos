# Canvas PSRAM scanout: warm-reset fixture

Candidate firmware source commit `3308654`, app SHA-256 `16a3a5993514d6a19cd7158492e9100885748d7828868b04c678f5d49ebc406e`, ELF SHA-256 `47d148ee0a00b55f902279856bfbcd3f3532e8fb9346e9b3d161e709f3df8cf8`. This is the opt-in static diagnostic pattern; it is not a live application-facing display service.

The first attempt could not get a serial response during chip detection. No Flash read or candidate write started; the empty backup is not evidence. The USB serial device disappeared and reappeared. After a passive read and retry, the device identified as ESP32-P4 rev1.3 with the expected MAC. The capture held the cooperative writer lock, exclusive serial descriptor and verified kernel exclusion of both serial aliases; it did not independently exclude writers through another hardware interface.

The retry backed up 16 MiB of Flash and verified it against the device; the partition table matched. It wrote the candidate bootloader and app, verified all three bootloader/table/app ranges immediately before capture, performed one warm USB reset, and verified those three candidate ranges again afterward. The exact identity-matched log passed `check-native-display-log.py --mode 2 --dpi 80 --canvas-demo`:

- CPU framebuffer FNV-1a `549e3481`; 720×1280 portrait, rotation 0.
- Display start success, 2 initial frames; IRQ progress to 32 frames; no reported DMA, bridge or DSI errors.
- The test does not measure DMA pixels, optical color, tearing, frame time or rendering speed.

After capture, the original erase-aligned loader and app spans were restored and the entire 16 MiB Flash was verified against the original backup. The capture then issued a warm reset of the restored device; its subsequent boot was not captured or validated. The private full backup and detailed Flash logs remain in `build/canvas-physical-20261029-retry`, not in this evidence directory. This evidence does not establish cold-power recovery, storage/power-loss behavior or concurrent use. Optical observation remains **not evaluated** until explicitly reported.

[Log](evidence/2026-10-29-canvas-scanout/boot.log) · [Report](evidence/2026-10-29-canvas-scanout/report.json) · [Image audit](evidence/2026-10-29-canvas-scanout/image-audit.json) · [Evidence identities](evidence/2026-10-29-canvas-scanout/qualification.json) · [First failed attempt](evidence/2026-10-29-canvas-scanout/first-attempt.json)
