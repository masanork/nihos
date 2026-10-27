# Native finite ES7210 input and muted control

2026-10-28 JST, based on main `64c67d6` after merging audio PR #10.
This checkpoint qualifies finite ADC/TDM/DMA progression and shutdown, not a
streaming recorder or calibrated microphone response. See
[ADR 0050](../adr/0050-native-finite-microphone-input.md).

## Physical comparison

Each image requested one 1024-byte capture after normal boot and a 250 ms ADC
settling interval. Four 16-bit slots gave 128 frames / 512 samples (nominal 8 ms
at 16 kHz). PCM was analyzed locally only after DMA ownership returned, then
zeroed with checked cache writeback. Raw audio was not logged or saved.

| Observation | Unmuted input, attempt-05 | Muted control, attempt-04 |
| --- | --- | --- |
| Application SHA-256 | `a69445830749ac448de38bba8bed4a0ca3f10a96eb58c2f860abe9535193b657` | `1666d0dd7bedda2d1ce5a8eefac35ff01627b91655999e3e1749208ecaa1ac2e` |
| Capture time | 35.038 s warm USB reset | 35.072 s warm USB reset |
| DMA raw / final state | 0x03 (done + successful EOF), phase 5, fault 0 | Same |
| Successful EOF descriptor | 0x4ff1b280 | 0x4ff1b240 |
| Samples / final descriptor | 512; ownership CPU, length 1024, EOF set | Same |
| Parked / ADC off / stopped / returned / erased | All confirmed | All confirmed |
| Raw slot peaks | 17408, 119, 64, 203 | 0, 0, 0, 0 |
| Raw slot spans | 17497, 119, 85, 55 | 0, 0, 0, 0 |
| Varying slots / clipped samples | 4 / 0 | 0 / 0 |
| Primary heap | 49472 B, 320 B above existing floor | 49536 B, 384 B above floor |
| I2C errors | 0 | 0 |
| Core/display and continuing IMU checkers | Passed | Passed |
| BLE discovery / scan stop | 20 advertisements; no HCI errors | 18 advertisements; no HCI errors |
| Display / CPU counters after capture | 1833 frames, 3018/3018 ticks | 1833 frames, 3019/3019 ticks |

The input slots vary, while the hardware ADC mute makes every reported sample
zero. This control helps distinguish ADC data from stale or floating input.
It does not establish physical mic/reference slot mapping, a known acoustic
transfer function, calibrated gain/frequency or absence of startup transients.
The large unmuted slot-0 peak is retained, not normalized away; no quality claim
is made from this uncontrolled short window. An earlier unmuted image had
peaks 61/108/45/170, but its different exact hash is not a second final run.

Wi-Fi was explicitly unconfigured; these captures do not qualify active AP
traffic coexistence. The normal display checker establishes controller/core
progress, not optical confirmation or physical touch interaction.

## Identity and restoration

ESP32-P4 revision 1.3 and its device identity were rediscovered under an
exclusive serial descriptor. Only the factory app partition at 0x10000 was
replaced. The current full 1 MiB app partition and first 64 KiB were backed up
privately before each installation. Exact candidate bytes were verified before
and after capture, then the prior app was restored and verified in full. The
first 64 KiB was confirmed unchanged; no loader, table, C6 or SD write occurred.

After attempt-01, a concurrent card test acquired the port. Attempt-02 rejected
the busy lease without accessing the device. When it became free, attempt-03
rejected a changed loader before any app write. The current bytes matched
`nihos-card-read-physical/build/card-read-main-64c67d6-frozen-01/loader`, and
attempts 04/05 were audited against that retained loader ELF/configuration.
Their prior app partition hash is
`41cace2fa1130c1820ff21036b628ed1689af836bd59462e914eba0c7857f0ca`;
the restored final device is that prior card image, not a microphone probe.

The [JSON receipt](2026-10-28-native-microphone.json) retains separate source
archives, candidate/ELF/log hashes, controls, earlier success and rejected
preflights. [Input evidence](evidence/2026-10-28-native-microphone/input/serial.log)
and [muted evidence](evidence/2026-10-28-native-microphone/muted/serial.log) include
raw UART, image audit, native options, checker reports and installation/
restoration verification logs. Flash backups and raw PCM are excluded.
Source archives describe the exact build inputs; subsequent evidence-checker
and documentation edits do not change the captured firmware bytes.

## Automated validation and limits

Debug/ReleaseSafe host suites and 213 Python regressions passed. New tests cover
reserved fields/identity and independent ADC shutdown, finite RX bounds,
descriptor owner/length/EOF checks, signed slot statistics, analog wait,
timeout/bad-EOF/DMA faults, dead clock, failed stop/mute and prohibited live-buffer
analysis/erasure. The evidence checker additionally rejects short capture,
missing cleanup/erase, malformed/mixed logs, inconsistent or clipped statistics
and using one mode as the other. CLI validation binds candidate image and mode
options to their build receipt, plus restoration and log hashes.

Formatting, ZLint, ShellCheck and the existing six native ELF audits passed.
Default connected, audio-output, microphone-input and muted-control image
audits passed. Both audio and microphone shims compile, and both reject the
wrong DW_GDMA base at the intended static assertion. CI builds and retains
both microphone modes; emulator or host checks do not qualify physical audio.

The input profile preserves the existing 49152-byte heap floor, with only
320 bytes of extra resident margin. Application recording, DMA resource sharing,
streaming/refill, AEC, microphone/reference slot mapping, known acoustic stimuli,
cold power-on, repeat/reopen operation and active AP traffic remain open gates.
