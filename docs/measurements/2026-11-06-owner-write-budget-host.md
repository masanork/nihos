# Trusted owner integration for experimental write budgets

The serialized checkpoint-service owner now exposes trusted `beginBudgeted`
and `releaseBudget` scheduler hooks. They are not client RPC operations.
Admission requires the exact live client, an unexhausted sequence, no pending
request, and empty request and response queues. Release requires the same
client and drained queues after the store has published its budgeted
transaction. `Store` continues to enforce the page-write and index-peak limits.
Both hooks currently perform synchronous full-volume free-space scans. They do
not provide bounded latency, native scheduling or asynchronous DMA/drain proof.

A client exit during unpublished staging rolls back when synchronous callbacks
have returned and no failure requires recovery. A published but unreleased
budget instead fences the owner: rebind and new owner initialization on that
instance are rejected. This includes a lost commit reply. A fresh recovered
store and a fresh admission are required. Draining a local response queue is
not an end-to-end receipt proving that an application observed the response.
I/O failure during budget admission or post-commit release also immediately
fences the owner. An allocation denial before publication can be canceled and
rolled back; a budget overrun or unknown I/O outcome is conservatively fenced.

Host tests exercise wrong-client and exhausted-sequence rejection, queued
requests and replies, staged write/sync, release only after queue drain,
rollback on client exit, lost reply, stale rebind, admission and release read
failures, prepublication allocation denial, and budget exhaustion. The fault
campaign injects a 31-byte torn write at 66 modeled write/sync events with two
writeback policies (132 cases), requiring owner fencing and old-or-new data
after fresh recovery. This is a host model, not physical media qualification.

The RV32 service probe compiles the two hooks with explicit externally supplied
media callbacks. It does not run them or prove task/IPC ownership, cache or DMA
safety, callback draining, stack sufficiency, or actual media persistence.

This work does not connect the hooks to SQLite or WAL. The budgets are not a
transaction-wide WAL, checkpoint and GC planner; no WAL shared-memory,
locking, reset or replay semantics are implemented here. The full-volume scan
and volatile hold remain unsuitable as the final GB-scale admission mechanism.
Next work must add incremental, cancellable admission and post-commit recovery
with a durable/revalidated reservation contract, then bind the native service
and SQLite VFS under a single audited owner before SD or power-loss trials.
