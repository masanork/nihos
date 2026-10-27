# Finite native audio output: physical controller checkpoint

2026-10-28 JST. Local `codex/tab5-native-audio`, based on main `734e89e`.
The IMU change is already merged as PR #8, and its post-merge checks passed.
This checkpoint covers a separate, opt-in ES8388/I2S0/AHB-DMA output fixture.
It does **not** qualify audible sound or a normal application audio service.
See [ADR 0049](../adr/0049-native-audio-output-probe.md).

## Main integration follow-up

After main advanced to `2a5d353` (foreground-card startup fix), the audio branch
merged it and rebuilt the opt-in image. `attempt-10` verified application SHA-256
`da929550d09110953a4b0989717874f2602dea1fd01dd328221c925ae1e4b145`
before and after a 35.058-second warm-reset capture. DMA flags 0x0b, BCLK
262,145, FIFO 16,384, final descriptor 0x4ff1b6b0 and stable phase 7/fault 0
matched the earlier controller result. Parked, codec-off, stopped and returned
were all 1. Core/display and continuing-IMU checkers passed; I2C errors were 0.
The 49,856-byte primary heap and 704-byte margin above the floor are unchanged.
The exact previous 1 MiB app was restored and verified; the first 64 KiB was
unchanged. Audible confirmation is still **not received**.

The [retained UART capture](evidence/2026-10-28-native-audio-main-followup/serial.log),
image audit, checker reports and before/after/restoration verification records
are source-bound by `main_followup` in the JSON receipt. Private Flash backups
are excluded. The source archive records the build inputs before the later
checker/documentation changes; those changes do not alter firmware bytes.

CI exposed an unrelated evidence-capture defect: emulator stderr INFO messages
could split the UART CRT-pass line when both streams shared a file. The runner
now retains stdout UART and stderr diagnostics separately, hashes both streams,
and checks only UART. All eight local normal-boot smoke cases then passed,
including absent/4/32/64 MiB PSRAM, delayed CPU1 and three expected failures.
The checker still rejects incomplete guest records; no parser repair fabricates
a pass from interleaved text. Updated host suites and 209 Python regressions
passed, along with static analysis and the positive/negative audio-shim builds.
The audio checker also now explicitly rejects a missing/invalid parked receipt.

## Initial candidate and physical result

The initial qualified candidate in `attempt-09` is SHA-256
`51f89b7c662afc80f2310863d7f9594a12446bcc5fee2336b66f1a1e65684ce0`.
Its primary heap is 49,856 bytes; the existing 49,152-byte floor was not changed.
Only 704 bytes of additional resident headroom remain above that floor in this
opt-in profile. The default audio-disabled connected image retains 56,128 bytes.

| Observation | Final result |
| --- | --- |
| Format / nominal rate | Philips I2S, 16-bit stereo / 16 kHz |
| Finite PCM plan | 8192 frames, nominal 512 ms, 1 KiB immutable PCM + 512 B descriptors |
| DMA raw flags | 0x0b: total EOF, EOF and done; no descriptor-error bit |
| Final EOF descriptor | 0x4ff1b6b0, matching the last of 32 linked slots |
| I2S BCLK counter | 262,145, consistent with 8192 × 32 clocks plus final edge |
| I2S FIFO sample counter | 16,384, consistent with both channels of 8192 frames |
| Final DMA descriptor FSM | Parked |
| Shutdown / ownership | Codec mute/power-off confirmed, DMA stopped, descriptor ownership returned to CPU |
| Later snapshots | Stable completed state, fault 0 |
| Core/display/IMU regression | Existing normal-boot display/core checker and continuing-acquisition IMU checker passed |
| Shared board I2C | Zero transaction errors |
| BLE | Discovery and acknowledged scan stop completed without HCI errors |
| Wi-Fi | Explicitly unconfigured; no AP-traffic qualification |

The corrected preceding `attempt-08` also completed with the same transfer
counters and clean shutdown, but has a different exact application hash. It is
retained as an earlier success, not relabeled as a second final-candidate run.
Neither run has operator confirmation of audible output. Programmed sample
rate and hardware counters are not a measured analog-frequency or volume test.
No microphone audio or card credentials were captured.

## Device and restoration

The attached Tab5 was rediscovered as ESP32-P4 revision 1.3. Its loader had
changed since the earlier IMU test. The first read-only preflight rejected that
mismatch before writing. The actual bytes then matched the frozen card-notice
loader, and all later candidates were audited against its ELF/configuration.

One exclusive serial descriptor covered each install, capture and restoration.
Before a write, the current first 64 KiB and factory app partition (1 MiB at
0x10000) were backed up privately. Only the app partition was replaced. Candidate
bytes were checked before/after the capture; the original full app partition
was then restored and verified, and the first 64 KiB was compared unchanged.
The final installed firmware is the prior card-test image, not the audio probe.
Loader, partition table, C6 firmware and SD were not written.

When another card-removal test acquired the port, the audio capture rejected
the busy lease and waited until that owner released it. It did not terminate
or take over the other process.

## Defects exposed and corrected

1. **Reserved codec bit:** CONTROL2 register 1 returned 0x40 after a request to
   write 0x00. The earlier whole-byte readback check stopped before DMA start.
   Configuration now preserves reserved bits and checks documented writable
   fields. A host regression retains reserved bit6 while changing analog fields.
   Amp-off/mute/DAC power-down still completed on those rejected candidates.
2. **Wrong DMA block:** AHB-DMA had been incorrectly assigned DW_GDMA's
   0x50081000 base. An access exception initially reported a later trap-prologue
   PC. Added stage markers and `mtval` localized the bad read to 0x500810e0.
   The official peripheral linker script and `DR_REG_AHB_DMA_BASE` establish
   0x50085000. The corrected alias and compile-time guard use one shared macro.
   Compiling a negative control with 0x50081000 now fails that static assertion.
3. **Shared pin mux:** GPIO26/27 also serve the unused FS-OTG PHY. Their proper
   GPIO mux handoff now temporarily clocks the wrapper, releases its analog pad
   mux through the vendor LL helper, and restores the previous clock gates.
   GPIO24/25 diagnostic serial pins and GPIO28 microphone data are untouched.

Failed builds, read-only preflights, codec failures, native exceptions and the
busy-port attempt are retained separately. No failed or mixed candidate is
included in the successful transfer receipt.

## Automated evidence and remaining gates

Debug and ReleaseSafe Zig host suites reported 377 passing tests each, with the
independent CCID test also passing. Python regressions passed 206 cases.
Formatting, ZLint, ShellCheck, the six existing native ELF audits, and both
audio-disabled/opt-in device image audits passed. The wrong-base compile was
rejected as expected. The audio evidence checker rejects partial FIFO/clock
counts, incomplete EOF, codec faults, native traps and missing stop/ownership
receipts. A generic native boot PASS does not qualify this probe.

[The JSON receipt](2026-10-28-native-audio.json) contains exact image/ELF,
source archive and log hashes, device counters, earlier failure records and
private artifact paths. The captured source archive corresponds to the bytes
used for that candidate; later documentation/build-check additions do not alter
the tested application.

Audible confirmation, analog sound/clock measurement, headphones, clicks,
cold power-on, repeated/reopen playback and sustained streaming remain separate
gates. ES7210 recording, a mixer and application audio IPC are not implemented.
Normal builds keep the fixture disabled.
