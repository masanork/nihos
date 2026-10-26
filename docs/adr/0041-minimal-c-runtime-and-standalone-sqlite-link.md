# 0041: Minimal C compatibility and symbol-closed SQLite link oracle

Status: accepted for local host tests and standalone RV32 linkage; native image
integration/execution remains unqualified, 2026-10-26.

## Runtime boundary

Use the pinned Zig 0.17.0 compiler_rt for memcpy, memmove, memset, memcmp,
strlen and software arithmetic, rather than implementing another copy. Add
original allocation-free C implementations for memchr, strcmp, strncmp, strchr,
strrchr, strspn, strcspn and binary64 fabs. They add no heap, locale, OS calls,
mutable globals or interrupt masking. Standard C caller requirements still
apply: buffers must be readable and strings NUL-terminated. Work scales with
the input; these are not constant-time or independently length-validating APIs.

Comparison/search uses unsigned bytes and converts int search arguments to
unsigned char. strchr/strrchr can return the terminator. fabs clears only the
IEEE binary64 sign bit, preserving zero, infinity, subnormal and NaN payloads.
Compile-time checks require the binary64 format. The compatibility object is
compiled freestanding with builtins disabled; both target objects contain no
calls or undefined symbols, preventing recursive libc lowering.

Host tests use prefixed names so the comparison library remains independent.
4096 generated string/byte cases are compared with host libc, including empty
strings/sets, bounded comparisons, high bytes, negative/wide search arguments
and terminators. Nine raw binary64 cases check sign/payload preservation.
ASan/UBSan and Clang static analysis pass. This does not requalify all of Zig's
compiler_rt implementations; that boundary remains pinned and explicit.

## Preserve REAL; choose UTC-only for this port experiment

The preceding omitted-FP experiment changed SQLite public types while saving
little code and retaining software-double dependencies. This experiment keeps
ordinary REAL declarations and SQL arithmetic. It instead compiles SQLite with
SQLITE_OMIT_LOCALTIME and SQLITE_ZERO_MALLOC. UTC date calculations remain in
SQLite; OS localtime/gmtime/strftime and ordinary malloc/free/realloc are absent
from the closed links. This is a port-fixture policy, not a new system clock or
time-zone implementation. In this configuration the localtime modifier returns
NULL. No automatic fallback to a host/board time API is supplied.

The no-I/O VFS still provides deterministic time/randomness and denies files.
It remains a fixture. Native SQLite needs a production platform/VFS contract.

## Closed link, separate from native boot

A fixed single-context oracle uses the real buddy heap, task ledger, configured
64 KiB pool, C allocator adapter and session implementation. It has its own
256 KiB backing array. Host execution performs sixteen full initialize/query/
shutdown cycles and checks complete heap recovery. Queries verify 42, REAL
arithmetic, UTC epoch/leap-day conversion and the omitted-localtime result.
The TLS owner oracle separately runs the original 308-point and session
321-point OOM/retry/cancellation suites with the new compatibility functions
and UTC-only engine.

ILP32 and ILP32F links include SQLite, the complete six-function session API,
the compatibility module, VFS, fixed oracle, ABI fingerprint and Zig compiler_rt.
Linker GC removes unused SQLite APIs. Both linked ELFs have zero undefined
symbols; independent Espressif nm checks agree. Disassembly contains no ECALLs.
This is a structural observation, not an execution or security proof.

The linker script uses synthetic code/data windows, has no board MMU layout,
image header, CRT/BSS/stack startup, interrupt vectors or stack reservations.
Its returning entry is for linking and host comparison, not booting. No binary
was flashed, no target ELF executed, no native linker/Flash whitelist modified,
and no new remote CI run. A closed link does not qualify native task ownership,
preemption, f64 helpers, stack bounds, PSRAM/cache behavior or physical timing.

## Publication gate

The local ordinary-CI workflow now includes the compatibility sanitizer test
and synthetic RV32 link probe. Those steps execute only on the next publication;
local success is not Linux-CI evidence. Actual native image integration/code
placement is the later Native-CI checkpoint, followed by distinct physical
qualification. The existing native memory and two-function Flash boot policies
remain unchanged.

[Measurement and source binding](../measurements/2026-10-26-sqlite-standalone-link.md).
