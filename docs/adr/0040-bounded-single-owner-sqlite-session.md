# 0040: Bounded single-owner SQLite memory session

Status: accepted as a host-qualified prototype; native linkage, service task
and application RPC are not implemented, 2026-10-26.

## One global owner before entering SQLite

`src/services/sqlite_session.c` owns one SQLite memory connection and all its
statements. It records `nih_task_identity()` before configuring/initializing
the THREADSAFE=0 library. Every normal entry rejects a different task before
calling SQLite. A nonblocking atomic gate also rejects concurrent/reentrant
entry. Open, allocation callbacks, evaluation, close and shutdown all run in
the owner context. No database/statement or borrowed result pointer escapes.
The source must be linked with a dedicated SQLite instance: direct calls into
that same library from other code would bypass this contract.

`sqlite3_mem_methods` uses the bounded C allocator. The wrapper detects a pool
it did not open and leaves it intact after a failed startup. Normal shutdown
requires all live library blocks to be freed before closing its parent. Failed
cleanup preserves owner/fault state rather than authorizing a new owner.
Killing the owner releases its task resources but leaves SQLite global pointers
invalid. A later generation cannot enter, close or reopen that state; restart
is required. This is fail-stop handling, not transparent library recovery.
A killed task with the gate held also leaves the service unavailable.

## Finite requests and copied results

The internal C header exposes open, eval and close. The caller supplies a
readable SQL span of 1..512 bytes containing exactly one statement and trailing
whitespace only. A request returns at most one integer/null scalar, copied
into caller-owned result storage. More rows/columns, text/blob/FP results and
writes with RETURNING rows fail. RETURNING is rejected before execution, and
oversized results are never partially published. Error returns do not promise
the transaction-level atomicity of an arbitrary SQL operation.

SQLite limits text values to 2048 bytes, SQL to 512 bytes, columns to 16,
expression depth to 16, compound SELECTs to four and variables to 16. Attached
databases are disabled. The memory DB uses 1024-byte pages and max_page_count=16.
Defensive mode is enabled, trusted-schema mode is off, and an authorizer rejects
caller PRAGMA/ATTACH/DETACH so requests cannot lift those policies. The column
limit must allow SQLite's own schema tables: an initial limit of four caused
schema setup failure and was corrected to sixteen. These are prototype limits,
not a complete untrusted-query security policy or application capability model.

The no-I/O fixture VFS is shared with the original allocator probe. It rejects
file paths/opens and supplies fixed time/randomness. It is not a production
VFS or entropy source. Persistent storage, durability and Flash pause/resume
are not exercised.

## Progress budget and cancellation

A progress callback checks cancellation every 100 VM instructions and interrupts
after 100,000 callback invocations. This is an operation-budget mechanism, not
a measured wall-clock deadline or a complete bound on parser/allocator time.
A successful later query is required after either budget interruption or cancel.

Each evaluation publishes a nonzero, monotonically increasing u32 token.
Tokens persist across session close/open and never wrap: exhaustion rejects
new evaluations while still allowing close. A trusted control-plane caller
can discover the active token and cancel it using atomics only; it never calls
sqlite3_interrupt or touches a cross-task SQLite pointer. A delayed store for
an old token cannot cancel a later token. Cancellation racing completion is
best effort; successful publication does not promise interruption of an already
finished query. Token discovery/cancel is internal, not a permissioned app API.

## Memory policy and evidence

The longer recursive query exposed exhaustion of the 128-byte class with the
previous forty-cell profile. Increase that class to 64. The current experimental
profile is `24,12,16,12,64,4,8,12,8,1`, requesting 50,640 bytes within the same
64 KiB buddy block. Other quotas remain unchanged. The original simple workload
still reports a 27,456-byte peak; that is not the session prototype's peak.
Per-class peaks for all possible SQL or OOM paths are not claimed.

The original 308-point allocator OOM/retry sweep passes for both equal quotas
and the configured profile. The session's 321-point sweep covers initialization,
scalar queries, schema creation, transaction/rollback, close, full recovery and
successful retry. Additional host tests cover wrong-owner open/eval/close,
pre-existing-pool preservation, request/result limits, forbidden configuration,
VM-budget interruption, actual pthread cancellation and recovery, stale tokens,
token exhaustion, and owner retirement followed by fail-stop refusal. A separate
executable tests the normal build with injection hooks compiled out. Clang's
static analyzer reports no diagnostics for the session source.

Native firmware still links only the allocator/identity C probes. The complete
nine-case emulator matrix and six device/emulator builds qualify that boundary;
they execute no SQLite. Host pthread evidence is not native SMP SQLite evidence.
There is no physical-device access or native library footprint/timing result.

## Following gates

Before a native service can be claimed: port the required C runtime and VFS,
choose and audit general service-code placement, measure the final RV32 library,
stack and allocation distribution, add a bounded owner mailbox/admission policy,
and define service failure/cancellation capabilities. Persistent use additionally
requires storage-owner integration, VFS fault injection, Flash/cache coordination
and physical recovery/power tests. The existing two-function Flash boot whitelist
is unchanged. No hardware settings, partition layout or upstream sources changed.

[Measurement and aggregate verification](../measurements/2026-10-26-sqlite-owner-session.md).

References: [SQLite initialization/shutdown](https://www.sqlite.org/c3ref/initialize.html),
[run-time limits](https://www.sqlite.org/c3ref/limit.html).
