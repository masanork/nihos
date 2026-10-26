# Task-local C allocator and SQLite memory-only host probe

- Date: 2026-10-26
- [ADR 0037](../adr/0037-task-local-c-allocator.md)
- [Source hashes, six images, nine retained cases and host logs](2026-10-26-native-c-allocator.json)
- Base: `a7bc2f9ae2a57618b59e6605f3931e295e086556`

## Result

The native kernel exposes an explicit task-local C allocator with 8-byte
alignment, 8..4096-byte classes, capacity lookup and preemptible realloc.
Allocation and positive resize failures preserve old data. Metadata lookup
validates current hart/task, parent and exact cell geometry before reading
pool metadata, without dereferencing the submitted pointer. C users can write
all reported capacity bytes; moving realloc preserves them even after a shrink.

One internal-SRAM binding per task identifies its parent. Task close removes
the binding and deferred cleanup reclaims the parent without child traversal.
No per-cell SRAM table, cross-core allocator lock, libc symbol override, new
Flash execution, SRAM region, stack enlargement or hardware setting was added.
Raw pointers cannot detect stale-address reuse; lifetime discipline is required.

The isolated continuation checkout is `/private/tmp/nihos-c-allocator`.
The previous checkout was clean at the base commit. The original repository's
separate local commits and dirty metrics/book work were left untouched.

## Native and host qualification

| Check | Result |
| --- | --- |
| Host Debug / ReleaseSafe | 145 tests passed in each mode |
| C ABI host caller | Capacity-copy, OOM, invalid/interior/foreign pointers, task retirement and full recovery passed |
| Python native log/image/compiler regressions | 84 passed |
| Zig format / ZLint / ShellCheck / language ABI probe | Passed |
| Device/emulator integer, raw FP, compiled FP | Six ELF/instruction audits and six full loader/image audits passed |
| Integer emulator PSRAM | Absent, 4, 8, 16, 32, 64 MiB passed |
| Raw FP emulator PSRAM | Absent passed |
| Compiled Zig/C FP emulator PSRAM | Absent and 32 MiB passed |

Each populated hart completes two C probes; an absent-PSRAM case reports zero.
The probe checks open/close and duplicate-open refusal, null/zero and oversized
requests, exact-pointer validation, alignment, capacity, full-class OOM,
preserved usable bytes, moving and in-place resize, and fresh double-free
rejection. A retained eight-byte C allocation survives busy-worker execution
and is checked before deferred parent cleanup. Native wrapper checks also
reject malloc/capacity/free with MIE disabled. Existing typed resize, complete
300-round SMP/lifecycle, IPI/WFI, FP, stack-guard and heap recovery checks remain.

Host tests add every-class pointer geometry, wrong task/hart/storage-kind and
closing/retired parent rejection, plus poisoned metadata followed by opaque
parent recovery. The inherited typed tests cover death during pending pool
initialization or move. No claim is made that a timer interrupt or forced
termination occurred inside a particular C copy.

Initial local setup required a writable Zig global cache and
`IDF_COMPONENT_MANAGER=0` for the loader-only build: the component manager's
macOS process enumeration was unavailable. No SDK source was modified. A first
Python compiler-negative test run omitted the writable-cache environment and
failed with permission errors; rerunning with the same configured cache passed
all 84 tests. These were setup failures, not target execution evidence.

## SQLite: actual host execution only

Unmodified official SQLite 3.54.1 is downloaded to ignored `build/sqlite/`,
verified against the published SHA3-256 and compiled with:

```text
SQLITE_THREADSAFE=0 SQLITE_OS_OTHER=1 SQLITE_TEMP_STORE=3
SQLITE_DEFAULT_PAGE_SIZE=1024 SQLITE_DEFAULT_MEMSTATUS=1
SQLITE_OMIT_LOAD_EXTENSION SQLITE_OMIT_WAL SQLITE_OMIT_AUTOINIT
SQLITE_OMIT_LOOKASIDE SQLITE_ENABLE_API_ARMOR
```

Actual SQLite calls the shared C API through `sqlite3_mem_methods` callbacks.
The host backend uses the same buddy/resource/size-pool implementations but
supplies host task selection instead of native interrupts and scheduling.
One context owns initialization, connection, statements and shutdown. A test
VFS denies file opens and paths, supplies fixed randomness/time, and does no
I/O. It is not a persistent or production VFS. No native SQLite object is linked.

The workload runs `SELECT 6*7`, creates a table with 1024-byte pages, commits
two rows and verifies count=2 and aggregate text length=8. Lookaside is disabled
so these requests reach the allocator. On this 64-bit macOS ARM host:

