# Default connectivity and board devices: physical checkpoint

2026-10-27. Branch based on main `1f43a4d`. This is controller/discovery and
register-level evidence, not GATT/HID, wall-clock, audio or complete device
qualification. See [ADR 0047](../adr/0047-default-connectivity-and-board-devices.md).

## Candidate and write boundary

The attached P4 was rediscovered as revision 1.3 with its expected identity.
The partition table was read and checked: one factory app, 0x10000/1 MiB,
no OTA slots. Only that application was written, with readback verification.
Bootloader, partition table, C6 firmware and SD were not written. Full backups
were skipped as the user requested. Factory C6 Hosted 1.4.1 was retained.

Private artifacts, source receipts, flash logs and serial captures are under
`build/device-check/` in the isolated worktree. Configuration and nearby BLE
addresses/payloads are absent from tracked files. Advertisement counts are
reports, not counts of distinct devices.

| Physical candidate | App SHA256 | Capture SHA256 |
| --- | --- | --- |
| Configured `configured-final`, 65 s | `781b1c2663e73a975a30567777e41e7c0389616ff56bb59c0d6d474a4ee88971` | `664b59ff72a7e0fb49b360da169b9800c054fce16d81b43fa198d05394c0a328` |
| No configuration `unconfigured-final`, 35 s | `b6ed837be58e65f7052c67d5d74477695e16410bdab0861c75bb20c8d0b1e132` | `78878c583dce199d8b4d423c3e5738405d1a1ee33a2d379732bb260aaa32aab2` |

## Results

- Configured Wi-Fi associated, acquired a real DHCPv4 address, and completed
  IPv6 link-local initialization. Acquisitions=1, reconnects=0, failures=0.
  This run does not retest natural renewal, peer Echo or global IPv6.
- BLE completed seven successful HCI commands: initialization, passive legacy
  scan, and scan disable after ten seconds. Configured run: 95 HCI events,
  88 advertisements, zero malformed events/rejections/timeouts. Scan finished
  in idle, not merely an unacknowledged stop request.
- Without Wi-Fi credentials, the normal public build still started the driver,
  finished BLE discovery with 275 advertisements, and acquired no Wi-Fi
  address. Station settings remained explicitly unconfigured.
- The configured run's display counter advanced 32 -> 3633; each CPU's timer
  counter advanced 15 -> 6018. The unconfigured run also retained display and
  dual-core health. Existing core/memory/display startup and IRQ checkers
  passed both captures. Optical appearance is not evaluated by these checkers.
- RX8130CE responded and its raw seconds advanced. Existing date registers
  read `40 08 05` (year/month/day BCD), with weekday `0x14`, which has two bits
  set. The calendar was correctly rejected; it was not changed or published
  as valid wall time. Flags=0x25, control=0. Calendar set/recovery remains
  host-tested and RV32-codegenerated, not physically exercised here.
- INA226 manufacturer/die ID matched; the final configured sample reported
  8,255,000 microvolts bus voltage. Calibration was not changed. No amperes or
  state-of-charge claim follows from the raw shunt result.
- BMI270 chip ID 0x24 responded, with internal initialization status false.
  No accelerometer/gyro acquisition claim follows from identity readout.
- Board polling finished with zero I2C transaction errors in both final runs.

## Failures retained and corrected

The first 65-second unconfigured candidate booted without a system fault but
all sensor reads failed and HCI Reset appeared to time out. Its app SHA was
`dca8b91d56b8b08f1c73f3bc6e7387d52b0739b8d42233701ddd6b74628bf3ed`,
log SHA `cfe6d4d653d89140ad23b28adf184a437b126535c234895ef9c901102a830dc7`.

The C6 power shim left the shared I2C output latches high. The Zig master
uses output-enable around a low latch; releasing the bus and restoring low
latches at handoff fixed all three device reads. Runtime bus recovery/reset
was not introduced.

The later `unconfigured-02`/`configured-02` candidates verified I2C and Wi-Fi
but FeatureControl RPC timed out. The exact 1.4.1 registry source, commit
`ee11e08c`, established that it enables Bluetooth at boot and has no such RPC.
It also showed that RX H4 stays inside the SDIO payload while TX moves its
packet type into the header. The final version-specific initialization and RX
normalization produced the successful discovery above. C6 firmware was not
replaced to obtain that result.

## Automated evidence and remaining gates

292 Debug and 292 ReleaseSafe host tests passed, including settings ownership,
unconfigured version fallback, HCI framing/credits/command correlation/scan
stop, advertisement validation, RTC invalid-date/BCD/VLF/STOP checks and
calendar-write failure handling. The 168 Python regressions and static gates
(format, ZLint, shellcheck, owner/RTC RV32 code generation, six audited native
ELF profiles) passed. The public normal device build passed image auditing;
configured heap retained 49,856 bytes, above the unchanged 48 KiB floor.

There is no GATT peer or BLE keyboard attached. Connection/security/HID reports,
C6-resident host offload, RTC calendar setting/backup/wakeup, IMU configuration,
audio/camera, and shared microSD transport arbitration remain explicit work.
