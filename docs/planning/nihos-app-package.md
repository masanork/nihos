# nihos application package boundary

Status: experimental canonical format, trust-policy boundary, two-slot install
journal, and authenticated trust-snapshot ordering model. The Ed25519 path runs
on RV32 in the emulator and both journals pass host crash matrices. No
production algorithm registry, root/key store, storage adapter, protected
counter, consent flow, or physical-device path is selected.

## Canonical bytes

Version 1 uses one fixed 144-byte little-endian header. Alternate header sizes,
reserved bits, missing payload/signature bytes, truncation, trailing bytes, and
length disagreement are rejected before trust evaluation.

| Offset | Bytes | Field |
|---:|---:|---|
| 0 | 8 | `NIHPKG01` magic |
| 8 | 2 | package format version |
| 10 | 2 | fixed header size, 144 |
| 12 | 2 | signature algorithm ID, interpreted by the verifier |
| 14 | 2 | signature byte length |
| 16 | 4 | exact total package length |
| 20 | 4 | exact Wasm payload length |
| 24 | 8 | nonzero monotonic package sequence |
| 32 | 2+2 | manifest schema and SDK ABI |
| 36 | 16+16 | module and publisher IDs |
| 68 | 4+4 | application version and requested service bits |
| 76 | 2+2 | maximum linear pages and zero reserved word |
| 80 | 4 | instruction budget |
| 84 | 32 | Wasm SHA-256 |
| 116 | 16 | opaque verifier-owned key ID |
| 132 | 12 | zero reserved bytes |
| 144 | variable | Wasm payload, followed by the signature |

The signature input is exactly `header || Wasm`. The trailing signature is not
part of its own input. Algorithm ID, signature length, total length, all
manifest limits, sequence, IDs, key ID, and payload digest are therefore inside
the signed region. There is no wire field for `verified`, origin, or effective
rights.

## Responsibility boundary

1. The package parser establishes one framing and returns exact signed, payload,
   and signature slices. It performs no cryptographic claim.
2. A trust provider resolves `(publisher ID, key ID)` against a trusted/unknown/
   revoked snapshot, supplies the inclusive minimum sequence for the
   `(publisher ID, module ID)` identity, and verifies the exact signed slice.
3. Only after all three trust checks succeed does the package layer construct a
   `signed_package + verified` manifest. On every trust failure it constructs an
   invalid attestation, so the normal application policy also fails closed.
4. The application policy independently recomputes Wasm SHA-256 and checks SDK
   ABI, identity, requested/effective services, memory, instruction and byte
   limits. A valid signature cannot grant a service denied by the platform.
5. The installer owns atomic storage and commits a higher accepted sequence only
   after the complete package has been synced, read back, and admitted again.
   Runtime admission is read-only; it accepts the installed sequence and rejects
   lower values.

The runtime, Wasm module, and host services never interpret a module-provided
trust flag. Choosing an algorithm registry, root/public-key representation,
key rotation overlap, revocation freshness and recovery, rollback-state storage,
package naming, user consent, and uninstall semantics remain later decisions.

## Experimental install journal

`src/app/package_install.zig` defines a storage-independent, per-application
two-slot journal. Each slot reserves the configured maximum package bytes and a
144-byte commit record. The record contains generation, signed package sequence,
trust-snapshot epoch, identity, exact package length and SHA-256, followed by a
checksum over the record metadata.

An update never overwrites the active slot. It clears and syncs the inactive
record, writes and syncs the candidate package, reads back and admits those exact
bytes, then writes and syncs the new record last. Recovery selects the highest
complete generation. A torn record is ignored; a complete newest record whose
package is damaged fails closed instead of silently loading the older sequence.
An identical retry is idempotent, while sequence reuse with different bytes,
downgrade, identity change, and a stale trust epoch are rejected.

The host model injects power loss before every byte write and sync event in one
update: all 504 cuts recover the complete old or complete new package. This is
an executable ordering proof for the model, not a storage qualification. A real
adapter must define truthful write/sync and erase behavior. The checksum is not
an attacker-resistant monotonic counter: restoring a complete older medium
snapshot still requires a separate secure monotonic-state design. Corruption of
the newest commit record itself can also make it indistinguishable from a torn
uncommitted update; medium-level redundancy or monotonic state must close that
gap. Persistent key/revocation snapshots and their update protocol remain
outside this module. See the [host measurement](../measurements/2026-10-29-package-install-host.md).

## Trust snapshot and monotonic epoch

`src/app/trust_snapshot_store.zig` defines a second two-slot journal for an
authority-authenticated trust snapshot. Its authenticator must return an epoch
that is covered by the root signature or MAC. `src/app/trust_snapshot.zig` now
defines an experimental canonical `NIHTRS01` encoding for that snapshot, while
`src/app/trust_snapshot_ed25519.zig` verifies it against separately provisioned
Ed25519 roots. Neither selects the production root or algorithm registry.

