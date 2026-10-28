# Tab5 UI host simulator

Use this while physical Tab5 testing is unavailable. It has no serial-port,
USB-reader, APDU or credential transport. Card insertion, authentication outcomes
and result data are fixtures. PIN input uses the production count-only demo
model: it stores a count, never the numeric values.

The normal UI uses the production splash, incremental console renderer,
boot-state model, pointer rotation, stream, queue and release-gated button.
Its boot checkpoints and log messages are synthetic. It models a host frame
boundary, not the normal firmware's PSRAM/DMA/cache or interrupt behavior.

## Run

```sh
python3 tools/card_sim/app.py
# Open http://127.0.0.1:8711
python3 tools/card_sim/app.py --application normal
# Open http://127.0.0.1:8711/?app=normal
```

Python 3 and the pinned Zig toolchain are sufficient on supported macOS/Linux
hosts. The command bootstraps Zig through the existing checksum-pinned script
when absent. There are no pip packages, browser extensions, ESP-IDF requirements
or CDN assets. The server listens on loopback only. The normal and card pages
have independent models and frames; requests are serialized because production
components have global state. Do not create multiple instances of the same
application and assume isolated production globals within one process.

Select **通常UI** in the header and tap the gray LOGS/SPLASH control. The browser
converts its landscape 1280x720 coordinates to the controller's portrait
720x1280 coordinates, then the production pointer model rotates them back.
Only a valid single-contact release toggles the view. Long holds, drag-out,
multiple contacts, missing reports and queue overflow cannot complete a click.
Escape/Ctrl-L also use the production boot-state actions. Add synthetic log
lines to exercise scrolling and compare incremental pixels with full repaint.
The queue checkbox/drain and simulated time controls allow rejected gestures
to be reproduced. Corrupt a log pixel to establish a negative control; the
candidate is rejected by the oracle and full redraw can repair it.

Choose **待受へ**, then place a synthetic traditional licence or My Number Card.
Tap the PIN keypad to add four count-only digits and confirm. The traditional
licence fixture asks twice. Overview includes a synthetic color pattern in the
portrait area to make row/stride errors visible. Use the sidebar to inspect
details, return, close, or remove the card. The result controls inside the canvas
also work: basic information, next history page, and close/erase. They use the
same `card/result_input.zig` controller as the native application. The My Number
fixture closes on a tap anywhere, matching that application's result handler.
Stable removal rearms the production
presence gate; leaving a card held cannot start another authentication job.
The synthetic licence has one history page. The full firmware's application
owner, timeout policy and card services are not run. After a PIN release the
host controller supplies a fresh idle report to arm the result-screen gate;
a preceding held contact remains quarantined until release.

Disable automatic EOF to hold the displayed frame while the candidate waits.
Advance EOF explicitly to publish it. Fault controls model a stuck DMA channel,
undrained FIFO, unstopped lane, failed cache handoff, or insufficient descriptor
capacity. Pixel corruption deliberately modifies a live SRAM span; the mismatch
counter must become nonzero. Clear injection and reset after a retirement fault.
Explicit shutdown cannot release SRAM while DMA is stuck.

**操作を保存** downloads a semantic JSON trace. Replay it in the UI or with:

```sh
python3 tools/card_sim/app.py --replay build/card-sim/evidence/trace.json
python3 tools/card_sim/app.py --application normal \
  --replay build/card-sim/evidence/normal/trace.json
```

Card events contain count changes, erase/cancel/confirm, result controls and
fault settings. Card replay rejects coordinates and numeric keys. Normal UI
traces are a separate format, explicitly marked `application: normal`, and save
portrait coordinates, contact counts, time deltas and queue dispatch policy.
They replay through the real input model, including rejected gestures, rather
than directly assigning a view. A normal trace is rejected by the card endpoint.
Normal recording stops at 4096 events and exposes `trace_full`; further input
is withheld until reset, so a saved trace remains complete and replayable.
The normal replay endpoint accepts up to 1 MiB for that bounded stream. Card
request limits remain unchanged. HTTP request logging is disabled. This tool
is for synthetic inputs.

## Base-image SRAM budget

The display uses the real `nih_sram_pool` allocator, then the real sparse builder
placement rules within those leases. It never reserves a separate card-only
address region over the base image. Built-in profiles are explicit templates:

