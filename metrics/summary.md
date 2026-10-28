# Project metrics

| Physical source lines | nihos | meos |
|---|---:|---:|
| implementation | 6,721 | 43,390 |
| tests | 1,934 | 4,967 |
| tooling | 1,203 | 2,943 |
| probes | 261 | 0 |
| vendored | 0 | 103,756 |
| generated | 0 | 101,738 |

Physical lines include comments and blanks. Test-code volume is not execution coverage.

## nihos

Commit: `6d267a5ddc8d27ec34c494df9fcf9c5165bcc2c2`; working tree dirty: `True`; UTC: 2026-10-25T13:17:14.507509+00:00.
Measured source fingerprint: `5728906f96fee085531c75fa34ac2f32e5aa67c1c3f6bfcc41cb861d33a72217`.

| Area | Implementation | Tests | Tooling |
|---|---:|---:|---:|
| build.zig | 0 | 0 | 20 |
| compat | 996 | 0 | 0 |
| include | 172 | 0 | 0 |
| probes | 0 | 0 | 0 |
| src | 5,553 | 1,739 | 0 |
| tools | 0 | 195 | 1,183 |

Host Zig emitted implementation line coverage: **96.3% (447/464)**.
14 files represented; 22 src/ files unrepresented.
Only DWARF lines emitted in the Debug host test binary are in the denominator.
Uncompiled functions/files, C/assembly, emulator and physical-device execution are outside this percentage.

## meos

Commit: `5d82fc19e99a7b52d72826cb577c269fdd41fe9a`; working tree dirty: `True`; UTC: 2026-10-25T13:17:14.774508+00:00.
Measured source fingerprint: `0c6066ef90d8676bff683277ca13094c2f31bd49f17f487fd216cbbd54489880`.

| Area | Implementation | Tests | Tooling |
|---|---:|---:|---:|
| apps | 2,595 | 72 | 0 |
| components | 141 | 0 | 0 |
| drivers | 9,824 | 0 | 0 |
| fs | 1,765 | 337 | 0 |
| hal | 4,825 | 0 | 0 |
| kernel | 6,240 | 713 | 0 |
| third_party | 0 | 0 | 0 |
| tools | 0 | 3,845 | 2,943 |
| user | 18,000 | 0 | 0 |

Execution coverage: **unavailable** (not zero).
