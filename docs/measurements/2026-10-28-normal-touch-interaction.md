# Normal touch interaction, report batching and deferred final qualification

2026-10-28 JST. These checkpoints extend the [idle check](2026-10-28-normal-touch-idle.md).
The final main-integrated candidate remains unqualified, and the PR stays draft.
The user deferred further device tests. Its interrupted restoration was completed
and verified after USB reconnection; that recovery does not qualify the capture.

## Initial normal-image interaction

Candidate `2cbb530b12a4b41bca58f40744bdccbe9f06996e8e5341985d0cffa4ba59486b`
ran for 368.429 seconds in attempt-02. The operator reported that the LOGS and
SPLASH views switched in both directions. The
[touch report](evidence/2026-10-28-normal-touch-interaction/touch-report.json)
records four explicit down/up pairs and four accepted alternating source=5
actions. [Operator evidence](evidence/2026-10-28-normal-touch-interaction/observations.json)
and a [serial excerpt](evidence/2026-10-28-normal-touch-interaction/serial-excerpt.log)
retain those separate observations. Only one quadrant was observed; negative
gestures were not confirmed.

Maximum touch polling work reached 19963 us. After the first touch, the
coordinate-present status remained set and full ten-slot scans continued after
release, so this was a continuing foreground cost. Individual seven-byte slot
reads required eleven transactions including status. The
[service report](evidence/2026-10-28-normal-touch-interaction/service-report.json)
passes finite speaker, microphone/erasure and internal UART cleanup checks.
This session did not acquire a network session: NTP attempts and RTC writes
stayed zero. Its unavailable-network control is distinct from the earlier
successful NTP checkpoint; it is not a connected coexistence claim.
The [qualification receipt](evidence/2026-10-28-normal-touch-interaction/qualification.json)
records full app restoration and unchanged boot bytes.

## Batched report reads

Runtime `94c8bde` independently implements the existing contiguous report layout
described by the [Espressif ST7123 driver](https://github.com/espressif/esp-iot-solution/blob/master/components/display/lcd_touch/esp_lcd_touch_st7123/esp_lcd_touch_st7123.c).
Nine whole records (63 bytes), then the remaining record (7 bytes), fit the
existing 64-byte bus limit without changing I2C speed, controller reset, IRQ or
release interpretation. All slots are still inspected. Host tests check sparse
tenth-slot contacts, second-contact detection, 1/9/10-slot bounds and failure
of the second read without publishing a partial sample.

The initial host attempt exposed inferred narrow-integer overflow in the batch
length expression. An explicit `usize` count fixed it before any new firmware
was installed; Debug and ReleaseSafe passed afterward.

Candidate `d7fcb8eb8f5c1537be87a93694211b7d8a57c9dbc70356c2198c4e5a88c947a0`
ran for 748.353 seconds in attempt-03. The
[touch report](evidence/2026-10-28-normal-touch-burst/touch-report.json)
records five down/up pairs, two accepted alternating view actions, 21507 polls,
16620 coordinate-present reports, no touch errors/overflow and a maximum read
duration of **14281 us**, approximately 28% lower. This is foreground read
duration, not end-to-end finger-to-display latency. This candidate has serial
view-action proof; no new independent optical or negative-gesture confirmation
was received. The [same-capture service report](evidence/2026-10-28-normal-touch-burst/service-report.json)
passes connected NTP-to-RTC, finite audio, microphone/erasure and internal UART
checks. [Identity/restoration evidence](evidence/2026-10-28-normal-touch-burst/qualification.json)
and its [loader audit](evidence/2026-10-28-normal-touch-burst/image-audit.json)
bind the exact candidate. The full app was restored and boot bytes were unchanged.

## Final main integration: interrupted, not qualified

Main `542e6ac` was integrated in `8efd270`. Host Debug/ReleaseSafe each pass 412
tests, Python passes 264, static analysis and six RV32 audits pass, and configured,
unconfigured and standalone-touch builds/audits pass. The
[same-profile comparison](evidence/2026-10-28-normal-touch-burst/layout-comparison.json)
measures static heap 62848 → 58176 bytes, a 4672-byte static SRAM cost.
The baseline is an ELF-only link measurement; it is not physical free-heap proof.

Candidate `42f1e05fd858f651fbb51b5a0309446e8bb087b3f5250143babc063abbf822b0`
was installed and verified, then booted and identified ST7121 in attempt-04.
USB disappeared during capture with `Device not configured`. The saved app
could not be restored because the device was absent. The
[interrupted receipt](evidence/2026-10-28-normal-touch-main-interrupted/qualification.json),
[pre-capture audit](evidence/2026-10-28-normal-touch-main-interrupted/image-audit.json),
[excerpt](evidence/2026-10-28-normal-touch-main-interrupted/serial-excerpt.log) and
[deferral](evidence/2026-10-28-normal-touch-main-interrupted/observations.json)
preserve the failure. No post-capture verification, complete log or restoration
claim is made. Earlier candidate observations do not qualify this final image.

Private backups, frozen credential-bearing images, full logs and scripts remain
under `/private/tmp/nihos-normal-touch-input/build/touch-qualification/`.
`attempt-04/app-before.bin` is the complete saved 1 MiB app, SHA-256
`6126f70e6fd3137c7fd7f8d0b645e83101d37fd2935e905462ebf2e81aa90ecb`.
The recovery script is `restore-final.py` there. It verifies chip/MAC, boot bytes,
backup hash and current candidate app before restoring; changed device contents
cause it to stop without writing. At 17:15 JST the device was reconnected. The
script matched the candidate and boot bytes, restored the full saved app and
verified it, and confirmed boot bytes were unchanged. The
[recovery receipt](evidence/2026-10-28-normal-touch-main-interrupted/restore-result.json)
supersedes the earlier incomplete-restoration state; the interrupted receipt
above is retained as a snapshot of the original failure. The device now has the
saved prior app, not the touch candidate. No additional operator test is implied.

Remaining device gates are the exact final candidate's visible view switching,
four quadrants, outside taps, long hold, drag-out-return, multiple-contact
suppression and an ordinary tap afterward, under connected device work. GT911,
ST7123, cold cycling, acoustic quality, IRQ input and external RS485 remain
separate qualification work. The excerpts contain selected first/last records,
not the full hashed private logs.
