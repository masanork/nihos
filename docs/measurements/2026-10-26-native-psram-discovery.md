# Native PSRAM command discovery qualification

- Date: 2026-10-26
- Zig 0.17.0, ESP-IDF v5.4.4 loader only, ESP-EMU 0.50.0
- [Source hashes, image digests and eight complete smoke reports](2026-10-26-native-psram-discovery.json)
- [ADR 0024](../adr/0024-bounded-native-psram-discovery.md)
- Reproduce with `sh tools/run-native-smoke.sh integer 32M`; select the other sizes explicitly.

## Result

The independent native app reads PSRAM mode-register pairs through a Zig
MSPI3 command engine before CPU1 starts. Four bounded reads repeat the
configuration and identity pairs. No ROM SPI routine or linked IDF PSRAM
runtime is used. Both mode-register capacity and subsequent native runtime
behavior were checked:

| Emulator selection | Configuration pair | Identity pair | Detected bytes | Full native fixture |
| --- | --- | --- | ---: | --- |
| Absent | `0x0000` | `0x0000` | 0 | Pass in integer, raw FP and compiled FP modes |
| 4 MiB | `0x0d00` | `0x00c9` | 4,194,304 | Pass in integer mode |
| 8 MiB | `0x0d00` | `0x00cb` | 8,388,608 | Pass in integer mode |
| 16 MiB | `0x0d00` | `0x00cd` | 16,777,216 | Pass in integer mode |
| 32 MiB | `0x0d00` | `0x00cf` | 33,554,432 | Pass in integer mode |
| 64 MiB | `0x0d00` | `0x00ce` | 67,108,864 | Pass in integer mode |

Each of the eight runs required 300 scheduler rounds, task lifecycle and
preemption checks, 64 ordered IPI/idle exchanges in each direction, unchanged
timer counts in that interval, SRAM guards/patterns and final FP accounting.
The compiled mode retained 503 / 469 timer captures inside generated FP
task code. Integer mode still copied no FP banks. No external memory region
was mapped or allocated in any run.

## Failure and resource evidence

All 67 host tests passed in Debug and ReleaseSafe. The added register model
checks delayed completion at the poll boundary, a stuck transaction, refusal
to reuse a timed-out controller, busy ownership, invalid register/empty
budget, stale FIFO and changing identity. Decode tests cover both supported
vendors and all five densities, absent responses and unsupported/bad-die
fields. These are protocol/state tests, not electrical timing simulation.

All 33 Python native-validator tests passed. The added gates require the
explicitly requested emulator capacity, matching vendor/good-die/density,
four reads and zero mapped/allocatable bytes. ZLint, ShellCheck and six
native ELF architecture/instruction audits passed. Six complete Flash
images were built and audited; the two known ROM symbols are unchanged.
Twenty-eight selected MSPI/clock/reset/CS definitions were checked to agree
between the pinned revision-1 and revision-3 register headers.

| Resource, either revision profile | Integer | Raw FP | Compiled FP |
| --- | ---: | ---: | ---: |
| Static SRAM reservation including stacks/alignment | 94,464 B | 97,664 B | 97,792 B |
| Internal runtime heap span including guards | 36,608 B | 33,408 B | 33,280 B |
| Remaining SRAM per owner after fixture allocations | 17,728 B | 16,128 B | 16,064 B |
| App image | 65,616 B | 65,616 B | 65,616 B |

Static reservation grew by 2,688 bytes per mode relative to ADR 0023's
fixture. Discovery runs before the SMP workload, adding no PSRAM work to
the trap path. These sizes and progress counts do not measure physical
allocation latency, PSRAM bandwidth or Quake performance.

## Remaining gates

The source manifest records the parent commit and changed file SHA256
values; artifact hashes identify the six image pairs and eight logs. Remote
CI is separate evidence. The preceding main commit
`5343fd3bc64aef581f320e482cf5d3eecfaf63d9` passed both ordinary CI and
[Native boot](https://github.com/masanork/nihos/actions/runs/40207107770);
that success does not qualify this change.

No physical device was accessed. The experimental XTAL/2 command setup
does not yet include native LDO channel 2 / 1.8 V supply startup, eFuse
calibration, MPLL/DLL tuning or board power qualification. There were no
device-mode writes, command-data round trips, address-alias checks,
MMU/cache mappings, external allocator registration or DMA tests. Detected
mode-register capacity is deliberately distinct from usable memory.
