# Native PSRAM supply and command-data qualification

- Date: 2026-10-26
- Zig 0.17.0, ESP-IDF v5.4.4 loader only, ESP-EMU 0.50.0
- [Source hashes, image digests and nine complete smoke reports](2026-10-26-native-psram-command-data.json)
- [ADR 0025](../adr/0025-native-psram-supply-and-command-data.md)
- Reproduce with `sh tools/run-native-smoke.sh integer 32M` and `sh tools/run-native-smoke.sh compiled 32M`.

## Result

The native boot now programs and reads back LDO channel 2, waits on a leased
1 MHz timer, identifies the die, programs/verifies its initial x8 modes and
performs bounded command-data writes/reads. All nine emulator runs completed
this boot stage and the subsequent 300-round scheduler/lifecycle fixture,
SRAM ownership checks, 64 IPI/idle exchanges per direction and FP accounting.

| Selected die | Sample addresses | Writes / reads | Total commands | Modes tested |
| --- | ---: | ---: | ---: | --- |
| Absent | 0 | 0 / 0 | 4 | Integer, raw FP, compiled FP |
| 4 MiB | 22 | 44 / 44 | 101 | Integer |
| 8 MiB | 23 | 46 / 46 | 105 | Integer |
| 16 MiB | 24 | 48 / 48 | 109 | Integer |
| 32 MiB | 25 | 50 / 50 | 113 | Integer, compiled FP |
| 64 MiB | 26 | 52 / 52 | 117 | Integer |

For each complementary pattern, all sampled addresses were written before
any were verified. The set includes zero, each word-aligned address-line
power of two, and the final word. All detected devices read back MR0=0x28,
MR4=0x40 and MR8=0x0b. Counts include four repeated discovery reads, nine
mode transactions and four data transactions per address. Absent devices
received only the four discovery reads, with no mode/data writes.

Every run read back the owned supply fields as control `0x180`, analog
`0x66800000`, selecting nominal DREF=6/MUL=5 and ripple suppression. The
emulated eFuse fixture selected the nominal path; complete versioned factory
trim selection was exercised by host tests. The settling interval completed
and CPU0's timer was returned/reloaded before scheduler startup.

The populated compiled-FP case retained 500 / 482 captures inside generated
task code on CPU0 / CPU1, with matching FP saves/restores and final FS=Off.
Integer tasks retained zero FP bank copies. No PSRAM work was added to the
trap path and no CPU-accessible external region was registered.

## Host and structural checks

All 75 host tests passed in Debug and ReleaseSafe. Added cases cover VO2
trim fallback/selection, preservation of unrelated PMU bits, dropped power
register writes, exact command phases, lost device-mode writes, every
sampled address-line alias on the 32 MiB model, corrupted data, poisoned
data-transfer timeouts and the final valid/outside/misaligned word boundary.
These are register/controller-policy models, not analog or cache models.

All 38 Python native-validator tests passed. New gates reject missing or
duplicated supply/data records, bypass/inconsistent supply fields,
incomplete mode/data counts and data writes to an absent die. ZLint,
ShellCheck and six native ELF instruction/layout audits passed. Six full
Flash images were also built and audited. Fifteen selected PMU/eFuse supply
definitions agreed between the pinned revision-1 and revision-3 headers.

| Resource, either revision profile | Integer | Raw FP | Compiled FP |
| --- | ---: | ---: | ---: |
| Static SRAM, stacks/alignment included | 100,992 B | 104,192 B | 104,320 B |
| Runtime heap span, internal guards included | 30,080 B | 26,880 B | 26,752 B |
| Free per owner after SRAM fixture allocations | 14,464 B | 12,864 B | 12,800 B |
| App image | 65,616 B | 65,616 B | 65,616 B |

Static reservation grew by 6,528 bytes per mode over the discovery-only
fixture. This includes boot qualification and reporting code; the chosen
128 KiB internal window and stack reservations did not grow. This is a
footprint measurement, not a PSRAM bandwidth or Quake FPS result.

## Evidence boundary

The JSON records changed source/workflow hashes and the parent commit,
plus the six image pairs and nine log digests. The preceding main commit
`d76fec43d98d8fd275acf5def187aefde22f186a` passed ordinary CI and
[Native boot](https://github.com/masanork/nihos/actions/runs/40208331945);
that result does not qualify this change. Remote CI is separate evidence.

No physical device was accessed. Programming/readback and an elapsed boot
delay do not qualify analog voltage or board power timing. Sparse command
samples do not establish full memory integrity or retention. CPU MMU/cache
access, cross-core PSRAM visibility, x16/high-speed MPLL/DLL tuning, external
allocation and DMA remain separate gates. All mapped/allocatable PSRAM
counters remained zero.
