# WAMR Rust application in the native emulator

The later [native instance-owner run](2026-10-30-wamr-native-owner.md) adds
graphics permission/lifetime checks and records the updated candidate hashes.
The measurements below describe the preceding candidate.

Date: 2026-10-29. Experimental worktree based on
`c0ff17d5ea6802eed4769a5b588da1735dbfbd32`. This is executable emulator
evidence, not physical Tab5 qualification and not a normal nihos build profile.

## Result

`probes/wamr-native/run-emulator.sh` builds the pinned WAMR 2.4.5 classic
interpreter for RV32IMAC/ILP32, creates sequence-1 and sequence-2 canonical
signed packages containing the fixed one-page Rust Wasm application, converts
sequence 1 and a signed trust snapshot into two-slot journal images, runs the
admission tests, links a
native ESP32-P4 image, audits its dedicated Flash sections, and runs it with 4
MiB PSRAM under esp-emu 0.50.0. The final ELF has no undefined symbols and
contains neither an independently linked raw-Wasm blob nor a standalone package
blob.

After borrowing the private PSRAM stack but before initializing WAMR, the owner
reads a 1,216-byte trust journal, 8,480-byte package journal, 8-byte monotonic
counter fixture, 32-byte provisioned root and 1,419-byte sequence-2 candidate
from mapped read-only Flash. It copies both journals into private mutable media.
The boot coordinator authenticates and seals trust epoch 1, reconstructs the
package-key/revocation/rollback provider, and recovers sequence 1. Its OS-owned
install path first injects `PowerLoss` at the commit-record write after the
inactive record and sequence-2 payload have each been synced. A newly initialized
coordinator still recovers sequence 1. Starting from that partial medium, a retry
clears and syncs the inactive record, writes and syncs sequence 2, then commits
and syncs its record. Another newly initialized coordinator models a restart and
recovers sequence 2 from that mutable media. It then rejects a
one-byte-truncated copy as a negative control. Only the resulting authenticated 1,211-byte payload is copied
into WAMR's two mutable buffers. The accepted manifest has SDK ABI 1, a one-page
linear-memory limit, a 10,000-instruction budget, and only the graphics service
bit. The runtime record reports `boot_recovered=1`, trust epoch 1,
signed-package origin, verified attestation, policy status zero, effective
rights, identity/digest tags, boot-admission cycles, private-stack high-water,
the interrupted-update recovery, three successful-retry package syncs,
initial/installed/recovered sequences 1/2/2, the simulated restart and the
truncation rejection. The restart is a fresh
coordinator in the same emulator process, not a process restart or power cycle.

The single CPU0 owner borrows one 456 KiB task-owned PSRAM lease:

- 128 KiB runtime buddy arena;
- 256 KiB linear-memory buddy arena;
- two 4 KiB writable module buffers;
- 64 KiB private native stack.

The writable module buffer is required by this WAMR loader contract. With the
embedded module passed directly from mapped read-only Flash, WAMR attempted to
move each UTF-8 name over its preceding length byte to create a retained
NUL-terminated string. The write did not take effect, so all exported function
lookups failed even though loading and instantiation returned success. Copying
the 1,211-byte module into the owner lease before `wasm_runtime_load` fixed the
counterexample without making mapped Flash writable.

The passing record reports status zero and two independent module/instance/
exec-env lifecycles within one initialized runtime. The first lifecycle makes
five accepted host calls, traps an invalid guest range, rejects invalid text
and stops a spin at 10,000 instructions. After destroying it, requested live
bytes, live block counts and buddy free bytes all return to the post-runtime-
initialization baseline. A second untouched module copy is then loaded and
makes four drawing calls before destruction. Final runtime destruction returns
both arenas to their original usable free counts of 126,848 and 253,824 bytes.
Requested peaks were 19,737 runtime bytes and 65,536 linear bytes. The combined
private-stack high-water observation rose from the earlier WAMR-only 4,600 bytes
to 23,628 bytes; the snapshot immediately after boot admission was also 23,628
bytes. The guest exports eight items including memory.

