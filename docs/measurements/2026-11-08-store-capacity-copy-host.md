# Host copy to a larger checkpoint store

This experiment copies a pinned committed source volume into a separately
formatted, empty checkpoint store. It streams every present key in one target
transaction, preserves blob versus mapped representation, and checks key
presence, kind, length and bytes against the source before reporting success.
It never formats or writes the source. Caller-supplied domain identifiers are
assertions only; a native caller must independently prove device ranges do not
overlap and retain exclusive ownership. Object pins/snapshots, token values,
generation numbers and uncommitted transactions are not migrated.

A host fixture created by the real SQLite service occupied a 4 MiB legacy
image and contained a table row `(1, 日本語)`. The test copied its two store
objects (20,496 bytes) into a separate 32 MiB image, imported an external
5,129,285-byte NFST as key 200, reopened the target, and compared every source
object with the target while verifying the source image SHA-256 was unchanged.
A copied database extracted from the reopened target passed SQLite
`PRAGMA integrity_check` and returned the original row; the added dictionary
returned 漢字 for かんじ. The dictionary is not redistributed by this test.

A separate model sampled 56 destination write/sync cuts across two writeback
policies, including points near the final publication; after modeled restart
the target was either empty or contained the complete original object set,
and the source digest remained unchanged. This is bounded fault sampling,
not exhaustive cut-point coverage or physical power-loss qualification.

This is not an on-device migrator or a selector/cutover protocol. The copy
function verifies the currently mounted target; the host test separately
reopens it. No MBR/GPT, SD range disjointness, capacity reservation for future
writes, concurrent SQLite writers, user snapshots, native scheduler, DMA or
Tab5 was tested. A failed or interrupted target must not be selected; commit
failure may have an unknown outcome and requires recovery and revalidation.

The original reproduction compiled the migration test directly. After the ABI
integration, use `NIHOS_NFST_PATH=/path/to/jisyo-l.nfst python3 tools/check-capacity-copy-abi.py`
instead; it links the separate host-only ABI
and imports into key 64. The measurements above record the earlier key 200
experiment; see `2026-11-09-capacity-copy-dictionary-abi.md` for the integrated
test and its evidence boundary.