| Metric | Observed |
| --- | ---: |
| Maximum pre-rounding request | 2048 B |
| SQLite-reported peak usable allocation bytes | 27,456 B |
| Allocation/reallocation calls in the baseline | 308 |
| Individually injected allocation failures | 308 |
| Remaining SQLite bytes after connection close | 0 B |
| Live library blocks / retained outer allocations after shutdown | 0 / 0 |

Each failure point must actually be reached once. SQLite may recover or return
NOMEM. Each run closes all statements/connections, shuts down, checks zero live
blocks and full outer recovery, then successfully repeats the entire workload.
This tests recovery for this finite sequence; it is not general SQLite fault
coverage. Normal SQLite shutdown must precede owner retirement. Force-reclaiming
the pool alone would leave global library state unusable.

## Reservation experiment

Classes are 8, 16, 32, 64, 128, 256, 512, 1024, 2048 and 4096 bytes. Baseline
peak live objects per class were respectively:

```text
21 9 14 11 35 4 6 9 5 0
```

The total request histogram was `56 29 35 24 111 7 19 21 8 0`. These peaks are
for the baseline; transient failure paths are separately exercised by the OOM
sweep. No production quota guarantee is inferred from one query sequence.

| Equal quota per class | Parent request | Outer buddy reservation | Result |
| --- | ---: | ---: | --- |
| 4 / 8 / 16 | 33,696 / 67,072 / 133,824 B | 64 / 128 / 256 KiB | NOMEM; full recovery |
| 32 / 34 | 267,328 / 284,016 B | 512 KiB | NOMEM; full recovery |
| 35 | 292,360 B | 512 KiB | Workload and 308-point OOM/retry sweep passed |
| 64 (default host probe) | 534,336 B | 1 MiB | Workload and OOM/retry sweep passed |
| 128 | 1,068,352 B | 2 MiB | Workload and OOM/retry sweep passed |

Thus a 27 KiB peak still needs a 512 KiB parent under equal quotas. The next
memory-policy experiment should use trace-informed per-class quotas and retain
adversarial failure/recovery tests. Count 35 is an observed threshold for this
host sequence, not a recommended native service budget. The host fixture itself
reserves a separate 4 MiB backing array; the table describes its live parent,
not the complete host process footprint. Native RV32 library allocation sizes,
page-cache/lookaside tuning, larger requests and query limits remain unmeasured.

## Native image footprint

The base's recorded source hashes were checked against the exact base commit;
its images were not rebuilt. Both revision profiles have these sizes:

| Mode | Previous total static | Current total static | Static growth | Internal heap | App image |
| --- | ---: | ---: | ---: | ---: | ---: |
| Integer | 123,136 B | 129,536 B | 6400 B | 91,648 B | 75,744 B |
| Raw FP | 127,168 B | 133,696 B | 6528 B | 87,488 B | 78,880 B |
| Compiled FP | 127,424 B | 133,952 B | 6528 B | 87,232 B | 79,216 B |

This growth includes C boundary code, pointer lookup, task bindings, the C test
caller and retained probe state. It is not an isolated production allocator
cost. Separate stack reservation remains 57,344 B; primary SRAM remains
163,840 B. The tightest heap has 38,080 B above the 48 KiB gate. Flash record
tables are 2464 B with FNV-1a `0x3816eb75`. SQLite contributes no native bytes.

## Reproduction and evidence limits

```sh
sh tools/run-c-allocator-probe.sh
sh tools/run-sqlite-memory-probe.sh
# Optional measured threshold, not a production budget:
sh tools/run-sqlite-memory-probe.sh 35
sh tools/run-native-smoke.sh integer 4M
sh tools/run-native-smoke.sh compiled 32M
sh tools/build-native.sh device compiled
```

The JSON binds 21 source/configuration files, the verified SQLite source/header,
host executable/object/log, six complete image audits and nine saved case
ELF/app/merged-image/layout/log/report sets. Each report's executable digest
matches its exact retained image. Case allocated contents match the final image
of its mode; full debug ELF determinism is not claimed.

Both preceding remote workflows succeeded:
[ordinary CI](https://github.com/masanork/nihos/actions/runs/40275665584) and
[Native boot](https://github.com/masanork/nihos/actions/runs/40275665578).
Current remote CI is separate from these local measurements.

No physical device was accessed. Native C ABI physical execution, PSRAM/cache
behavior, copy/interrupt latency and maximum stack use remain unqualified.
SQLite has only host memory-database evidence: native executable placement,
C runtime port, final RV32 footprint, service-global ownership/cancellation,
bounded RPC, storage VFS fault injection, Flash-pause and physical durability
remain subsequent gates. No game, storage or real-time improvement is claimed.
