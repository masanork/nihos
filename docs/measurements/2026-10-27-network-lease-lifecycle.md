# Native network lease lifecycle and retry checkpoint

2026-10-27. Lease renewal, rebinding, expiry and reconnect are implemented for
the normal-boot owner. The fixed 120-second limit is removed in source.
**Successful physical renewal and AP recovery remain unqualified**: the saved
AP was unavailable during this run. The earlier integration's 20/20 IPv6
Echo result is a different candidate and does not qualify these changes.

## Verified implementation behavior

- Debug and ReleaseSafe suites: 281/281 passed each.
- Tests cover T1/T2 wire fields and timing, stale XID/server rejection,
  lease-clock restart on ACK, invalid T1/T2 preserving the old lease, expiry
  and NAK clearing both families, retained T1 output replaced at T2, and ARP
  acknowledgement separated from DHCP acknowledgement under backpressure.
- Format, ZLint, shellcheck, RV32 architecture probes, 21 normal / 5 C6 image
  audit tests and six native ELF audits passed.
- Eight normal-boot emulator cases passed with networking disabled. They do
  not emulate the C6 or qualify physical renewal.
- Combined diagnostic and normal images built and passed the existing image
  auditor without reducing the 48 KiB SRAM heap floor.

## Physical observations and failed acquisition

P4 rev1.3 and existing factory C6 firmware; application-only writes at
`0x10000`, verified before boot. No C6, bootloader, partition-table or SD
write, and no full-flash backup per the user's instruction.

Attempt 01 ran 200 seconds with the diagnostic image. It never acquired an
address, so no renewal or planned post-readiness reset occurred. The owner
retried with increasing delays while display frames, both scheduler counters
and three injected serial UI controls continued. Attempt 02 added retained
failure fields and confirmed `disconnect_reason=201`, `WIFI_REASON_NO_AP_FOUND`
in the pinned SDK. The Mac was on a different IPv4 network from the earlier
successful AP session. No network selection or router settings were changed.

| Attempt | Image SHA-256 | Serial log SHA-256 |
| --- | --- | --- |
| 01, 200s, no acquisition | `bae45c700965f5765b6e82040693962fb362ccdc36f7be5f7408a693dd7dc883` | `3dd133c4d42f0a844f9a1cb362082d5ca2c0271054912f5043c3cd33405a8011` |
| 02, reason diagnostics | `74f8ff38db7c787f47fddf2c6e6ffb010ee98482a842685cf9747806899256bf` | `c8b015bef07dd6ee3ce8ac828c6b7a31b4c4a22612569c7aab5197faccac6558` |

Private candidate snapshots, receipts and logs are under
`build/wifi-device/renewal-01/`. Subsequent source changes preserved the
failed candidates separately. The latest normal build disables the diagnostic
renewal/reset injections. See [ADR 0046](../adr/0046-native-network-lease-lifecycle.md)
for the implementation contract and build flag.

## Required next physical checks

Enable the configured AP or provide an updated private Wi-Fi configuration.
Observe a matched real renewal ACK, revoke/re-acquire after the controlled C6
reset, and confirm continued Echo/UI progress beyond the former 120-second
limit. Also retain natural T1/T2/expiry, AP-disappearance/reappearance,
long-duration loss/latency and cold power-cycle gates. The diagnostics' early
renewal would not substitute for natural T1/T2 timing. MicroSD arbitration,
application sockets, complete MLD/NUD/SLAAC lifetime maintenance, and global
IPv6 connectivity remain outside this checkpoint.

## Final normal image: AP-absence qualification only

Attempt 03 retained an immutable normal-image snapshot and ran 135 seconds.
The diagnostic early-renewal and reset injections were compiled out. The
existing normal-boot/display checker passed unchanged. The final records
showed six retries and seven `NO_AP_FOUND` failures, zero acquired addresses,
zero renewal ACKs, frame counter 32 → 7,832, both scheduler counters
15 → 13,020, and three accepted serial display controls. Retry/UI progress
continued beyond the former 120-second boundary. This proves neither
successful association nor successful recovery after a connected session.

- Application: 154,416 bytes; SRAM heap: 53,632 bytes.
- Bin: `6ace7cc67f3173095a3301b066cde37315c55233891f9504f2e89fc241e6d354`
- ELF: `23aff517c3705b4dacf05003e9904215f8123ac3f9a56174abd41e0a98750ed1`
- Serial log: `3a87bdf166f47dd1d9fddc95aea42e48ed9b47152c27412e657c04bf053f1480`
- Maximum observed owner poll: 6,975 us, not a worst-case or IRQ bound.

All 250 source-snapshot hashes and all retained artifacts matched the normal
build receipt. Private `candidate-normal-final/`, `display-result-03.json`
and `ap-absence-result-03.json` bind this observation to its exact image.
`candidate-diagnostic-final/` is built/audited but not physically qualified.
The board is left running the normal retrying image; no successful network
result is claimed until its AP becomes available. Physical key presses,
optical quality and cold power cycles were not tested here.

`NIHOS_NATIVE_NETWORK_TEST=1` without networking was also verified to fail
before compilation. The ordinary build defaults to `network_test=false`.