After WAMR destruction and lease release, the existing native workload kept
both harts and timers progressing. Three 100-round SMP markers, the 300-round
soak marker and the integer completion marker were observed. This shows the
fixture did not prevent that finite emulator qualification path from
completing; it is not a general scheduler-liveness or latency proof.

## Image boundary

WAMR is opt-in as the `wasm` low-level ELF mode and is rejected for the device
profile. The normal 160 KiB primary SRAM region does not hold the interpreter:
249,072 bytes of reachable WAMR/package/Ed25519/coordinator code and 35,147
bytes of read-only code data plus media fixtures are placed in the loader's
second mapped Flash span. The narrow WAMR audit checks contiguous zero padding
from the record page, RX text, read-only non-executable data, exact journal/
counter/root sizes, the package occurring exactly once at package slot zero,
representative WAMR, Ed25519 and boot-recovery functions in Flash, absence of
raw-Wasm/standalone-package symbols, and zero undefined symbols. This is narrower
than the normal production image audit and deliberately labeled as an emulator
fixture.

The linked debug ELF is retained for diagnosis, but compiler-generated debug
paths are not byte-stable. The script removes only debug sections into a
canonical image ELF while retaining its symbol table, and uses that canonical
ELF for `elf2image`, emulation, structural audit and candidate hashing. This
prevents a changing `.debug_line` string from changing the ELF digest embedded
in otherwise identical flash bytes.

