# Native full-capacity mapping and external boot arenas

- Date: 2026-10-26
- Zig 0.17.0, ESP-IDF v5.4.4 loader only, ESP-EMU 0.50.0
- [Source hashes, six image audits and nine smoke reports](2026-10-26-native-external-arenas.json)
- [ADR 0027](../adr/0027-native-external-boot-arenas.md)
- Reproduce: `sh tools/run-native-smoke.sh integer 4M` and `sh tools/run-native-smoke.sh compiled 32M`.

## Layout and allocation

The native runtime maps the full detected capacity using a bijective page
permutation. The first 192 KiB retains the nonidentity CPU/command test
windows. The remaining virtual tail is divided between two guarded arenas;
its usable capacity excludes four 64-byte guards. SRAM and PSRAM use the
same owner-local implementation, with an explicit allocation API for each
domain and no fallback, shared heap lock, free or reset.

Integer-mode emulation produced these results:

| Die | CPU mapped | Registered external capacity | Free after fixture allocations |
| --- | ---: | ---: | ---: |
| Absent | 0 | 0 | 0 |
| 4 MiB | 4,194,304 B | 3,997,440 B | 3,734,400 B |
| 8 MiB | 8,388,608 B | 8,191,744 B | 7,928,704 B |
| 16 MiB | 16,777,216 B | 16,580,352 B | 16,317,312 B |
| 32 MiB | 33,554,432 B | 33,357,568 B | 33,094,528 B |
| 64 MiB | 67,108,864 B | 66,912,000 B | 66,648,960 B |

All nine complete smoke cases passed: integer with absent/4/8/16/32/64 MiB,
raw FP without a die, and compiled FP without a die and with 32 MiB.
Each completed 300 scheduler rounds, lifecycle, IPI/idle, FP and both memory
domain gates. These are execution/resource results, not bandwidth or FPS
measurements. The JSON binds changed source hashes and artifacts to parent
commit `32fde0f00dd8fc379012575add386a732232eed7`; remote CI is separate.
That parent passed both ordinary CI and
[Native boot](https://github.com/masanork/nihos/actions/runs/40243878948).
Those remote results qualify the parent, not this change.

Each populated boot retains the earlier 36 CPU checks, 36 physical-command
checks, 72 commands and five cache operations before CPU1 release. Both
bootstraps then check 3,072 words over 64 rounds; CPU0 verifies the final
48 reply words through physical commands. CPU1 remains parked while CPU0
finishes those checks and initializes external owners and guards.

Each owner consumes 131,520 external bytes: a 64-byte bootstrap allocation
and two 65,728-byte worker allocations. The latter cross 64 KiB pages and
are filled under timer preemption. Workers sample patterns continuously;
after retirement, every allocated byte, alignment and guards are checked.
Invalid length/alignment/oversized requests must preserve capacity and MIE.
The absent case also attempts and rejects external allocation.

An exploratory run failed because CPU1's internal completion was published
before its longer external scan. The validator rejected the zero external
record. External verification/publication now precedes internal completion,
so CPU0's existing acquire wait covers both domains.

## Host and structural verification

All 87 host tests passed in Debug and ReleaseSafe. The added page-plan test
requires a bijection at every supported capacity, with displaced pages and
no aliases. A late PTE fault must revoke the complete map. The existing
cache model still separates CPU and physical views and injects missing
writeback/invalidation, identity translation, cache rejection and command
failures. These tests verify protocol/translation, not analog behavior.

All 48 native Python tests passed. New cases reject missing/duplicate owners,
reserved-page overlap, incomplete tail coverage, incorrect allocation or
guard accounting, incomplete worker checks and external records without a
die. ZLint, ShellCheck and all six architecture ELF audits passed. All six
full Flash images were also built and audited.

## Internal SRAM footprint

Both revision profiles produced the same resource sizes:

| Mode | Static SRAM including stacks | Internal heap span | Free per owner after SRAM fixture |
| --- | ---: | ---: | ---: |
| Integer | 96,512 B | 34,560 B | 16,704 B |
| Raw FP | 99,840 B | 31,232 B | 15,040 B |
| Compiled FP | 100,096 B | 30,976 B | 14,912 B |

Sharing domain operations and keeping diagnostic print/hex routines out of
line reduced code duplication. The smallest internal heap grew from
16,896 to 30,976 bytes despite adding external ownership state. The 128 KiB
SRAM window, four 8 KiB bootstrap/interrupt stacks, worker stacks and 16 KiB
minimum heap gate remain unchanged. Every app image is 65,616 bytes; exactly
six documented ROM symbols remain allowed/required. No IDF application
runtime, FreeRTOS, DMA or PSRAM trap-path access was added.

## Evidence limits

No physical device was accessed. Emulation, PTE readbacks and sparse data
checks do not qualify every PSRAM cell, real coherency, voltage/timing,
retention, DMA, x16 or high-speed MPLL/DLL operation. Cache ROM routines
still contain waits without a nihOS software timeout. This is monotonic
boot allocation rather than a reusable C/SQLite heap. Application lifetimes
and a free-capable allocator are subsequent work.
