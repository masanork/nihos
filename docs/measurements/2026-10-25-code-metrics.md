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

## Interpretation and evidence

This is a local working-tree comparison on 2026-10-25, including untracked and
modified non-ignored source, not a comparison of releases or clean commit trees.
Concurrent native-bootstrap work was continuing in nihos. The nihos `src/`
bytes were frozen from the Linux collector's input snapshot at approximately
22:12 JST; tooling was copied into the isolated snapshot shortly afterward.
The reported commit is the base revision, not a claim that all measured bytes
are committed. Per-file hashes are in `build/metrics/final/current.json` and
`comparison.json`; compact aggregates are retained alongside this record.
The frozen measured nihos sources are also archived locally at
`build/metrics/nihos-source-snapshot.tar.gz`.

MeOS has about 6.5 times the implementation volume of this nihos snapshot.
Its `user/` tree alone is 18,000 lines. The projects have different features
and platform boundaries: nihos is still at native-runtime/bootstrap stage,
whereas MeOS includes applications, a GUI, filesystems, networking, interpreters
and multiple board backends. These counts do not establish language efficiency,
performance, equivalent functionality or maturity.

MeOS's vendored source and generated/font/image/dictionary data are deliberately
separate. Counting them as project implementation would overwhelm the comparison.
The complete scope and filename exceptions are in `metrics/README.md`.

Local validation completed:

- Zig host tests: all 51 pass on Linux ARM64, both directly and under kcov v43.
- macOS Debug and ReleaseSafe host build/test gates pass.
- ZLint, Zig formatting, ShellCheck and RV32 architecture compile checks pass.
- The C/Zig/Rust ABI probe passes.
- All nine metrics and publication regression tests pass, including stale-main
  and concurrent-push cases against disposable local bare repositories.
- Actionlint accepts the updated hosted workflow.

The host coverage result is 447/464 emitted implementation lines (96.3%) across
14 represented files. Uncompiled functions and hardware-only source are outside
that denominator; high host emitted-line coverage is not whole-kernel coverage.
MeOS tests were not rerun or instrumented, so its execution coverage is unavailable.
The initial charts are a local baseline. The new GitHub Actions workflow,
remote publication and target/physical execution were not run by this metrics change.
