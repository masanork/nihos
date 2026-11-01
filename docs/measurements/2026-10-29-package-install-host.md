# Signed-package install crash model

Date: 2026-10-29. Experimental worktree based on
`c0ff17d5ea6802eed4769a5b588da1735dbfbd32`. This is a host-executed storage
ordering model, not filesystem, raw-Flash, SD, power-loss, or physical Tab5
qualification.

## Model and result

`src/app/package_install.zig` implements a per-identity two-slot journal over a
narrow `readAt` / `writeAt` / `sync` interface. Each slot contains up to 512
bytes in this fixture and a 144-byte checksummed commit record. Installation:

1. admits the signed candidate before writing;
2. invalidates and syncs only the inactive record;
3. writes and syncs the complete candidate;
4. reads back and admits the exact stored bytes;
5. writes and syncs generation, sequence, trust epoch, identity, length and
   package SHA-256 as the final commit operation.

The fault store makes every completed byte immediately durable, then injects
power loss before each byte write and sync. This conservatively exposes every
prefix of the update. All 504 cuts recovered either the exact sequence-1
package or the exact sequence-2 package; no partial package was returned.

```text
NIHOS_PACKAGE_INSTALL crash_cuts=504 old_or_new=1 partial=0 committed_payload_corruption=fail_closed
All 3 tests passed.
```

The other tests verify idempotent retry, same-sequence/different-byte conflict,
downgrade rejection, identity binding, stale trust-epoch rejection, and that a
damaged payload behind the newest complete record fails closed instead of
falling back to the older committed sequence.

The separate integration test signs the actual 1,211-byte Rust Wasm with the
public RFC test key, installs the resulting 1,419-byte package through the
Ed25519 provider, recovers sequence 1/trust epoch 1, and reads back exact package
bytes. Retained evidence: [crash-model log](evidence/2026-10-29-package-install-host/test.log)
and [Ed25519 install log](evidence/2026-10-29-package-install-host/ed25519-install-test.log).

## Remaining boundary

The model assumes the adapter's `sync` accurately describes its medium and that
its slot area can be rewritten or erased safely. It does not qualify any nihos
filesystem/VFS, raw NOR erase block, SD card, cache, controller, or cold power
cut. Record checksums detect tearing and corruption but do not prevent an
attacker from restoring a complete older storage snapshot. A separate host
model now defines trust-snapshot ordering against a monotonic epoch, but a real
protected counter remains absent. Production key and revocation snapshot
encoding/authentication, consent, space
reservation, uninstall, and garbage collection remain separate gates. Damage
to the newest commit record can be indistinguishable from a torn uncommitted
record and therefore also requires medium redundancy or separate monotonic
state before this can be called rollback-resistant storage.
