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
