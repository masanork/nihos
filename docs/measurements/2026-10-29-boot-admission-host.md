# Boot admission composition

Date: 2026-10-29. Experimental worktree based on
`c0ff17d5ea6802eed4769a5b588da1735dbfbd32`. This is host execution, an RV32
compile closure and a private mutable native-emulator fixture, not persistent-media
or physical-device boot evidence.

## Result

`src/app/boot_admission.zig` provides the single OS-owned path from persisted
trust/package journals to runtime-loadable package bytes. It first authenticates
and seals the newest trust snapshot against the external monotonic floor, reads
and verifies the exact snapshot again, reconstructs the package key/revocation/
rollback provider, then recovers and re-admits the installed package. The
returned package bytes borrow caller-owned scratch memory.

The coordinator has an atomic single-owner gate. An active recovery-authority
snapshot returns `recovery_maintenance`; it never yields application bytes.
Unprovisioned trust and a valid trust snapshot without a package are separate
non-error states.

```text
NIHOS_BOOT_ADMISSION ready=1 idempotent=1 install_sequence2=1 simulated_reboot=1 revocation=1 gate_released_after_error=1
NIHOS_BOOT_STATES unprovisioned=1 install_without_trust_rejected=1 no_package=1 owner_busy=1 recovery_maintenance=1 recovery_install_rejected=1 future_trust_rejected=1
All 2 tests passed.
```

The test installs a real root-signed trust snapshot and Ed25519-signed package,
recovers exact sequence-1 bytes twice, installs sequence 2 through the same
OS-owned coordinator, and recovers it through a newly initialized coordinator.
It rejects installs without trust and while recovery authority is active, then
advances trust to a snapshot that
revokes the package key and observes fail-closed rejection. It also blocks one
host thread inside storage read and verifies that a concurrent recovery call
returns `Busy`; the first owner resumes and completes.

The full call closure compiles as RV32IMAC soft-float freestanding code. The
compile-only object reports 73,480 bytes of `.text`, 4,076 bytes of read-only
data/strings and only `__lshrdi3`, `memcpy`, and `memset` as unresolved runtime
helpers. This object is an inventory artifact, not a linked image-size delta.

The native emulator now links deterministic two-slot trust/package journal
images rather than a standalone package blob. Its CPU0 owner copies them to
private mutable media, recovers sequence 1, drops the sequence-2 commit write
after two syncs, and proves a fresh coordinator still recovers sequence 1. It
then retries sequence 2 with three syncs and recovers sequence 2 through another
fresh coordinator. It copies only that
recovered/admitted payload into WAMR's mutable buffers and
completes both runtime lifecycles plus the SMP/soak tail. The structural audit
requires `load_source=boot-journal`, exact media sizes, one package occurrence
at package slot zero, and no raw-Wasm or standalone-package symbol.

Retained evidence: [host test](evidence/2026-10-29-boot-admission-host/host-test.log),
[RV32 compile log](evidence/2026-10-29-boot-admission-host/rv32-compile.log),
[RV32 attributes](evidence/2026-10-29-boot-admission-host/rv32-attributes.txt),
[undefined symbols](evidence/2026-10-29-boot-admission-host/rv32-undefined.txt),
[emulator log](evidence/2026-10-29-boot-admission-host/emulator.log),
[structural audit](evidence/2026-10-29-boot-admission-host/image-audit-wamr.json),
[candidate hashes](evidence/2026-10-29-boot-admission-host/candidate-sha256.txt),
and [media hashes](evidence/2026-10-29-boot-admission-host/boot-media-sha256.txt).

The separate [host file process probe](2026-10-29-package-file-adapter-host.md)
now executes this coordinator across ten independent processes. The parent
kills the package writer with `SIGKILL` at its pre-commit checkpoint; a later
process recovers the old package and retries the update. After package
update/recovery, it commits a root-signed epoch-2 key revocation and terminates
with `_exit(86)` before counter advancement, bypassing explicit file close and
Zig defer execution. The next process proves continued sealing failure prevents
all package reads; a later process seals the lagging counter and rejects the
revoked package. A later process rejects both boot and reinstall of sequence 2 with no
media changes. Another process opens the saved epoch-1 trust journal against
counter floor 2 and rejects it as `Rollback`. The counter remains an ordinary
host file whose integrity the experiment assumes.
The same runner adds four separate package-media cuts, killing the writer
after invalidation, during payload/record writes, and after commit sync. Each
cut is recovered by a fresh host process entering this coordinator; all recover
the expected exact old/new package bytes.
Two further controls preserve the new commit record and healthy old slot but
corrupt the new payload or substitute the signed old package. Fresh processes
reject boot/reinstall as `ActivePackageInvalid` with unchanged media. Restoring
the altered package range permits exact sequence-2 recovery in fresh processes.

## Qualification boundary

The coordinator fixes boot ordering, trust freshness, maintenance behavior and
exclusive entry for the current Ed25519 experiment. It does not provision
production roots, protect the monotonic counter, qualify a filesystem/Flash
adapter, or persist writes across emulator runs. WAMR is invoked from recovered
sequence-2 storage in the current emulator fixture, but its mutable journal is
private memory initialized from build-time bytes. Coordinator replacement is
not an emulator process restart or power cycle.
The gate excludes overlapping calls but cannot make adapters safe if another
path writes the same medium outside the coordinator. Cold-power and physical
Tab5 qualification remain required.
