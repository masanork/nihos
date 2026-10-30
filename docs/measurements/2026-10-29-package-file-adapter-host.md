# Package and trust file-adapter conformance

Date: 2026-10-29. Experimental worktree based on
`c0ff17d5ea6802eed4769a5b588da1735dbfbd32`. This is a macOS host adapter test,
not Tab5 storage, secure counter, cold-power, filesystem, or raw-Flash evidence.

## Result

`probes/wamr-native/file-storage-test.zig` implements the existing storage
callbacks with positional file reads/writes and `fsync`. It uses separate
pre-created files for trust slots, the monotonic-counter fixture, and package
slots.

The probe commits trust epochs 1 then 2, installs package sequence 1, closes all
descriptors, reopens every file read-write, and verifies exact snapshot/package
bytes and metadata:

```text
NIHOS_FILE_ADAPTER trust_epoch=2 package_sequence=1 reopen=1 fsync_trust=6 fsync_counter=2 fsync_package=3
NIHOS_FILE_FAULTS trust_write_cuts=9 package_write_cuts=8 sync_cuts_each=3 exact_old_or_new=1 short_files_rejected=2
All 2 tests passed.
```

The second test starts from a committed old generation and injects an I/O error
after 9 representative cumulative write lengths for the trust journal and 8
for the package journal. It separately fails each of the 3 journal `fsync`
positions. After every failed transaction it closes and reopens the actual
files; authenticated readback must equal all bytes of either the old generation
or the new generation. A file truncated by one byte is rejected as `Io` for
both journal types rather than being interpreted as an empty store.

A separate executable probe then uses persistent trust-journal, counter and
package-journal files across ten distinct host processes. Their recorded PIDs
are unique. Recovery verifies the deterministic root signature, checks the
counter floor, reconstructs the Ed25519 application key and rollback
floor, and re-admits the package through `boot_admission.Coordinator`. Process 1
provisions trust and commits sequence 1. Process 2 syncs the inactive record and
sequence-2 payload, then waits before writing its commit record. A Python parent
checks the checkpoint's PID against its own child, sends `SIGKILL`, and requires
return code -9. Its read timeout is 10 seconds and it reaps the child on every
failure path.
Process 3 reopens all media and recovers sequence 1. Process 4 retries and
commits sequence 2 with three `fsync` calls. Process 5 reopens all media and
recovers the exact sequence-2 package bytes. Process 6 commits a root-signed
epoch-2 trust snapshot revoking the application key, then calls `_exit(86)`
before counter advancement, leaving floor 1. This skips Zig defers and explicit
file-close paths. The runner requires exit status 86; an ordinary success or
another failure cannot satisfy the test. Process 7 attempts boot with the
same counter failure and stops before any package read. Process 8 authenticates
the committed epoch-2 snapshot, advances and syncs the counter to 2, then rejects
the revoked application. Trust-journal bytes are unchanged during sealing.
Process 9 rejects both boot and reinstall of sequence 2 without any writes;
the runner compares all three media hashes before and after this rejection.
Process 10 receives the saved epoch-1 trust journal with the current epoch-2
counter and rejects recovery as `Rollback`:

```text
NIHOS_BOOT_PROCESS phase=provision trust_epoch=1 sequence=1 trust_syncs=3 counter_syncs=1 package_syncs=3 pid=<pid-1>
NIHOS_BOOT_PROCESS phase=interrupt trust_epoch=1 sequence=1 package_syncs=2 await_sigkill=1 pid=<pid-2>
NIHOS_BOOT_PROCESS phase=recover-old trust_epoch=1 sequence=1 process_reopen=1 pid=<pid-3>
NIHOS_BOOT_PROCESS phase=install trust_epoch=1 sequence=2 package_syncs=3 pid=<pid-4>
NIHOS_BOOT_PROCESS phase=recover-new trust_epoch=1 sequence=2 process_reopen=1 pid=<pid-5>
NIHOS_BOOT_PROCESS phase=interrupt-trust trust_epoch=2 counter_floor=1 trust_syncs=3 counter_syncs=0 abrupt_exit=86 pid=<pid-6>
NIHOS_BOOT_PROCESS phase=reject-unsealed trust_epoch=2 counter_floor=1 seal_failed=1 package_reads=0 pid=<pid-7>
NIHOS_BOOT_PROCESS phase=seal-revoked trust_epoch=2 counter_floor=2 counter_syncs=1 boot_rejected=1 pid=<pid-8>
NIHOS_BOOT_PROCESS phase=reject-revoked trust_epoch=2 sequence=2 boot_rejected=1 install_rejected=1 writes=0 pid=<pid-9>
NIHOS_BOOT_PROCESS phase=reject-rollback trust_epoch=1 counter_floor=2 rejected=Rollback writes=0 pid=<pid-10>
```

The final 1,216-byte epoch-2 trust
journal SHA-256 is `a51cb966299232b786ab3e972ecd81ae4577e5c675c55d7955ceb8dec91cd3f2`,
the 8-byte counter SHA-256 is
`d86e8112f3c4c4442126f8e9f44f16867da487f29052bf91b810457db34209a4`,
and the 1,312-byte package journal SHA-256 is
`1c72c773100be3c0659dde138c68be3c5c47168be47f04af5ff6d1afd583a104`.

