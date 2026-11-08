# One-way capacity activation experiment

The host-only guard first requires the readiness comparison from the preceding
experiment, then writes one activation sector and calls a media barrier. It
starts only from an erased metadata slot. If the write or barrier fails, its
result is `PublicationUnknown` and that guard remains fenced: it cannot retry
or authorize writes. An existing or unreadable metadata slot also fences the
guard. The caller must keep both stores frozen throughout this process.

Recovery chooses the target only for an intact record whose asserted geometry,
card identity and target-instance identity match independently supplied boot
facts, and only after the caller reports successful target recovery. It never
falls back to the old source because target recovery failed. An erased record
selects legacy only when an external authority independently proves that legacy
is still authoritative; without that proof it requires recovery. This matters
once target writes could have happened. After activation, normal target writes
change the old equality fingerprint, so target recovery relies on its own
persistent identity and store recovery, not on equality with the stale source.

In a model, 60 combinations of activation write/sync cut, writeback policy and
torn length produced 45 unknown outcomes and 15 acknowledged successes. On
recovery, 13 selected legacy under the test's explicit frozen-source proof,
38 selected the matching recovered target, and nine required recovery. Some
unknown outcomes had in fact persisted the complete record; none was retried
through the fenced guard. A host SQLite fixture also copied to a 32 MiB target,
passed readiness, simulated activation, added a 5,129,285-byte dictionary,
reopened the target and retained the SQLite integrity result and Japanese row.

This is not a native selector or a production cutover protocol. The record has
no authentication and uses a single sector; corruption can require manual
recovery. Card identity, target-instance identity, range ownership, the
legacy-authority fact and the target-recovered fact are trusted caller inputs;
none is implemented or proven by the record. No metadata location is reserved,
no MBR/SD write was performed, and no real device, DMA, physical power loss,
rollback, or writable-target lineage was qualified.
