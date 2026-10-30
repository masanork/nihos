# Updating camera preview prototype (2026-10-30)

The shell `camera-live` command keeps the sampled preview visible and starts the next capture after each successful presentation. It uses the existing retained-frame restart path, rather than releasing its frame or DMA channel. Each image remains an 80×45 grayscale sample enlarged to a 320×180 rectangle. This is a slow updating preview, not a video pipeline.

The CPU0 overlay can refresh while visible. A key stops the live session; if a frame is already being captured, the session drains and discards it before accepting another camera request. Input during that drain is suppressed. Stopping during the initial capture also discards its result. A capture failure stops automatic requests and returns the ordinary UI. The recognized touch view button follows the same stop path; physical touch and keyboard have not been tested in this trial.

## Final physical workflow

On Tab5 ESP32-P4 rev 1.3, MAC `e8:f6:0a:e2:e8:9c`, one exact candidate completed:

1. Enter shell and start `camera-live` once.
2. Automatically capture and present sequences 1–5 without closing the overlay. All five sampled hashes differed and all CPU framebuffer comparisons had zero mismatches.
3. Send serial Escape, repaint shell view 1, and discard the pending sequence 6 without presenting it.
4. Run `camera`, capture and present sequence 7, then close it with Escape.
5. Run `camera-live` again and stop while its first capture is loading. Discard sequence 8 without presentation, then successfully run the shell `mem` command.

The first five presentation frame counters were 332, 476, 617, 759 and 901; the manual capture was presented at 1180. These are display progress observations, not an independently timed camera frame rate. This path reinitializes the sensor and receiver for each image and updates on the order of a few seconds. The previous retake trial separately measured approximately 2.3–2.4 seconds per retake.

App SHA-256 `8652c98a94ccb3b1a3f6f1d1b91580105c99441ac58bc6ee09cf3b40ac23aa33`; ELF SHA-256 `4e6808695c7ae813568ded858854cd393a1fb8cd62a1efb8e83772a691886bb9`. The [receipt and image audit](evidence/2026-10-30-camera-live/) record exact candidate verification before and after capture, restoration of both previous erase spans and full readback verification. A hard reset followed restoration; no restored-system boot was captured. This remains an isolated, uncommitted camera-enabled prototype, with network and normal storage disabled. Optical appearance, scene identity, sustained operation, general DMA release and video remain unqualified.

## Reset boundary and incomplete trials

The initial USB-reset trial `/private/tmp/nihos-camera-live-20261030` produced three live images and then stopped on a capture failure. It did not retain immediate failure details. The next USB-reset trial `/private/tmp/nihos-camera-live-detail-20261030` failed its first CSI preparation: `state=13`, `result=2`, `failed_phase=3`, `reason=0x1007`, indicating pre-existing receiver clock bits. This is an unresolved USB-reset/recovery boundary; the root cause of the initial failure is not established.

The successful workflow used esptool's ESP32-P4 `watchdog_reset()` after checking chip revision and MAC, then reopened serial under the existing lock and exclusivity checks. This is not a cold power-cycle. The intermediate `/private/tmp/nihos-camera-live-watchdog-20261030` completed the workflow but failed an overly strict ROM-banner check because the leading banner was not retained across reset/reopen. Its capture exception skipped post-capture candidate verification. The final checker instead requires one native session startup, no repeated ROM banners or foreign firmware header, and all workflow records; independent candidate byte verification remains mandatory. All incomplete transactions restored both prior spans; they are not counted as final qualification.

The final raw log and frozen binaries are in `/private/tmp/nihos-camera-live-final-20261030`. The private adapted qualifier is `/private/tmp/nihos-camera-live-tools/tools/qualify-camera-id.py`. Host tests cover refresh during presentation, refusal to refresh during dismissal/recovery, and draining an outstanding frame before restart. The host suite and camera/normal native image audits passed.