Retained evidence: [host test log](evidence/2026-10-29-package-file-adapter-host/test.log),
[process-boundary log](evidence/2026-10-29-package-file-adapter-host/process.log),
[media hashes](evidence/2026-10-29-package-file-adapter-host/media-sha256.txt),
and the final [trust](evidence/2026-10-29-package-file-adapter-host/trust.bin),
[counter](evidence/2026-10-29-package-file-adapter-host/counter.bin), and
[package](evidence/2026-10-29-package-file-adapter-host/package.bin) images.
The saved [epoch-1 journal](evidence/2026-10-29-package-file-adapter-host/trust-epoch1.bin)
is the rollback input. Its hash remains
`ef8c7185fbbc10576f1c487f222810c1be95e11f56e8836af1892a08266c3327`.
The [lagging counter](evidence/2026-10-29-package-file-adapter-host/counter-lagging.bin)
retains floor 1 after the trust commit. It pairs with the final trust journal to
reproduce the pending-seal input.
The runner's [termination status](evidence/2026-10-29-package-file-adapter-host/termination-status.txt)
records the immediate process exit separately from the firmware-style marker.
The parent's [kill status](evidence/2026-10-29-package-file-adapter-host/kill-status.txt)
records the package writer PID, `SIGKILL`, and return code -9.

The runner also executes a four-case `SIGKILL` matrix from separate copies of
the committed sequence-1 package journal. Each case uses its own writer and
recovery process (eight additional distinct PIDs). The recovery enters the full
boot coordinator and compares every recovered package byte with the expected
deterministic signed package:

| Kill checkpoint | Completed package syncs | Partial write | Recovered sequence |
| --- | ---: | ---: | ---: |
| Inactive record invalidated | 1 | none | 1 |
| Payload write in progress | 1 | 106 of 213 bytes | 1 |
| Commit record write in progress | 2 | 72 of 144 bytes | 1 |
| Commit record synced, installer has not returned | 3 | none | 2 |

The partial writes issue positional file writes before the parent kills the
writer; they do not issue another `fsync`. Trust and counter bytes remain equal
to their epoch-1 input throughout this matrix. The saved cut images preserve
the host-visible bytes observed after process termination. They do not model
which unsynced bytes would survive kernel failure or loss of power.
Retained [matrix log](evidence/2026-10-29-package-file-adapter-host/kill-matrix.log)
and [matrix manifest](evidence/2026-10-29-package-file-adapter-host/kill-matrix.json)
bind each image hash, checkpoint, recovered sequence and writer/recovery PID.
The cut images are retained as
[clear](evidence/2026-10-29-package-file-adapter-host/cut-clear.bin),
[partial payload](evidence/2026-10-29-package-file-adapter-host/cut-payload.bin),
[partial record](evidence/2026-10-29-package-file-adapter-host/cut-record.bin), and
[committed](evidence/2026-10-29-package-file-adapter-host/cut-committed.bin).

Two additional committed-state controls keep the complete sequence-2 commit
record and the healthy sequence-1 slot unchanged. One flips a Wasm byte in the
new slot. The other substitutes the complete, correctly signed sequence-1
package into the new slot while retaining its sequence-2 commit record. A fresh
process rejects both boot and reinstall as `ActivePackageInvalid`, rather than
falling back to the healthy old slot. All trust, counter and damaged package
media bytes remain unchanged during rejection. Reversing only the altered
package range produces the original committed image; another fresh process
then recovers and compares every byte of sequence 2. These controls add four
processes to the ten-phase flow and eight-process kill matrix.

The [corruption log](evidence/2026-10-29-package-file-adapter-host/corruption-controls.log)
and [manifest](evidence/2026-10-29-package-file-adapter-host/corruption-controls.json)
bind each rejection/restoration PID and image hash. The
[changed payload](evidence/2026-10-29-package-file-adapter-host/corrupt-payload.bin)
and [old-package substitution](evidence/2026-10-29-package-file-adapter-host/substitute-old.bin)
images retain the corrupted committed state. Their restored images are identical
to the saved committed case above. This exercises the commit-record digest
binding; independent signature-verifier tests remain separate evidence.

## Qualification boundary

This validates callback offset/length handling, explicit file sync calls, and
close/reopen plus real process-boundary recovery on the host, including
adapter-injected partial writes and sync failures. It still does not simulate a
host kernel crash or power loss. The package-commit interruption kills the
writer with `SIGKILL`, while repeated counter-sealing failure returns an adapter
error. The trust-commit interruption terminates the actual process with
`_exit(86)` before it can return
through the update call or close files explicitly. The kernel remains running,
and successful `fsync` semantics are supplied by macOS.
The counter file is not protected against rollback. The
injected `Io` paths are not evidence for an actual ENOSPC event, kernel or
device-cache loss, directory-entry loss, torn sectors, media removal, raw erase
blocks, or cold power. Because files are pre-created, the test also does not
claim file-creation or directory-metadata durability. A nihos medium adapter
must be tested against its actual cache, sync, allocation and interruption
model before publication.
