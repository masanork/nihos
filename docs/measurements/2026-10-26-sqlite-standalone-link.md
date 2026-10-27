# Local-only C compatibility and standalone RV32 SQLite link

- Date: 2026-10-26
- Base: `65b5d240c5f770864e8c1167c6368893b8fceb58`
- [ADR 0041](../adr/0041-minimal-c-runtime-and-standalone-sqlite-link.md)
- [Source hashes, exact link reports and local logs](2026-10-26-sqlite-standalone-link.json)

## Result and limits

Both ILP32 and ILP32F now produce a symbol-closed SQLite/session ELF, retaining
SQLite REAL support and the full session API. These use a synthetic linker map,
not the ESP32-P4 image layout. No target ELF was executed and no native firmware
was changed. No CRT/boot/stack initialization is supplied, so the ELF must not
be treated as a flashable application.

| ABI | Executable sections | Read-only sections | Total executable + read-only | Data/BSS |
| --- | ---: | ---: | ---: | ---: |
| ILP32 | 540,550 B | 55,148 B | 595,698 B | 269,320 B |
| ILP32F | 540,560 B | 55,148 B | 595,708 B | 269,320 B |

The writable count includes the oracle's explicit 262,144-byte heap backing
array. The remaining 7176 bytes include SQLite, session, VFS, ledger and heap
state. This is not a native SRAM budget: worker/interrupt stacks and real native
memory/scheduling state are absent, and the production pool will have a different
backing allocation. File/debug size is not used as the Flash measurement.

The 274-byte compatibility object adds seven byte/string primitives and fabs;
its data size, calls and undefined imports are zero. Zig compiler_rt supplies
memory primitives and software arithmetic. The ELF includes oracle/allocator,
runtime, C session and VFS code; the table is not SQLite-only attribution.
Unreachable public APIs such as backup/complete are removed: 193 SQLite public
symbols present in its object are absent from the final link. Most parser/query
machinery remains. Linker GC does not turn this into a small SRAM-only library.

Both complete symbol tables have zero undefined entries, independently checked
with pinned Espressif nm. The link auditor checks soft/single-float ELF flags,
ordinary REAL public prototypes, required actual implementations and absence
of ordinary allocator/localtime/gmtime/strftime definitions. Both disassemblies
contain no ECALL instructions; the compatibility objects contain no calls.
The first audit overlooked localized compiler_rt symbols, which was corrected
to inspect local and global definitions; this was not a target-link failure.

## Executed host evidence

- 4096 differential byte/string cases match host libc. Nine binary64 bit cases
  preserve payloads while clearing signs. ASan/UBSan pass; Clang static analysis
  emits no diagnostics for the new compatibility source.
- The same fixed-context link oracle executes sixteen host cycles. It checks
  SELECT 42, REAL multiplication cast to integer, the Unix epoch, the UTC leap
  day 2000-02-29, NULL for the unavailable localtime modifier, semantic shutdown
  and full heap recovery.
- The TLS task-owner oracle with the actual compatibility functions and UTC-only
  SQLite passes the original 308-point allocation-failure sweep and session
  321-point failure/retry sweep, including wrong-owner refusal, progress budget,
  actual pthread cancellation, stale tokens and retired-owner fail-stop.
- The fixed oracle is deliberately not the native scheduler: it models one
  stable context with a real task ledger and 64 KiB configured pool. Its host
  execution proves neither target calling conventions in execution nor native
  interrupt/PSRAM behavior.
- ShellCheck, formatting and ZLint pass for the added scripts/oracle. Previously
  validated kernel and log-validator code is unchanged and was not retested
  solely to increase test counts.

## Policy and reproducibility

The source archive remains the checksum-pinned official SQLite 3.54.1 with no
modifications. These candidate builds preserve THREADSAFE=0, ZERO_MALLOC,
OS_OTHER, memory temp state, 1024-byte pages, and the existing omitted lookaside,
WAL, loadable-extension and automatic-initialization configuration. They add
SQLITE_OMIT_LOCALTIME while preserving REAL types. Header declarations come
from the pinned Zig package; no musl runtime is linked or copied.

C is compiled at -Oz, freestanding, with builtins/PIC/stack protector/unwind
metadata disabled and function/data sections enabled. Zig uses the existing
safe mode and its bundled compiler_rt. The complete six-function session API
is retained as explicit roots alongside the returning oracle entry.

```sh
sh tools/run-c-runtime-test.sh
# Requires the already-verified SQLite source cache from the preceding host probe:
sh tools/probe-sqlite-rv32-link.sh
```

The preceding `65b5d24` object snapshots are retained separately under
`build/qualification-rv32-object-65b5d24/`. Their reports were regenerated using
the committed inspector and unchanged object bytes, checked against the prior
recorded report hashes, then archived. New working reports do not replace that
historical evidence. Current exact ELFs, objects and link reports remain under
`build/sqlite-link/`.

The local ordinary-CI workflow contains new sanitizer/link steps for the next
push; it has not run remotely for this change. No push or CI dispatch was made.
The next integration gate is actual native code/data placement with the real
owner allocator and startup path, followed by local target execution and
Native CI. Runtime stack, cache-off/Flash rules, native f64/FP context behavior
and physical validation remain separate gates. No native SQLite support or
persistent storage result is claimed here.