The fixed Wasm SHA-256 is
`4b226889e627af9ce64ee0b5529d1418cd60afc80944d315ed2b64026dde1710`.
The canonical sequence-1 package SHA-256 is
`5958b4dac8881c0ffd7cc3d820072d66afe0b99bb9ed6c535ccb6a1df7be2801`.
The sequence-2 update package SHA-256 is
`3cf7221864c758bbe7377a49e208343ecff55c80adeca31063db7d5df4daaa88`.
The final retained canonical ELF SHA-256 is
`23d3a446412cd839588282f05625651a5363431af354b9a2042f55ef480ae99e`;
the merged flash image SHA-256 is
`41b527dc714484576f0faf1b6903c52500e11893bc3e04fc2e09ba172504ad0d`.
Both were byte-identical across two complete rebuild-and-emulator runs after
canonicalization.
See the [emulator log](evidence/2026-10-29-wamr-native-emulator/emulator.log),
[build log](evidence/2026-10-29-wamr-native-emulator/build.log), and
[structural audit](evidence/2026-10-29-wamr-native-emulator/image-audit-wamr.json).
The retained [policy test](evidence/2026-10-29-wamr-native-emulator/policy-test.log)
records the host acceptance and rejection suite; the [candidate hashes](evidence/2026-10-29-wamr-native-emulator/candidate-sha256.txt)
bind the Wasm, both signed packages, canonical ELF, and merged flash image, while the
[media hashes](evidence/2026-10-29-wamr-native-emulator/boot-media-sha256.txt)
bind the trust/package journals, counter and root fixture.
The [package test](evidence/2026-10-29-wamr-native-emulator/package-test.log)
checks canonical signed framing, trust-provider ownership, revocation and
rollback separately. It is a host test with a mock verifier; the emulator uses
the RV32 Ed25519 adapter and reports signed-package origin.
The [install crash test](evidence/2026-10-29-wamr-native-emulator/package-install-test.log)
is also run before image construction. It covers 504 byte/sync cuts in the
storage-independent two-slot model; it is not executed against emulator or
physical persistent storage.
The [trust snapshot test](evidence/2026-10-29-wamr-native-emulator/trust-snapshot-test.log)
adds 260 byte/sync/counter cuts and protected-floor rollback cases. Its
crash-matrix authenticator and monotonic counter are host fixtures, not
production trust storage. The accompanying [canonical-format test](evidence/2026-10-29-wamr-native-emulator/trust-snapshot-format-test.log)
and [root-chain test](evidence/2026-10-29-wamr-native-emulator/trust-snapshot-root-test.log)
exercise the experimental Ed25519 root-to-package-key chain before image
construction; they do not run inside the emulator image.
The [persistent chain test](evidence/2026-10-29-wamr-native-emulator/trust-snapshot-chain-test.log)
then covers 468 cuts across root-1 to root-2 rotation, package-key revocation,
counter sealing and old-medium rejection. It is also a host model.
It additionally records normal/recovery authority separation, 468 crash-safe
recovery-replace cuts after active-root revocation, and 468 cuts handing the
recovery snapshot back to a new normal root.
The [file-adapter test](evidence/2026-10-29-wamr-native-emulator/file-storage-test.log)
then maps both journals to host positional files, calls `fsync`, closes and
reopens them, and recovers exact bytes. Its second case injects 9 trust-write
cuts, 8 package-write cuts and all 3 sync failures per journal; reopened bytes
must be exactly old or new, and one-byte-short files are rejected. It is not
part of the emulator image and does not qualify device storage, actual ENOSPC,
cold-power persistence or a protected counter.
The full runner also invokes a
[ten-process boot-closure probe](evidence/2026-10-29-wamr-native-emulator/package-process-test.log):
each process reopens trust/counter/package files and re-verifies the root-to-
package-key chain. Sequence 1 is committed, the sequence-2 writer is killed by
its parent with `SIGKILL` before the commit write, a distinct process recovers
sequence 1, another commits sequence 2,
and a fifth recovers sequence 2. Five more processes commit epoch-2 key
revocation followed by immediate `_exit(86)` before counter advancement, stop
before package reads on repeated
sealing failure, seal the lagging counter and reject the revoked application,
reject boot/reinstall, and reject the saved epoch-1 trust journal
against counter floor 2. This is host file persistence evidence and is
not part of the emulator image.
The host runner also executes four parent-kill cuts around package writes and
syncs, with eight additional writer/recovery processes. The
[file-adapter measurement](2026-10-29-package-file-adapter-host.md) retains the
cut images and exact-byte recovery results.
The host runner additionally rejects damaged committed payloads and substitution
with the old signed package, retaining the healthy old slot. Restored bytes
recover exact sequence 2 in separate processes; this is also host-only evidence.
The [boot-admission test](evidence/2026-10-29-wamr-native-emulator/boot-admission-test.log)
then composes trust recovery/counter sealing with package re-admission. It
exercises immediate revocation, explicit maintenance state, a real overlapping
host owner and a future-trust rejection. Its
[RV32 log](evidence/2026-10-29-wamr-native-emulator/boot-admission-rv32.log)
is compile-only. The emulator image now executes the same coordinator against
build-generated journal images, copies them to private mutable media, proves a
commit-write interruption still recovers sequence 1, retries sequence 2, and
uses only sequence 2 recovered by a fresh coordinator as the
WAMR load source. That media exists only for this call and does not persist
across emulator processes or model a filesystem/raw-Flash adapter.
The [RFC Ed25519 test](evidence/2026-10-29-wamr-native-emulator/ed25519-rfc-test.log)
and [actual-Wasm package test](evidence/2026-10-29-wamr-native-emulator/package-ed25519-test.log)
then exercise strict cryptographic verification. They use public RFC test key
material. The native emulator now runs root verification, trust decoding and
package verification, interrupted-update recovery, installation and restart
recovery as one closure, observing 106,780,693 emulator cycles and 23,628
private-stack bytes in two
identical runs; these are not physical-device time or stack measurements.

## Residual gates

This run uses two fresh copies of the same fixed application. It establishes a
canonical package boundary and an experimental package-only Ed25519 load path.
It does not establish a production algorithm registry/key lifecycle, trusted
publisher provisioning, mutable persistent trust storage or a qualified
storage adapter/protected counter, multiple
application identities, arbitrary-module safety, concurrent WAMR owners,
blocking service cancellation, production display/input integration, device
latency, real PSRAM behavior, optical output, process-restart persistence, or
cold-power behavior. The same-process coordinator replacement proves the native
install/recovery contract only. Physical work remains intentionally deferred
while the device is unavailable.
