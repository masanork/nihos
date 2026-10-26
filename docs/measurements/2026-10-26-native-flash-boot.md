# Native whitelisted Flash boot code

- Date: 2026-10-26
- Zig 0.17.0, ESP-IDF v5.4.4 loader only, ESP-EMU 0.50.0
- [Source manifest, image audits and exact case evidence](2026-10-26-native-flash-boot.json)
- [ADR 0033](../adr/0033-whitelisted-flash-boot-code.md)
- Reproduce: `sh tools/run-native-smoke.sh compiled 32M` and `sh tools/build-native.sh device compiled`.

## Result

Two CPU0 boot functions now occupy 4,280 bytes of executable/read-only Flash
at `0x40000120..0x400011d8`: PSRAM discovery/setup and mapping preparation.
The probe obtains a PC inside its own function; populated cases also return
a PC inside the mapping function. Absent cases require a zero mapping PC.
Each case's log validator checks those PCs against the individual function
ranges from that saved ELF, plus one completed boot record. The compiled
32 MiB example recorded probe `0x40000180` and mapping `0x40000d1e`.

Both functions run before CPU1 release and scheduler timers. Existing
instruction audits prohibit FP instructions in the moved code and reject
any other Flash function. The entry, trap path, ongoing task/scheduler and
allocator code, stacks, ordinary constants and mutable state remain resident.
No Flash controller initialization, erase/program, Flash MMU0 replacement,
cache resize, frequency change or new ROM ABI was introduced.

## Net footprint

Both revision profiles have the following relative sizes. Comparison uses
the six recorded audits for baseline `fad25f6`; its evidence path/digest is
retained in the JSON and it was not rebuilt for this comparison.

| Mode | Previous static SRAM | Current static SRAM | Net reduction | Internal heap | Margin above 48 KiB gate |
| --- | ---: | ---: | ---: | ---: | ---: |
| Integer | 108,288 B | 104,320 B | 3,968 B | 59,520 B | 10,368 B |
| Raw FP | 112,448 B | 108,352 B | 4,096 B | 55,488 B | 6,336 B |
| Compiled FP | 112,832 B | 108,736 B | 4,096 B | 55,104 B | 5,952 B |

Net reduction includes added PC capture, report fields/output, alignment and
the expanded normal record table. The table grew from 1,986 to 2,068 bytes,
with FNV-1a `0x18b8402d`; both harts' initial/final reads match their ELF.
The app image grew from 67,600 to 67,680 bytes. Its first mapped image segment
now holds 256 descriptor bytes followed by 4,280 code bytes; boot instructions
start at image offset 288, physical Flash `0x10120` for the factory app offset.
Adjacent ELF sections merge into that one image segment. Exactly two external
mapped image segments remain, with table data at image offset `0x10020`.

Resident regions remain 160 KiB, the heap minimum 48 KiB, bootstrap/interrupt
stacks four times 8 KiB and worker stacks two times three times 4 KiB. Safe
compilation, task quotas, cache geometry and clock policies remain. No SRAM
bank was added. After existing boot-fixture allocations and guards, internal
free space per owner was 29,184 bytes in integer, 27,136 in raw FP and 26,944
in compiled FP. The gain is capacity, not a performance measurement.

## Qualification

All nine final emulator cases passed: integer with absent/4/8/16/32/64 MiB,
raw FP without a die, and compiled FP with absent/32 MiB PSRAM. They retained
the complete 300-round scheduler/FP/lifecycle/forced-exit, IPI-only idle,
SRAM, PSRAM/cache/command, heap recovery and task-pool checks. Every saved
ELF/app pair passed auditing again; each report's ELF digest matches its
saved executable, and each saved image's allocated ELF contents match the
final image of its mode. Runtime SRAM owner spans match their audited heaps.

Six profile images passed full loader/configuration/image auditing, and
nine case snapshots retain their exact ELF/app/merged image/layout/audit and
log/report. First-segment boot bytes must match the ELF, both descriptors
must select 64 KiB MMU pages, and mapped offsets must remain congruent.
ZLint, ShellCheck and six architecture ELF/instruction audits passed.

All 75 Python tests passed: 60 log, 13 image and two compiler tests. Five
new tests cover missing/duplicate/incomplete boot evidence, absent/populated
mapping rules, PCs outside their audited function role, unexpected/duplicate
Flash functions, invalid RX/page bounds and overlapping/unaccounted extents.
The unchanged 119-test host suite's Debug and ReleaseSafe commands succeeded
using their valid cached results; these host modules do not execute native
Flash fetches. Native execution evidence is the distinct emulator matrix.

## Evidence boundary

Baseline ordinary CI and
[Native boot](https://github.com/masanork/nihos/actions/runs/40259528989)
both succeeded. Current remote CI remains separate from these local results.
No physical device was accessed. Captured PCs and section/symbol checks are
fixture evidence, not a general call-graph or executable-attestation proof.
General service code in Flash, cache-off SMP coordination, erase/program,
physical instruction-fetch timing, cache eviction, power and DMA behavior
remain separate work. No game FPS or latency improvement is claimed.