The fixed 64-byte snapshot header signs epoch, root-key ID, record counts and
an authority role (`normal` or `recovery`), plus all key/rollback bytes. Key records bind publisher ID, key ID, algorithm,
trusted/revoked status and up to 64 public-key bytes. Rollback records bind
publisher/module identity to a nonzero minimum package sequence. Both record
sets must be strictly sorted and duplicate-free; alternate lengths, reserved
bytes, truncation and trailing bytes are rejected before root verification.

The update commits and syncs the authenticated snapshot record before advancing
an independently protected monotonic counter. If power fails between those
operations, boot recovery can authenticate the newer snapshot and advance the
lagging counter. The reverse ordering is forbidden because it could leave a
counter floor whose snapshot was never committed. Once the protected counter
has advanced, restoring the complete older slot medium or losing the newest
record fails closed below the floor. The model assumes one serialized trust
update/recovery owner; concurrent writers require a higher-level exclusion
contract.

The host model passes all 260 byte/sync/counter cut positions and explicitly
rejects whole-medium rollback and newest-record damage after the floor reaches
epoch 2. A separate host chain verifies an epoch-7 snapshot with the second of
two overlapping test roots, decodes one package key plus one rollback record,
and admits a package signed by that key. Revoked/unknown/duplicate roots and a
mutated signature fail closed. Normal roots cannot sign recovery snapshots and
recovery roots cannot sign normal snapshots. This relies on the counter adapter making
`advance` atomic, durable and non-decreasing. Production root provisioning,
rotation/recovery policy and a real protected counter remain unimplemented. See
the [trust snapshot measurement](../measurements/2026-10-29-trust-snapshot-host.md)
and [format/root measurement](../measurements/2026-10-29-trust-snapshot-format-host.md).

The combined chain then updates a root-1-signed epoch-1 snapshot to a
root-2-signed epoch-2 snapshot across all 468 persistent write/sync/counter cut
positions. Epoch 1 trusts the package key; epoch 2 revokes it and raises its
minimum sequence. Every recovered epoch is root-authenticated and sealed to the
matching counter: the package is accepted only at epoch 1 and rejected as
revoked at epoch 2. After epoch 2 commits, root 1 can be removed from the
provisioned overlap set only after the monotonic floor is sealed; whole-medium
rollback is then rejected.

Emergency recovery replacement remains deliberately blocked in the general
update API once the active normal root is revoked. The dedicated
`recoveryReplace` path instead requires a recovery-only authenticator, a
candidate epoch strictly above the protected floor, and a checksummed structural
head exactly at that floor. It selects the opposite slot without re-enabling or
authenticating the revoked root, verifies readback, commits the new record, then
advances the counter. A retry recognizes a fully committed recovery snapshot
whose counter had not yet advanced, as well as a committed-and-sealed snapshot
whose success response was lost.

The end-to-end model passes all 468 recovery cuts from revoked normal-root epoch
1 to recovery epoch 3. It then uses separate current/candidate authenticators to
handoff from recovery epoch 3 to new-normal-root epoch 4 across another 468
cuts. Only after epoch 4 is sealed does recovery authority leave the active
provisioning set. The model still depends on protected floor integrity and one
serialized owner; it is not a physical recovery implementation.

## Storage adapter conformance

`probes/wamr-native/file-storage-test.zig` maps the two storage callback sets to
host positional file I/O and `fsync`. It pre-creates fixed-size slot and counter
files, commits trust epochs 1 and 2 plus one package, closes every descriptor,
reopens all files read-write, and recovers exact epoch-2 snapshot bytes and the
sequence-1 package. The observed protocol calls six trust-file syncs, two
counter-file syncs, and three package-file syncs.

The same adapter injects partial writes at 9 representative trust-journal and 8
package-journal byte positions, plus failures at each of the 3 journal sync
positions. Every failed attempt is followed by close/reopen and authenticated
exact-byte readback; only a complete old or complete new generation is visible.
Trust and package files shortened by one byte both fail with `Io` instead of
silently becoming empty stores.

This proves that one concrete adapter obeys the callback lengths, offsets,
readback, error and reopen contract under those injected cuts. It does not make
the counter protected, reproduce a real ENOSPC event, qualify macOS `fsync` as
cold-power durability, sync containing-directory metadata, or model raw-Flash
erase/program constraints. Files are created before the tested transactions,
so file creation durability is deliberately outside the result.
See the [file-adapter measurement](../measurements/2026-10-29-package-file-adapter-host.md).

