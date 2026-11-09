# Copy readiness record experiment

This host-only experiment produces a 512-byte readiness record after a caller
has independently reopened two quiescent stores and verified all current keys,
kinds, lengths and bytes. The record includes the asserted card/range layout,
both store generations, a canonical SHA-256 of the source objects and a CRC
for accidental record corruption. The asserted source, target and metadata
ranges must be disjoint and match the compiled store capacities. These range
numbers do not prove that the actual devices or partitions match them.

On reassessment, an intact record is `candidate_ready` only if both stores
remain frozen and the full comparison and fingerprint succeed again. Changing
either store, corrupting the record or supplying a mismatched layout fails
closed. A blank record returns `legacy` only if an external authority can
independently prove the old store is still authoritative; otherwise it also
requires recovery. No valid state here grants permission to write to the target.

The host test reopened both model stores and sampled 60 metadata write/sync
cuts over three writeback policies and five torn-write lengths. Results were 13
legacy, 38 candidate-ready and nine recovery-required; no invalid record was
accepted. The real-SQLite fixture from the capacity-copy experiment also
prepared readiness after reopening its 32 MiB target. Importing the dictionary
then changed that target and correctly invalidated the old readiness record.

This record is not a native selector, automatic cutover, authenticated metadata
or a writable-store lineage protocol. The CRC and digest are not signatures.
The caller must prove card identity, range ownership, external legacy authority,
exclusive access, successful store recovery, media barriers and buffer drain.
No actual record location is reserved, no MBR or SD write was performed, and
no physical power-loss or device boot behavior was tested.
