# Card reader scene handoff without panel reinitialization

The public detection notices already used two SRAM banks, but PIN, overview,
portrait and detail screens still called `display.replace`'s cold path:
stop DMA → switch the backlight off → stop the PHY → wipe SRAM → reset and
initialize the panel. Thus normal result/page transitions visibly blinked.

The card/keypad replacement path now stages the new pixels and sparse plan in
CPU-owned PSRAM while the old SRAM scene keeps scanning. It requests retirement
at a completed DMA frame, then drains the bridge and host video FIFOs. Only
after the tail is sent does it enter command/LP mode and retire DPI/DMA. It wipes
the retired SRAM, binds the new plan, primes the FIFO and resumes video without
panel reset, PHY reinitialization or backlight shutdown. It waits for two DMA
completions before returning. No additional framebuffer or SRAM pool is added.

DMA EOF alone is not panel-frame completion: queued tail pixels must be drained.
Rev1 hardware also lacks the newer bridge VSYNC interrupt. This implementation
uses bounded FIFO-empty and stopped-lane conditions rather than claiming an
output-VSYNC interrupt. The video pause remains measurable; optical quality is
a separate acceptance condition.

Ordinary removal during local input retires the card job and replaces its
private display with a public scene. Uncertain transport/display/cleanup errors
still fail dark. Failed retirement retains DMA/domain ownership, so SRAM cannot
be reused until shutdown is confirmed. Cold initialization remains available
for initial startup and recovery from an inactive emergency display.

Foreground polling and CLIC18 share an interrupt-masked display service entry.
The legacy reader's redraw helper is explicitly placed in its audited foreground
Flash section; its unchanged 48 KiB SRAM-heap guard still passes.

## Card-free physical exercise

`NIHOS_NATIVE_CARD_SCENE_EXERCISE=1` requires `DISPLAY=11` and
`CARD_AUTO_PROBE=1`. The image audit rejects linked `usb_probe.Device.*`
functions in this profile. The exercise contains no card communication or
credential submission, even if a reader/card remains attached.

It runs two rounds of PIN1 → PIN2 → synthetic portrait/overview → details →
overview → notice. PIN indicators use generated counts, not user digits. After
the finite run it shows a labelled test screen; taps advance synthetic screens
for optical inspection. The picture is an artificial striped pattern.

The exercise compares the complete actual DMA pixel stream, read through the
uncached SRAM alias in descriptor order, against the staged framebuffer after
every transition and at the final test screen. PIN dynamic textures are first
materialized independently in the expected frame. Only mismatch counts are
logged, not pixels, identity values or touch/key input.

Build the card-free candidate:

```sh
NIHOS_NATIVE_NETWORK=0 NIHOS_NATIVE_USB=1 NIHOS_NATIVE_DISPLAY=11 \
NIHOS_NATIVE_CARD_AUTO_PROBE=1 NIHOS_NATIVE_CARD_SCENE_EXERCISE=1 \
sh tools/build-native.sh device integer
```

The installed source is `2acb01d0c631999f15513d8fa7601bc601e09b3d`.
ELF SHA-256: `ae798b27f620d6d0558aaf93b2944e2526bdd129619cc45a7401b8ebbe86dbdd`.
Application SHA-256: `413ad2e4021a5e5bf7fb51825904f501c64805dd89fe6135167dcd518122c1a9`.
All frozen artifact hashes and manifest source fingerprints matched. The prior
installation and all three new flash ranges were verified under one exclusive
serial descriptor immediately before the warm-reset capture.

Recorded result: 12 automatic transitions; 13 complete pixel comparisons with
zero mismatched words; one panel initialization; zero backlight-off operations;
zero display faults. Maximum measured video pause: 15,897 µs. The final screen
was left for local manual inspection without a post-capture reset.

- [Captured log](evidence/2026-10-28-card-scene-handoff/boot.log)
- [Image audit](evidence/2026-10-28-card-scene-handoff/image-audit.json)
- [Display and scene report](evidence/2026-10-28-card-scene-handoff/report.json)
- [Qualification metadata](evidence/2026-10-28-card-scene-handoff/qualification.json)

```sh
python3 tools/check-native-scene-log.py \
  docs/measurements/evidence/2026-10-28-card-scene-handoff/boot.log \
  docs/measurements/evidence/2026-10-28-card-scene-handoff/image-audit.json \
  /tmp/card-scene-report.json
```

## Failed candidates and acceptance limits

The first exercise stopped before its first scene with a trap. Manual polling
could overlap the IRQ-owned path; polling is now serialized and ordinary
exercise waits leave refresh to CLIC18. The next candidate failed to complete
its first transition. Added stage diagnostics then exposed host
`dpi_buff_pld_under` (`dsi_error1=0x00080000`): video was consuming data while DPI
was paused. JTAG status reads on that already failed synthetic run confirmed
the latched bits; the debugger halted/resumed it without a reset.

[The underflow log](evidence/2026-10-28-card-scene-handoff/underflow-before.log)
is retained. Stopping video consumption fixed that error. A subsequent candidate
passed reset/backlight checks and the user confirmed no flicker, but reported
whole-screen line shifts and missing content. It is an optical failure, not a
successful display qualification. The tail-drain fix and actual-pixel checks
were added after that report. The new drain-fixed candidate's optical result
is still awaiting user confirmation.

Host tests replay the production retirement policy, including bridge/host
draining before shutdown, stuck channel/FIFO/lane ownership retention, and
emergency blanking. Pixel replay tests detect corrupt fixed and incremental
sources, bad widths, out-of-bounds descriptors and incomplete frames. Evidence
checker tests reject dark/reset/stalled/missing transitions, mismatched pixels,
card/input events and a read-enabled exercise configuration. CI builds the
exercise alongside the existing reader profiles.

Host Debug/ReleaseSafe, 219 Python tests, static/ZLint/shell checks and six
audited RV32 links passed. Legacy portrait build/image audit passed with
49,536 bytes of resident SRAM heap. The authenticated image is built/audited
offline; it is not installed or used for further credential submissions here.
Cold power-on, real-card result transitions, and issuer-signature verification
are not qualified by this card-free exercise.

All candidates, failed and successful captures, debugger status, source identity
and build/test output are retained privately under
`/Users/masanork/Documents/Codex/2026-10-28/nihos-card-scene-transitions`.
