# Tab5 foreground card startup: scheduler timer handoff

The first physical `DISPLAY=11` PIN-free probe from main `734e89e` stopped
after display startup with `cause=b8000010` and `native task dispatch`.
No card classification or credential submission occurred. The failed log is
retained in [the evidence directory](evidence/2026-10-28-card-foreground-startup/failed-boot.log).

The integration retained the scheduler timer's CPU0 CLIC16 enable and TG0T0
interrupt-matrix route while handing the timer to the foreground card loop.
`Timer.start()` arms the elapsed alarm before the following `disarm()`, allowing
an interrupt to enter the retired scheduler with a foreground Flash frame.
The fix masks interrupts, disables those CPU0 routes, stops and acknowledges the
timer, fences MMIO, then restores the previous interrupt state. Early display
initialization and the normal live console keep their scheduler ownership.

The model regression exercises the old stop/start/disarm ordering as a negative
control, then checks the new handoff with interrupts initially enabled/disabled,
the peer route unchanged and the elapsed counter available afterward.

## Physical startup evidence

- Runtime source: `787610a292e5078091a903f95854d21288f563d1`.
- ELF SHA-256: `5a3602961b67e4e94a4214cdfa8f23fa14163c1dc789c016dea507c27226e261`.
- Application SHA-256: `3641a00742dd118d81d9c07c1be95a8c98830be752b8c82345aab15bec1ee6b5`.
- Explicit `NETWORK=0 USB=1 DISPLAY=11 CARD_AUTO_PROBE=1`; reading disabled.
- Prior installation verified, all three candidate flash ranges written and
  verified under one exclusive serial lease, then warm USB reset.
- Fixed log reaches 32 refresh frames, the automatic-card self-test, and a
  public notice with one panel start, zero backlight-off operations, and no fault.
- All frozen artifact hashes and the manifest's current source fingerprints match.
- [Raw startup snapshot](evidence/2026-10-28-card-foreground-startup/fixed-boot.log),
  [image audit](evidence/2026-10-28-card-foreground-startup/fixed-image-audit.json),
  [pre-capture flash verification](evidence/2026-10-28-card-foreground-startup/fixed-verify-before.log),
  and [display report](evidence/2026-10-28-card-foreground-startup/fixed-display-report.json).

The hardware run also exposed two validator integration omissions: the audited
automatic-card self-test's auxiliary `BOOT` header was treated as foreign
firmware, and portrait keypad/card modes 8–11 were checked as landscape. The
validator now accepts that one ordered auxiliary header only for audited
automatic-card images and checks those modes as 720 × 1280, rotation 0.
Foreign headers, repeated/reordered boots, multiple ROM banners, and wrong
geometry remain rejected. Tests replay the fixed physical snapshot.

## Scope and validation

Host Debug and ReleaseSafe, static/ZLint/shell checks, six RV32 audited links,
and probe/full/legacy card image builds passed. The updated Python suite passes
206 tests. The captured startup passes:

```sh
python3 tools/check-native-display-log.py \
  docs/measurements/evidence/2026-10-28-card-foreground-startup/fixed-boot.log \
  docs/measurements/evidence/2026-10-28-card-foreground-startup/fixed-image-audit.json \
  /tmp/card-foreground-display-report.json --mode 11 --dpi 80
```

This is physical warm-reset startup evidence. Card insertion/removal, visible
flicker, cold power-on, credential reads, and signature verification are not
qualified by this snapshot. No PIN was entered. Full and legacy builds were
checked offline and were not installed during this run.

The immutable candidate and additional failed/checker snapshots are retained at
`/Users/masanork/Documents/Codex/2026-10-28/nihos-card-foreground-787610a`.
The earlier `card-notice-timer-probe-frozen-01` directory is diagnostic only: it
was not installed and does not bind its binary to the final manifest sources.
