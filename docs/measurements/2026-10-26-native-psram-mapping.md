# Native PSRAM mapping, cache bridge and cross-core qualification

- Date: 2026-10-26
- Zig 0.17.0, ESP-IDF v5.4.4 loader only, ESP-EMU 0.50.0
- [Source hashes, six image audits and nine complete smoke reports](2026-10-26-native-psram-mapping.json)
- [ADR 0026](../adr/0026-native-psram-mapping-and-cache-handoff.md)
- Reproduce with `sh tools/run-native-smoke.sh integer 32M` and `sh tools/run-native-smoke.sh compiled 32M`.

## Result

Every populated run mapped the first, middle and final physical PSRAM pages
into three consecutive 64 KiB virtual windows. All 1,024 MMU1 entries were
written/read back; only those three pages were valid. The middle/final
translations are nonidentity mappings, so flat RAM backing cannot stand in
for the MMU. No external allocator was registered.

| Selected die | Reserved CPU mapping | CPU/command checks | Cross-core result | Task modes |
| --- | ---: | --- | --- | --- |
| Absent | 0 | Skipped | Skipped | Integer, raw FP, compiled FP |
| 4 MiB | 192 KiB | 36 / 36 | 64 rounds | Integer |
| 8 MiB | 192 KiB | 36 / 36 | 64 rounds | Integer |
| 16 MiB | 192 KiB | 36 / 36 | 64 rounds | Integer |
| 32 MiB | 192 KiB | 36 / 36 | 64 rounds | Integer, compiled FP |
| 64 MiB | 192 KiB | 36 / 36 | 64 rounds | Integer |

Each populated boot checked both CPU-to-command and command-to-CPU data
visibility across line/page boundaries using writeback/invalidation. Its
mapping phase completed 72 physical commands and five cache operations.
Both bootstraps then checked 3,072 PSRAM payload words each over 64
request/reply rounds. After CPU1's external accesses ended, CPU0 wrote back
and verified the final 48 reply words using physical commands.

All nine cases subsequently completed the existing 300-round scheduler,
lifecycle, SRAM ownership, IPI/idle and FP gates. The populated compiled-FP
case retained 484 / 493 captures inside generated task code on CPU0 / CPU1.
Integer mode retained zero FP copies. These are execution checks, not
hardware bandwidth or Quake FPS measurements.

## Cache model and ABI evidence

All 85 host tests passed in Debug and ReleaseSafe. The added model keeps
physical memory and CPU cache contents separate. Suppressing writeback or
invalidation, ignoring the PTE translation, dropping a PTE write, rejecting
a cache operation or failing a physical command all prevent qualification
and revoke the mapping. Tests also cover invalid ranges/cache geometry,
plaintext/encryption-counter selection and rejection of live remapping.

All 43 native Python validator tests passed. The new gates require complete
mapping and cross-core records, exact checked-entry/cache/command counts,
zero failure diagnostics and no mapped accesses for an absent die. Known
capacity alone cannot pass. ZLint, ShellCheck and all six architecture ELF
audits passed. Six full Flash images were built and audited.

The cache boundary uses the official ROM entry points for L2 line size,
enable, invalidation and writeback. Together with console output and CPU1
entry publication, exactly six ROM symbols are allowed and required by the
ELF audit. Twenty-four selected MSPI2 definitions agreed across revision
headers; all four cache ROM addresses agreed across the pinned ROM linker
maps. No ESP-IDF application runtime or C cache implementation was linked.

Direct cache-register setup initially failed its readback check at
`0x3ff10274` in ESP-EMU. Those exploratory attempts were not passing runs.
The accepted boundary follows the ROM API used by the official LL layer.
The ROM routines' internal waits do not have a nihOS software timeout;
physical cache timing/hang behavior remains a separate gate.

## Resources and remaining gates

| Resource, either revision profile | Integer | Raw FP | Compiled FP |
| --- | ---: | ---: | ---: |
| Static SRAM, fixed stacks/alignment included | 110,848 B | 114,176 B | 114,176 B |
| Runtime internal heap span, guards included | 20,224 B | 16,896 B | 16,896 B |
| Free per owner after SRAM fixture allocations | 9,536 B | 7,872 B | 7,872 B |
| App image | 65,616 B | 65,616 B | 65,616 B |

The 128 KiB window and stack reservations are unchanged. The smallest heap
span is only 512 bytes above the 16 KiB linker gate, so further native code
needs footprint/layout work alongside full-capacity external allocation.
Boot command primitives are shared through explicit non-inlining; no PSRAM
operations were added to the trap path.

The JSON binds results to changed source/workflow hashes and the parent
commit. The preceding main commit
`7d741ae6e2257014ad9260d824fd098964bc7df6` passed ordinary CI and
[Native boot](https://github.com/masanork/nihos/actions/runs/40209801087);
that result does not qualify this change. Remote CI is separate evidence.

No physical device was accessed. Emulation and the cache model do not
qualify silicon coherency, analog voltage, power timing, retention, DMA or
x16/high-speed MPLL/DLL operation. Only the reserved 192 KiB test windows
were mapped; general external allocation remained zero. All remaining
detected capacity and physical qualification are subsequent work.
