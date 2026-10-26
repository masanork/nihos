# Native local Input Support read

This opt-in mode reads EF0002 (name, address, birth date and gender). It does
not read the My Number EF, face image or signature AP, and it does not perform
issuer-signature verification. The result screen states that qualification.

```sh
NIHOS_NATIVE_USB=1 NIHOS_NATIVE_DISPLAY=9 sh tools/build-native.sh device integer
python tools/capture-native-usb.py PORT OUTPUT build/native-device/image-audit.json \
  --install build/native-device --card-read --runs 1
```

The existing count-only DISPLAY=8 demonstration remains separate and rejects
USB/JPKI. DISPLAY=9 requires USB=1 and rejects JPKI, CARD_CHECK, SDMMC, storage,
non-device profiles and non-integer modes. All PIN-free boot probes retain
their existing whitelist and cannot submit a PIN.

Before PIN entry, the foreground owner enumerates Sony 054c:0dc9, checks the
Input Support retry count, proves a PIN-free power-cut cleanup, and opens a
fresh session with a fresh retry count. Cleanup requires DMA retirement and
erasure, verified expander OFF control, and USB physical disconnect observed
while the host/PHY is still running. A reset host register is not a disconnect
receipt. The initial session does not submit a PIN. Counts 0, 1, unknown or
already-authenticated status stop the operation before offering entry.

The actual Input Support four-digit PIN is entered only on the device. Each
key commits once on an explicit single-contact release. Holds, drags and
multiple contacts disarm the gesture. "確認" triggers one submission; the
counter is rechecked before constructing VERIFY. A final transport whitelist
allows only this AP's commands and consumes its single VERIFY budget before
starting USB. Failed or uncertain outcomes never retry or reopen PIN entry.
The PIN prompt expires after 180 seconds and cancels with cleanup.

Common Owner.step still requires inactive CCID state. Only the explicit
stepWithPowerCut API can substitute the board's proved physical-disconnect
cleanup. Authenticated attributes remain inaccessible until terminal cleanup
succeeds. The final Device.close additionally checks VBUS OFF control. This
checks control/readback and detach; it is not a VBUS-voltage or RF measurement.

The foreground paints a staging RGB565 frame and sparse plan in the reserved
display PSRAM span. Before starting scanout it copies every nonuniform pixel
to dedicated SRAM. Per-frame DMA reads only SRAM. PIN indicators/confirmation
use the existing small frame-boundary texture swaps. Result changes retire
DMA before clearing both SRAM pools and rebuilding a scene. Rendering and
card foreground entry points are individually named and bounded in a separate
RX Flash section in the first mapped page; display IRQ/runtime stays in SRAM.
The image auditor keeps the existing 48 KiB SRAM heap floor and stack layout.

Results use a generated 16x16, two-times-scaled bitmap font from the pinned
Noto Serif CJK JP Regular (Copyright 2017-2024 Adobe, SIL OFL 1.1; see
[src license](../src/graphics/boot/OFL.txt)). Latin and JIS X 0213 single-codepoint
coverage totals 11,336 glyphs / 408,096 bytes. Unsupported characters show a
square and increment a metadata-only missing-glyph counter. Each page shows
at most 84 characters; tap to continue long fields, then name/address/date/
gender in order. The last tap or a 180-second page timeout clears attributes,
staging pixels and retained scanout pixels. There is no automatic new card job.

UART records only lifecycle status, counters, cleanup mode and field-presence/
shown masks. It never logs PIN digits, touch coordinates, key identities,
APDU contents, attribute values or their hashes. Captures allow one read run
only. No network or persistent result storage is used by the firmware.
Capture post-verification resets the board; reusing the image can offer a new
PIN-free prompt, but no PIN survives reset and no submission is automatic.

Host replay tests cover dense Japanese pages and actual PIN-screen layouts
against the SRAM capacity and renderer output. Host models cover failures,
uncertain VERIFY, changed/last retry counts, cancellation, bounded reads,
CCID extension polls, strict cleanup, explicit power-cut fallback and PIN
buffer erasure. Native results and the user's optical confirmation must be
recorded separately from these host/build checks.
