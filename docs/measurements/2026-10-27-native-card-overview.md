# Native card overview and portrait candidate

Firmware source: `4d31507` (one-screen implementation `cdf1c5c`, followed by
CPU0 foreground-owner allocation correction). This candidate has no completed
real-card portrait-read receipt yet.

The user reported successful four-field browsing on the preceding paged
implementation. That optical observation is retained separately in
[the preceding read record](2026-10-27-native-card-read.md).

## Host and build evidence

- Debug and ReleaseSafe: 224 tests passed.
- Python evidence checker regressions: 138 tests passed.
- ZLint: 109 files, zero errors/warnings; shellcheck passed.
- Six existing native architecture/image links passed; DISPLAY=8 and DISPLAY=9
  also linked after the overview/service changes.
- ASan/UBSan: five synthetic JP2/J2K fixtures match stock reference RGB565;
  lossless, lossy, SYCC, wide grayscale, malformed/truncated input, output/arena
  guards and quota exhaustion covered. No real card data enters these tests.
- DISPLAY=10 native image audit passed. Encoder/I/O functions are rejected,
  source/object hashes bound, task-owned PSRAM and stack quotas recorded;
  the 48 KiB minimum primary SRAM heap is unchanged.

## Physical attempts (retain failures)

1. `card-overview-cdf1c5c-attempt-1`: pre-install comparison against the older
   reader firmware failed, so no new image was written. Subsequent app-header
   identification found the native-console `live-01` ELF SHA
   `d046b866f6c5847990e0aae071da1aecb373db362861aa34d0f5b01892379b15`.
2. `card-overview-cdf1c5c-attempt-2`: console image fully verified under the
   install lease, then overview image flashed and verified. Preparation stopped
   at `PhotoOwner`, before decoder selftest, USB/card session or PIN offering.
   Post-run Flash comparison retained. No authentication occurred.
3. `card-overview-4d31507-attempt-3`: corrected allocator uses the already-live
   CPU0 bootstrap owner, with no fabricated task generation or owner shutdown.
   Pre-install comparison against attempt 2 required under the same lease.
   Native synthetic decode reference passed (`selftest=1`, `error_code=0`),
   stack high-water 1112 / 12288 bytes, workspace 4194176 bytes. PIN-free
   Surface query returned `63CA`, counter 10. Synthetic overview scanout and
   explicit tap-to-start stage reached. Real card/portrait and optical results
   remain pending; no credential has been submitted at this checkpoint.

Artifacts, exact source/ELF/manifests, installation binaries, checks and raw
metadata logs are retained in
`~/Documents/Codex/2026-10-27/nihos-native-card-overview/`.
The capture never records a PIN, APDU contents, individual number, attributes
or portrait. Surface credential submission has its own one-use budget.

## Exact candidate image

- ELF SHA256: `a9e3c0ee83fc6e43b99820b780e741534bc48d7c941ccacd8d2b42ab1d63d114`
- App SHA256: `deeb037e852743bded3f8cdb30c811310873e6c14c1abfc6983a8052802543fc`
- Codec text: 128832 bytes; RO data: 23260 bytes.
- Maximum reported C frame: 560 bytes (not a full call-graph stack bound).

## User-reported reset after local confirmation

The user pressed the device PIN and confirmation controls, then observed a
restart. Attempt 3 retained `CARD_READ_READY` with Input Support remaining 3,
followed by `DISPLAY_IRQ_FAIL`: frame 413 (`0x19d`), event 2, DMA error
`0x2000`, no DSI/bridge errors, then `FAIL display refresh`. This bit is named
`SHADOWREG_OR_LLI_INVALID_ERR` in the pinned IDF HAL. No read-result/cleanup
receipt was reached; whether a credential was dispatched is unknown from
this old log. An unchanged retry count later cannot prove a PIN was never
sent, because a successful VERIFY can reset the count.

The capture tool subsequently verified the installed Flash successfully and
issued `hard_reset`, explaining the observed restart after the display fault.
The firmware's own fatal path halts after emergency cleanup; it does not
request reboot. The timing of the user's observation is separate from the
captured metadata; the first fault here is display DMA, not a recorded wrong-PIN
response.

Correction candidate `00c0871` flushes/invalidates descriptor memory before
using only its non-cached CPU alias, following IDF v5.4.4's DW-GDMA driver.
DMA head/next pointers retain cached bus addresses. Descriptor-memory cache
writeback is removed from frame rearming, while pixel/texture synchronization
is retained. Before enabling local entry, a synthetic count-only screen
cycles 0..4 twelve times, holding each update for eight frames (at least 480
frames), without calling `Service.submit`. This is a physical regression gate,
not proof of the cause until exercised on hardware.

Fatal card-mode logs now retain only lifecycle state, consumed VERIFY budgets,
remaining count and cleanup status; no PIN, touch coordinates, APDU body or
card attributes. A failed authenticated capture no longer automatically resets
the board to post-verify Flash. Existing failed artifacts remain unchanged.

Attempt 4 could not acquire the exclusive serial lease because the separate
native-console `live-04` capture owned it; no installation or card operation
was performed by attempt 4. The existing owner was not interrupted.

## Attempt 6: observed parser failure after one local submission

`card-overview-00c0871-timeout-6` started as a no-input timeout observation.
The user reported touching the device during this run. Retained metadata shows
one four-digit VERIFY, `fault=10` (malformed), no attributes displayed, terminal
power-cut cleanup 2, VBUS OFF and erased 1. No display DMA failure was observed.
The Input Support remaining count before entry was 3; Surface remaining was 10.
The 480-frame count-only swap test passed with zero VERIFY before local entry.
The timeout hypothesis was not tested by this run; it is not classified as an
idle cancellation. Exact failing parse stage was absent in this old firmware.

A synthetic FF10 EF0001 response reproduces `Missing` in the old number parser.
The new parser handles that primitive TLV, rejects ambiguous values and checks
the check digit before constructing any Surface credential. This is a concrete
reproduced defect consistent with the physical malformed outcome, not yet proof
of its exact physical stage. The new phase receipt will distinguish Input
Support attribute, number and portrait failures without logging values.

Host tests also prove that a valid four-field read followed by photo parse
failure remains private until successful cleanup, can then display just the
four fields, and is erased on cancellation/dismissal. Failed cleanup or
physical disconnect cannot publish that partial result. The one-shot budgets
and no-retry rules remain unchanged.
