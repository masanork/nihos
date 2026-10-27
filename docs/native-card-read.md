# Native local card overview

DISPLAY=9 reads Input Support EF0002 (name, address, birth date and gender).
DISPLAY=10 additionally reads the Surface AP portrait and displays it beside
the four fields in one overview. Neither mode performs issuer-signature
verification; the result screen states that qualification. DISPLAY=9 never
reads the My Number EF. DISPLAY=10 uses that EF only as a transient Surface AP
credential; the number is never displayed, logged or retained.

```sh
NIHOS_NATIVE_USB=1 NIHOS_NATIVE_DISPLAY=10 sh tools/build-native.sh device integer
python tools/capture-native-usb.py PORT OUTPUT build/native-device/image-audit.json \
  --install build/native-device --card-read --runs 1
```

The existing count-only DISPLAY=8 demonstration remains separate and rejects
USB/JPKI. DISPLAY=9 and DISPLAY=10 require USB=1 and rejects JPKI, CARD_CHECK, SDMMC, storage,
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
square and increment a metadata-only missing-glyph counter. One screen shows all four fields, wrapping the address over six rows and
placing a 192x256 portrait at the upper right. Extremely long fields show an
explicit ellipsis and a truncation receipt; missing glyphs remain counted.
A tap or a 180-second result timeout clears attributes,
staging pixels and retained scanout pixels. There is no automatic new card job.

UART records only lifecycle status, counters, cleanup mode and field-presence/
shown masks. It never logs PIN digits, touch coordinates, key identities,
APDU contents, attribute values or their hashes. Captures allow one read run
only. No network or persistent result storage is used by the firmware.
Capture post-verification resets the board; reusing the image can offer a new
PIN-free prompt, but no PIN survives reset and no submission is automatic.

Host replay tests cover dense Japanese overview screens and actual PIN-screen layouts
against the SRAM capacity and renderer output. Host models cover failures,
uncertain VERIFY, changed/last retry counts, cancellation, bounded reads,
CCID extension polls, strict cleanup, explicit power-cut fallback and PIN
buffer erasure. Native results and the user's optical confirmation must be
recorded separately from these host/build checks.

DISPLAY=10 first decodes an embedded synthetic image and checks every RGB565
pixel by a fixed reference checksum, then probes the Surface AP retry count
without a credential. Any failed preflight stops before offering PIN entry.
The initial display is explicitly labelled synthetic data; tap/release opens
the actual PIN screen. This gesture cannot become a PIN key.

After the single successful Input Support PIN, EF0001 supplies the 12-digit
Surface credential. The owner rechecks the Surface retry count, rejects
last-attempt/blocked/changed counters, and submits that credential at most
once, with a separate final-wire budget. Unknown outcomes are terminal.
DF27 is parsed only inside bounded Surface data; no Surface credential is
needed if the AP already reports authenticated before a known counter.

The opt-in codec is pinned OpenJPEG 2.5.4, BSD-2-Clause, restricted to decoding
JP2/J2K (no HTJ2K). Its private task-owned PSRAM lease is 4 MiB minus 128 bytes,
including 32 KiB encoded data, 96x128 RGB565 pixels and a bounded allocation
arena. It has no file, network, diagnostic or thread I/O. Dimensions are
limited to 512x640, one/three components, up to 8-bit precision. Aspect ratio
is preserved with paper-coloured padding. CPU0 borrows only its quiescent
12 KiB worker-stack span; guard/high-water metadata and full workspace
erasure are required. The image audit binds source/object hashes, Flash
functions/sections, static C frames and the existing 48 KiB SRAM heap floor.
This is a bounded prototype, not general JPEG2000 security qualification.

Run `sh tools/check-photo-codec.sh` for synthetic reference, truncation, quota
and guard checks under ASan/UBSan. `probes/photo/README.md` records the codec
profile and provenance. Actual card/photo rendering and optical confirmation
remain physical-device evidence, separate from these build and host tests.

EF0001 numbers accept a primitive FF10 TLV with padding, legacy 01/DF01 or
exactly twelve ASCII digits. Duplicate fields, malformed lengths, non-digits
and a bad check digit stop before Surface credential submission. References:
[author's card read trace](https://tex2e.github.io/blog/protocol/jpki-mynumbercard-with-apdu)
and [J-LIS check digit formula](https://www.j-lis.go.jp/data/open/cnt/3/1282/1/H2707_qa.pdf).
No digit filtering or guessed credential fallback is used.

A later Surface/photo error preserves only already validated four fields,
and exposes them via `attributesResult()` only after successful terminal
cleanup. The existing `result()` still requires overall job success. Failed
cleanup, cancellation and disconnect erase the fields. The UART phase record
contains only failed state, status word, timeout category and consumed VERIFY
budgets. Failure paths now emit RESULT as well as DONE, even without attributes.
End messages distinguish timeout, cancellation, PIN/counter problems,
communication/parse failure and partial portrait failure.
