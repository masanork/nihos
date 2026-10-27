# Native BMI270 acquisition: physical checkpoint

2026-10-27, isolated `codex/tab5-native-imu` worktree based on main `51da82e`.
Normal native Tab5 boot now uploads the licensed BMI270 configuration and
continuously reads all six accelerometer/gyroscope axes. Earlier main only
identified the chip. See [ADR 0048](../adr/0048-native-bmi270-acquisition.md).

## Candidate and device boundary

- ESP32-P4 revision 1.3, 32 MiB PSRAM, ST7121 panel; rediscovered on the attached
  Tab5, with expected identity and one factory application at 0x10000/1 MiB.
- Application: 159,888 bytes; SHA-256
  `0c0ac924ae5779183be5f17a8f00dafb801bef532a6a1ca75167c26d27e499fa`.
- Primary SRAM heap: 56,192 bytes; unchanged minimum 49,152 bytes.
- Mapped non-executable Flash tables: 54,270 bytes, including the 8,192-byte
  Bosch base configuration. No extra mapping or heap-floor reduction.
- The retained bootloader differs from the newly built loader. Its exact bytes
  matched the retained card-service loader, and the candidate was audited using
  that loader's ELF and configuration before installation. No loader update
  was needed.
- Before writing, the first 64 KiB and existing 1 MiB app partition were backed
  up privately. The installer compared both again under its exclusive serial
  lease before replacing only the factory app. Candidate bytes were verified
  before captures and after all three runs; the first 64 KiB remained unchanged.
  Partition table, C6 firmware and SD were not written.

Exact source-manifest digest, ELF/image hashes, log hashes, parsed readings,
display/CPU progress and private artifact paths are in
[the structured receipt](2026-10-27-native-imu.json). Source files and candidate
artifacts are hashed in the retained `candidate/network-receipt.json`.

## Physical results

The same installed candidate passed three 40-second USB-reset captures.
Every reset soft-resets the IMU before configuration, so a previous initialized
sensor cannot stand in for a successful new upload.

| Check | Result |
| --- | --- |
| Chip / completed configuration | 0x24 / all 8,192 bytes on each boot |
| Initialization, configuration and power readback | Passed each boot |
| Fresh readings in periodic diagnostic snapshots | Seven valid snapshots per run, after initial startup |
| Sample count in those snapshots | 7→1206, 7→1206, 9→1208 |
| Acceleration magnitude across snapshots | Approximately 0.979–1.044 g |
| IMU transport/sensor fault | Zero in every capture |
| Shared RTC/INA226 I2C errors | Zero in every capture |
| Display / CPU0 and CPU1 timer counters | Continued increasing in every capture |
| BLE discovery | Seven acknowledged commands and clean scan stop each run |

Both sensors are configured at nominal 100 Hz; these are sensor output
settings. The observed host acquisition rate is roughly 40 bursts/s, sharing
the normal loop with display, C6 and other board work. Each burst contains all
six signed axes. This is not a lossless 100 Hz stream or a calibrated motion
service. No operator movement was requested during capture; no controlled
orientation/gyro-response claim is made.

Wi-Fi remained explicitly unconfigured, acquiring no IP address; no private
Wi-Fi credentials were used. This test qualifies shared C6/BLE operation, not
AP traffic coexistence. Existing RTC date validation still rejected the
board's invalid weekday; the test did not write or repair RTC time.

The IMU checker requires complete upload, no fault, strictly advancing sample
counts, both data-ready flags, signed 16-bit axis values and repeated plausible
gravity magnitude. The existing normal-boot display/core checker passed each
capture separately. Optical appearance is not evaluated by either checker.

## Host and build validation

- Debug and ReleaseSafe Zig suites: 369 passing tests reported in each run.
- Python regression suite: 203 tests passed, including negative controls for
  stale/incomplete/faulty IMU evidence, mixed boots and malformed records.
- Format, ZLint, ShellCheck, RV32 RTC/IMU/network code generation and all six
  existing native ELF image audits passed.
- The normal connected device build and both new/retained loader audits passed.
- The configuration upload model checks all bytes and the pinned SHA-256,
  word-address increments, one-transfer budget, waits measured from transfer
  completion, signed extrema, failed readback, data-ready gating and failure
  invalidation.

## Retained failed attempts

Host development first exposed a private fake-bus method, an unconverted fake
clock argument, a Mach-O-incompatible ELF-only data section, and the analyzer's
failure to count `builtin` inside a section annotation. These were corrected;
native data remains in mapped Flash and host data uses the platform's proper
read-only section. Enlarging the existing board diagnostic schema also exceeded
its compile-time branch quota; a separate IMU record avoided changing that quota.

Read-only device preflight initially tried a ROM flash read without the stub,
then correctly rejected a nonmatching new loader, and finally attempted to load
the flasher stub twice. No firmware was written by those attempts. The corrected
preflight used one stub, rediscovered the matching retained loader, saved the
original app and rebooted. Failed logs remain under `build/imu-qualification/`.

## Remaining gates

Controlled movement, gyro bias/calibration, sensor-to-display axis mapping,
FIFO/IRQ acquisition, application input/IPC and physical fault injection remain.
Long-duration operation, active Wi-Fi traffic and cold power-on are separate
tests. This exact candidate has no optical confirmation. The final installed
app remains the audited normal IMU candidate; the prior app is backed up.
