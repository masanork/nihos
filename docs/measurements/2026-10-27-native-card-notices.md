# Card status transitions: remove panel restarts

The operator reported a visible flash whenever a conventional IC licence was
placed on or removed from the reader. This was observed with the PIN-free
probe, before authenticated licence reading. PIN tests were suspended at the
operator's request while the display issue was investigated.

## Cause and implementation

`card_auto.notice()` previously called `display.replace()` for every public
status message. That path stopped DMA, drove GPIO22 low, stopped the DSI PHY,
and ran the complete panel reset/initialization sequence before restarting
scanout. The initial reset alone waited 120 ms. Ordinary insertion/removal
therefore used a cold-start path and deliberately darkened the screen.
The reader-open/slot-error recovery path also called display emergency cleanup
before drawing a new public status message.

Public notices now use two 94 KiB banks inside the existing 188 KiB upper UI
SRAM pool. The next sparse frame's descriptors and pixel payload are prepared
in the inactive bank. A completed DMA frame publishes the new list head;
the old bank is not modified while it is visible. Panel timing, PHY and
backlight continue running. Cache handoff is limited to the inactive bank,
and all subsequent descriptor/pixel stores use its noncached alias. Invalid,
oversize, pending or cache-failed candidates are not published.

Public-notice USB recovery retires card/workspace state without stopping the
display. Failures during private card jobs retain complete emergency erasure.
Transitions to/from PIN, profile-choice, licence/history and portrait views
still use the existing stop/wipe/rebuild path; this change qualifies only the
insertion/removal notices, not every application scene transition.

Foreground notice preparation and automatic-mode scanout initialization use
explicitly audited Flash functions. The frame-completion/IRQ path stays in
SRAM. No memory region, heap minimum, stack or Flash capacity was enlarged.

## Software evidence

- Zig Debug and ReleaseSafe host tests passed. Every one of the 27 actual
  public captions, rendered as both title and detail, fits either bank and
  reconstructs the complete RGB565 frame exactly.
- The production C bank builder/publication code passes a host replay with
  exact pixel checks, immutable active-bank checks, delayed frame handoff,
  pending-bank exclusion and invalid/capacity/cache-failure rejection.
- The Python suite passed 147 tests. Its new notice-log regression rejects
  panel restarts, backlight-off transitions, faults and nonadvancing frames
  or swaps. Format, ZLint, shellcheck and six default RV32 ELF audits passed.
- Full/probe device candidates passed their ELF/image audits. Earlier full
  builds hit the existing 48 KiB SRAM heap assertion; their logs are retained.
  Moving foreground-only initialization/preparation to audited Flash resolved
  the limit without changing that assertion.
- The legacy DISPLAY=10 device image also passed its ELF/image audit, retaining
  its previous 49536-byte primary SRAM heap and no automatic-reader profile.

| Candidate | ELF SHA-256 | Primary SRAM heap |
| --- | --- | --- |
| Full | `4f91f609b719bb6b586668fb60dcc84b35c7666af7646b8b9b6f18a7f17b0685` | 51072 bytes |
| Probe | `3a624f476bd03b7713e400d58f85d854214e4fff0fa2f51d64ccce437000ed74` | 56704 bytes |

Exact binaries, options, manifests, loader artifacts and hash receipts are
retained in `build/licence-flicker-release-{full,probe}`. The full application
image hash is `71377aa27827ba56242f04bf18265ebfaf4cc6301771c16b4a12712bbab47076`;
the probe image hash is `c25baaa202d30b0d23382b42ebc3e0dcff7602ebb34f07ad42c7a7e27c35bb11`.

## Physical gate remains open

These candidates have not been installed. Another worktree's live SD
qualification held the shared serial port; it was not interrupted. No card
credential was submitted during this investigation. The operator's successful
classification/removal observations belong to the earlier probe firmware.

The next physical check is the new PIN-free probe's insertion, held-card,
removal and reader-reconnect behavior, with separate optical confirmation.
`NIHOS_NATIVE_CARD_AUTO_DISPLAY` records only swap/frame counts, panel-start
count, backlight-off count, backlight state and fault state. The probe log
checker requires one panel start, zero backlight-off transitions, continuing
frames/swaps and no display fault across boot/classification/removal.
This metadata cannot establish absence of all optical artifacts by itself.

Authenticated reading remains deferred until this display gate is checked.
No real licence signature verification is claimed; issuer keys remain absent.