| Template | Free low extent | Free high extent | Maximum display leases |
| --- | --- | --- | --- |
| Normal | `4ff40000..4ff60000` | `4ff6e000..4ff9f000` | 128 + 188 KiB |
| Resident font | `4ff40000..4ff60000` | `4ff80000..4ff9f000` | 128 + 124 KiB |

The normal high extent has 196 KiB free; the display quota caps its lease at
188 KiB. A smaller base free extent remains smaller. To use an actual base
build's `service_sram` extents instead of a template:

```sh
python3 tools/card_sim/app.py --base-audit build/native-emulator/image-audit.json
python3 tools/card_sim/app.py --base-audit build/native-emulator/image-audit.json \
  --headless build/card-sim/audited-evidence
```

The audit's extent names, bounds, alignment and sizes are checked before import.
The simulator retains the JSON hash and its declared ELF hash; it does not
reaudit an ELF or establish that the audit describes a currently running board.
Use a report generated by `check-native-image.py` for the intended base image.
The imported profile is added to the browser selector, and headless mode adds
an audited-budget scenario. Quota rejection keeps the old scene and leases.
Minimum allocator quotas remain 64 KiB low and 8 KiB high.

## Repeatable checks and artifacts

```sh
python3 -m unittest discover -s tools -p 'card_sim*test.py' -v
python3 tools/card_sim/app.py --headless build/card-sim/evidence
```

The default headless run checks fourteen card contracts: full fixture lifecycle,
EOF atomicity, touch release/drag/multicontact, capacity rollback, three bounded
retirement failures, cache rejection, pixel corruption as a negative control,
base templates, deterministic semantic replay, result controls/drag rejection
and My Number dismissal. Ten normal-UI contracts cover view roundtrip,
rejected/stale contacts, queue overflow, frame boundaries, scrolling/palettes,
raw-input replay, bounded trace capture, a pixel negative control/repair and a
synthetic failure.
HTTP regressions additionally check actual frame bytes, trace replay,
normal/card format separation, stale-frame rejection and origin policy.
The regular host CI gate runs these and retains headless evidence artifacts.

The output contains `report.json`, source/compiler/shared-library hashes,
`trace.json`, `boot.png`, `overview.png`, and the exact `overview.rgb565` frame.
The receipt binds evidence to the loaded host libraries and their source
fingerprint. Shared libraries are content-addressed, checked before reuse, and
built via temporary files so a partial compile is not accepted as a cache hit.
PNG export uses only Python's standard library.
Normal reports, a typed trace, source receipt and landscape `splash.png` and
`logs.png` are retained under `normal/` in the same output/artifact directory.

## Evidence boundary

| Layer | Executes | Does not qualify |
| --- | --- | --- |
| This host simulator | Production splash, compressed font decoder, PIN/result renderers, touch contact/count model, presence gate, SRAM allocator, sparse C builders, publication/retirement policy, pixel checker | RV32 ABI/CPU timing, interrupts, cache coherency, physical DMA/MIPI, optical flicker, touch controller, USB/CCID/APDU, card data decoding or signature verification |
| Normal UI host mode | Production normal splash, console incremental/full raster, gray control, boot-state actions, pointer rotation/stream/queue/button | Native application-owner scheduling, PSRAM placement/scanout, cache/DMA/interrupt behavior, actual boot/device status and latency |
| ESP-EMU native smoke | Actual RV32 application image, emulated CPU/SMP/timer behavior | Complete Tab5 board, display, USB reader or card interoperability |
| Physical Tab5 | Candidate-specific device behavior | Anything outside that candidate and measured scenario |

The C adapter maps addresses and supplies a small logical descriptor layout;
production builder and retirement functions run unchanged. Register waits use
bounded deterministic predicates, not an ESP32-P4 peripheral model. The browser
displays replayed descriptor/SRAM pixels rather than the CPU staging framebuffer.
The CPU frame is the comparison oracle; the production scene checker supplies a
second comparison. A modeled backlight-off count of zero is a policy check,
not an optical measurement of flicker.

Keep genuine target execution as a separate check:

```sh
sh tools/run-native-smoke.sh integer 0
```

This uses the existing pinned ESP-EMU and requires the pinned ESP-IDF setup for
boot artifacts. No command in the simulator guide flashes hardware. Physical
qualification remains pending until a device is available.