A companion command-line probe carries trust-journal, counter and package-
journal files through ten separate host processes. Each recovery authenticates
the root-signed trust snapshot, reconstructs the Ed25519 package provider and
enters the OS boot coordinator. It provisions sequence 1, kills the sequence-2
writer with parent-issued `SIGKILL` before its commit record, reopens and
recovers sequence 1, retries sequence 2,
then reopens and recovers sequence 2. Unique PIDs and exact final bytes establish
a real process boundary for the full host boot adapter. The last five processes
commit epoch-2 key revocation followed by immediate `_exit(86)` before counter
advancement, reject boot before
package reads while sealing still fails, seal the lagging counter and reject
the revoked package, reject sequence-2 boot/reinstall, and reject the
saved epoch-1 trust journal against counter floor 2. This remains macOS file
evidence rather than emulator/native Flash or cold-power qualification.
An additional four-case parent-issued `SIGKILL` matrix uses independent copies
of the sequence-1 journal: after inactive-record invalidation, during payload
write, during commit-record write, and after commit sync. Separate recovery
processes return exact sequence-1 bytes for the first three and exact sequence-2
bytes for the committed case. Unsynced partial-write survival is host-visible
process behavior; kernel/power failure remains outside this evidence.
Two committed-state controls corrupt the new payload or replace its package
with the valid signed old package while preserving the sequence-2 record and
healthy old slot. Separate processes reject boot and reinstall without changing
the media. Restoring only the package range returns exact sequence-2 bytes on
another process's recovery. This confirms damaged committed payloads do not
silently select the old slot in this host adapter.

## Boot admission composition

`src/app/boot_admission.zig` now fixes the boot read order: authenticate and
seal the persisted trust head, verify and decode its package keys/revocations/
rollback floors, then recover and re-admit the installed package under that
exact epoch. Only this successful path returns package bytes for a runtime.
Unprovisioned trust, normal trust without a package, and an active
recovery-authority snapshot are explicit distinct states. Recovery authority
places the OS in maintenance and never launches an application.

An atomic gate rejects re-entry or another hart entering the composition while
one owner is active, including while storage callbacks run. Host tests cover an
actually overlapping thread, gate release after an admission error, immediate
package revocation after a trust update, idempotent reboot recovery, and a
package record from a future trust epoch. The complete call closure also
compiles for RV32IMAC. The coordinator also owns package installation: it
requires sealed normal trust, commits through the two-slot installer, and reads
back the committed package. The native emulator copies build-generated journals
to private mutable media, recovers sequence 1, injects a commit-write failure,
and proves a fresh coordinator still selects sequence 1. It then retries
sequence 2 with three syncs, replaces the coordinator again, and passes only
recovered sequence 2 to WAMR.
This closes the executable install/recovery composition path, not process-
restart persistence or cold-power durability; see the
[boot-admission measurement](../measurements/2026-10-29-boot-admission-host.md).

## Experimental Ed25519 adapter

The [journal-to-WAMR host fixture](../measurements/2026-10-29-journal-wamr-host.md)
uses the actual Rust app instead of the small crash-model payload. A fresh
process recovers and admits its signed package from journal files before WAMR
executes the exported bytes. Exact payload equality and wrong-root/damaged-media
rejections are checked by the runner.
Its [same-process extension](../measurements/2026-10-30-journal-wamr-buffer-host.md)
admits private journal snapshots through a Zig C ABI and passes the resulting
private module buffer directly to WAMR. It requires an already sealed counter;
the read-only snapshot adapter cannot make durable counter repairs.
The ABI returns effective services alongside the private payload. The trusted
platform's grant is an admission limit, not a permission mask copied directly to
the guest. A host owner attaches only the manifest's admitted services to the
specific runtime instance and checks them at graphics-import entry. A valid
signature alone cannot launch the fixture when its graphics grant is absent.

Algorithm ID 1 is provisionally exercised as Ed25519 by
`src/app/package_ed25519.zig`. It performs strict/cofactorless verification,
requires an exact 64-byte signature, and resolves a public key by the full
`(publisher ID, key ID)` pair. The adapter borrows immutable key and rollback
snapshots; it rejects duplicate key identities, duplicate rollback identities,
zero minimum sequences, and stored `unknown` records before exposing a provider.
It does not load, persist, update, or trust those records itself.

The primitive is checked against RFC 8032 section 7.1 test vector 1. A second
test uses that vector's public test seed to sign the actual 1,211-byte Rust Wasm
fixture. The resulting 1,419-byte canonical test package parses and authenticates
with SHA-256
`5958b4dac8881c0ffd7cc3d820072d66afe0b99bb9ed6c535ccb6a1df7be2801`.
Signature, payload, revocation, and rollback mutations are rejected. The RFC
secret is public test material and must never become an installation key. See
[RFC 8032](https://www.rfc-editor.org/rfc/rfc8032.html).

## Current acceptance evidence

`src/app/package.zig` host tests cover canonical packing/parsing, all framing errors,
trusted/unknown/revoked keys, rollback, unsupported algorithms, invalid
signatures, exact verifier message boundaries, service denial, and payload
digest mismatch. Separate tests cover RFC Ed25519 verification and the actual
Wasm package path. The WAMR emulator script runs them around its package-only
build. The RV32 closure now parses and admits the exact package
from mapped Flash, then copies only its authenticated payload into WAMR's two
mutable loader buffers. The raw Wasm remains a build input for package creation
and identity audit but is no longer linked into the ELF. See the [RV32
measurement](../measurements/2026-10-29-package-ed25519-rv32.md).
The two-slot installer tests additionally cover every write/sync crash cut,
idempotent retry, sequence conflict, downgrade, trust-epoch regression, and
fail-closed recovery when the committed head payload is corrupted. The trust
snapshot tests separately cover update/counter cuts and complete-medium rollback
against a protected epoch floor.
