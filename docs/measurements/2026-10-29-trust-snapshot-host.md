# Authenticated trust snapshot crash model

Date: 2026-10-29. Experimental worktree based on
`c0ff17d5ea6802eed4769a5b588da1735dbfbd32`. This is a host ordering model, not
a production root/key format, secure-element counter, persistent nihos store,
or physical power-loss qualification.

## Ordering and result

`src/app/trust_snapshot_store.zig` stores opaque authenticated snapshots in two
slots. A checksummed 96-byte record commits generation, authenticated epoch,
length and snapshot SHA-256. The authority callback must authenticate the whole
snapshot and return an epoch covered by that authentication.

An update invalidates only the inactive record, syncs the snapshot, reads back
and authenticates it, commits its record, and only then advances an external
monotonic counter. Recovery advances a lagging counter only after finding the
newer complete authenticated snapshot. It rejects a snapshot below the protected
floor.

The fault model exposes every completed byte immediately and injects failure
before all writes, syncs and the atomic counter advance:

```text
NIHOS_TRUST_SNAPSHOT crash_cuts=260 old_or_new=1 sealed=1 partial=0
All 2 tests passed.
```

All 260 cuts recovered and sealed the exact epoch-1 or epoch-2 snapshot. After
the counter reached epoch 2, restoring the entire epoch-1 slot medium and
damaging the newest commit record were both rejected rather than falling back.
Retained evidence: [host test log](evidence/2026-10-29-trust-snapshot-host/test.log).

## Remaining boundary

The crash-matrix authenticator is a deterministic fixture checksum, not a root
signature. A separate host test now covers the experimental canonical format
and Ed25519 root chain, but production root provisioning and rotation/recovery
policy, counter hardware/service, storage adapter, and physical interruption
tests remain open. The model assumes
counter `advance` is independently protected, atomic, durable and
non-decreasing; it does not prove those properties. It also assumes one
serialized updater/recovery owner rather than concurrent trust writers.
