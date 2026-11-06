# Opt-in write budget in the experimental checkpoint store

`beginBudgeted` scans current free payload and index space, including retained
roots and reader pins, before beginning one serialized transaction. The
caller supplies conservative limits for payload page writes, index page writes,
peak additional index occupancy, and separate payload/index margins. All
supported store writers reach the shared `writePage` gate: payload and index
writes are charged before I/O, including writes from blob streams, resize and
scattered mapped batches. Reused pages are charged again. Index peak includes
transient replacement, so repeated replacement of one staged leaf can reuse
space without reserving one distinct index page per write.

An exceeded budget or a failed allocation search poisons the transaction;
commit is refused and the caller must roll back. I/O failure fences the store
and requires a new recovered instance. Following a successful commit the
budget remains held, blocks the next transaction, and can only be released
after a fresh free-space check confirms the requested margins. The caller must
serialize all access to the store; these Zig fields and calls are not a
security boundary against an untrusted client. Existing unbudgeted operations
remain available and the native service does not use this interface yet.

The host tests cover admission overflow, pinned old roots, payload and index
underestimates, repeated index replacement, mapped and blob writes, aborted
streams, failed admission after partial staging, post-commit hold, and unknown
publication. A fault campaign injects a 31-byte torn write at 66 modeled
write/sync events under two writeback policies (132 cases), recovering old or
new committed data. This is not exhaustive media fault or physical power-loss
evidence.

The opt-in large NFST test builds on the earlier fragmented-media experiment.
It plans a payload write upper bound from the fixed batches and supplies two
index peak pages, 81 index writes, four payload margin pages and one index
margin page. A 5,129,285-byte dictionary was imported across gaps in 79 batches,
then committed, the budget held and released, and the image reopened and
verified. Actual vs admitted payload writes were 1,415/1,418; index writes were
81/81. The old objects survived and all dictionary bytes matched SHA-256.
This one workload does not establish bounds for arbitrary transactions.

```sh
.tools/zig-0.17.0/zig test -O ReleaseSafe src/storage/write_budget_test.zig
NIHOS_NFST_PATH=/path/to/jisyo-l_nfst.bin \
  .tools/zig-0.17.0/zig test -lc -O ReleaseSafe \
  src/storage/fragmented_large_host_test.zig --test-filter 'large NFST staged'
```

This is an experimental physical-page budget, not a complete reservation
contract for SQLite WAL or SD. Admission currently scans the volume, which is
not a practical GB-scale free-space index. The budget does not reserve a
contiguous extent or promise success under every fragmentation pattern, and
its in-memory hold does not survive reboot. WAL logical bytes, checkpoint and
GC work, asynchronous owner completion/draining, durable re-admission after
recovery, and all native service clients still require integration. A caller
must not treat an arbitrary SQLite error or a failed commit as a known outcome.
