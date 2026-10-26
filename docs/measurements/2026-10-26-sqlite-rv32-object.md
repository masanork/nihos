# Local-only SQLite RV32 object and runtime inventory

- Date: 2026-10-26
- Base: `67e16e62b51061bff54234e543ae8a9546c128ec`
- [Source/object/ABI evidence](2026-10-26-sqlite-rv32-object.json)
- Reproduce: `sh tools/run-sqlite-memory-probe.sh`, then
  `sh tools/probe-sqlite-rv32.sh`.

## Scope

These are relocatable compile-only RV32 freestanding objects. They are not
linked into the firmware, run in ESP-EMU or executed on a device. Zig 0.17.0's
pinned musl headers provide C declarations only; no musl runtime is linked or
vendored. The SQLite archive/extracted files are checked against the existing
published SHA3-256 before compilation. Optimization is `-Oz` with independent
function/data sections and no stack protector/PIC/unwind tables. No unreferenced
section elimination is performed, so these are not final executable sizes.

The current native firmware inputs are unchanged. The host SQLite build now
sets `SQLITE_ZERO_MALLOC=1`: the default allocator is a failing stub, while the
explicit configured task allocator remains active. This removes ordinary
malloc/free/realloc/calloc fallback references from all four object inventories.
The original 308-point and owner-session 321-point OOM/retry suites, plus the
normal non-test executable, pass locally with that option. The configured
profile remains a 50,640-byte request / 65,536-byte parent.

## Controlled variants

All four builds use the same SQLite 3.54.1 source, zero/default allocator policy,
OS_OTHER, THREADSAFE=0, memory temp state, 1024-byte pages and the existing
lookaside/WAL/extension/autoinit exclusions. One axis is RISC-V ILP32 versus
ILP32F. The other preserves SQLite REAL support versus adding
`SQLITE_OMIT_FLOATING_POINT`.

| ABI / SQL policy | SQLite executable sections | SQLite read-only data | SQLite writable data/BSS |
| --- | ---: | ---: | ---: |
| ILP32 / REAL retained | 533,102 B | 55,058 B | 6841 B |
| ILP32F / REAL retained | 533,074 B | 55,058 B | 6841 B |
| ILP32 / FP omitted | 516,444 B | 54,191 B | 6481 B |
| ILP32F / FP omitted | 516,444 B | 54,191 B | 6481 B |

The owner-session object adds 1914 executable, 90 read-only and 40 writable
bytes in all four variants. Its future runtime needs are not covered by those
static bytes. The ABI fingerprint is 44 read-only bytes. These numbers count
all allocated object sections, including currently unreferenced APIs; do not
add them to a running image or claim they are linker-GC measurements.

## ABI and unresolved runtime requirements

Compile-time RV32 fingerprints show: pointer/long 4 bytes, SQLite allocator
method table 32 bytes, VFS 88 bytes, scalar result 16 bytes with value at offset
0 and presence flag at offset 8. Every object has the expected ELF soft/single-
float ABI bits for its variant. A header probe independently detects the types
of `sqlite3_column_double` and the VFS `xCurrentTime` callback.

The omitted-FP option rewrites floating public declarations to integer types
while the SQLite header is parsed, then undefines the temporary macro. As a
result, mixing ordinary consumer/VFS declarations with an omitted-FP engine is
not an interchangeable build. The current no-I/O VFS is not adapted to that
variant and is not included in these objects. No ABI call execution is claimed.
The default host/session build continues to retain REAL support.

Omitting FP reduces this object's executable sections by only about 16.6 KiB
and does not remove all soft-double helpers. The inventory still includes
conversion/comparison/multiply helpers and gmtime/strftime. REAL-retaining
builds require additional arithmetic/conversion helpers, fabs and localtime.
This argues against treating the option as a simple native-fit fix. A coherent
numeric/VFS contract and linked measurements must precede choosing it.

After subtracting definitions provided by the SQLite/session/ABI objects,
remaining external symbols include:

- The explicit nih_task identity/allocator API and sqlite3_os_init/os_end.
- Bounded implementations of memory/string primitives, including memcpy,
  memmove, memset, memcmp, memchr, strcmp/strncmp, strlen, strchr/strrchr and
  strspn/strcspn.
- RISC-V software arithmetic helpers and the time/math functions noted above.

The remaining per-variant symbol sets are in the JSON. Complete section tables
are retained under each build directory, with report digests in the aggregate JSON. All twelve object inventories
were independently compared with the pinned Espressif toolchain's nm output.
Some dependencies can disappear at final link if all referring sections are
unreachable; this inventory is not a proven minimal runtime closure.

## Next local/native gates and CI cadence

Local investigation can continue through a bounded C runtime/VFS adapter,
relocatable/final link experiments, host fault tests and emulator regressions
without pushing every small stage. A main push automatically starts ordinary
CI; it should verify accumulated changes and the Linux environment before the
publication is considered validated. This local-only change has not been
published and has no fresh remote-CI claim.

Native CI is useful when a batch changes native build inputs, image/linker
layout, code placement, traps/timers/ownership or target execution. It is not
needed solely because this separate object probe or host SQLite option changed.
Linking SQLite into the actual native ELF, or expanding the two-function Flash
execution whitelist, is the next clear Native-CI checkpoint. At that point
measure final dead-stripped code, SRAM/PSRAM, stack and executed ABI behavior.
A physical test remains a separate gate for real cache/timing/storage behavior.

For the preceding published base, both
[ordinary CI](https://github.com/masanork/nihos/actions/runs/40282027577) and
[Native boot](https://github.com/masanork/nihos/actions/runs/40282089637) succeeded.
Those results cover that exact commit, not this unpublished follow-up.
