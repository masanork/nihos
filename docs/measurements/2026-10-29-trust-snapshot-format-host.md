# Canonical trust snapshot and Ed25519 root chain

Date: 2026-10-29. Experimental worktree based on
`c0ff17d5ea6802eed4769a5b588da1735dbfbd32`. This is host validation with public
test material, not production root provisioning, protected-counter persistence,
or physical-device evidence.

## Format and result

`src/app/trust_snapshot.zig` defines canonical `NIHTRS01` framing: a fixed
64-byte header, sorted 104-byte key records, sorted 40-byte rollback records,
and one trailing root signature. Epoch, root-key ID, exact lengths/counts,
authority role (`normal` or `recovery`), publisher/key/module identities,
algorithms, trusted/revoked status, public-key
bytes and minimum package sequences are all inside the signed region.

The parser rejects every truncation, alternate length, nonzero reserved field,
unknown status, invalid key length, unsorted/duplicate identity and trailing
byte. The Ed25519 adapter requires an exact provisioned root-key ID and strict
signature, rejects duplicate or revoked roots, and supports an explicit overlap
set for rotation. The provisioned root role must match the signed snapshot role;
normal/recovery cross-use is rejected.

The integration fixture signs an epoch-7 snapshot with root 2 while roots 1 and
2 overlap. It decodes one Ed25519 package key and one rollback record into the
existing trust provider, then admits a package signed by that package key:

```text
NIHOS_TRUST_ROOT epoch=7 roots=2 package_keys=1 rollback=1 package_admitted=1 authority_separated=1 recovery_epoch=8
All 1 tests passed.
```

Retained evidence: [format test](evidence/2026-10-29-trust-snapshot-format-host/format-test.log)
and [root-chain test](evidence/2026-10-29-trust-snapshot-format-host/root-test.log).

## Persistent rotation and revocation chain

The combined fixture stores a 272-byte root-1-signed epoch-1 snapshot, then
updates to a same-size root-2-signed epoch-2 snapshot. Epoch 1 trusts the test
package key with minimum sequence 1; epoch 2 revokes it and raises the minimum
to 2. It injects power loss before every storage byte, sync, and protected
counter advance:

```text
NIHOS_TRUST_CHAIN crash_cuts=468 recovery_cuts=468 handoff_cuts=468 roots_overlap=2 retired_root1=1 revoke_package_key=1 rollback_rejected=1 recovery_replace=1 normal_handoff=1
All 1 tests passed.
```

All 468 recovered states have a valid root signature and matching sealed epoch.
The test package is accepted only when epoch 1 survives and rejected as a
revoked key when epoch 2 survives. After the completed update, recovery succeeds
with only root 2 provisioned once the epoch-2 counter floor is sealed; restoring
the epoch-1 medium is rejected. Retained
evidence: [persistent chain test](evidence/2026-10-29-trust-snapshot-format-host/chain-test.log).

The fixture also provisions an offline recovery-role root and signs a higher
recovery snapshot. Once root 1 is marked revoked, the general update API still
rejects replacement. Dedicated `recoveryReplace` uses only the checksummed
structural head at the protected floor to select the inactive slot; it never
temporarily re-enables root 1. All 468 interruption points can be retried to the
exact recovery epoch 3 snapshot; retry after a committed/sealed success is also
idempotent. A separate transition authenticates the
current recovery snapshot and a new normal-root candidate independently; all
468 cuts recover epoch 3 or epoch 4, after which the recovery root can be
removed from active provisioning.

## Remaining boundary

The deterministic roots are test-only and must never be provisioned. Production
root generation/custody, rotation overlap duration, operational emergency
authorization, algorithm migration, snapshot distribution,
consent/audit, protected
counter and durable media remain separate gates. The current package decoder
accepts Ed25519 package keys only; the 64-byte canonical key field reserves
framing room but does not claim support for another algorithm.
