# 0056: Identity-bound pristine font library image, preserving kernel ownership

Status: accepted for host-driven RV32 ISA qualification, 2026-10-28.

The stack bank can be lent outside the worker lifetime (ADR 0055), while the
library's 32 KiB writable region contains persistent state. LazyPool's initialized
owner ceilings live in data, and HarfBuzz's language registry retains pointers
into service-owned backing after individual clients close. A new service epoch
must start from the exact linked library initializer, with zero BSS and no stale
library pointers. It must not reset kernel heap metadata, the owner ledger or
buffers belonging to other live users.

Qualify this boundary first with real RV32 FreeType/HarfBuzz code in host Unicorn,
not a native reset path. The standalone linker gives the library a 32 KiB bank
at 0x51000000 and puts the existing Zig buddy/task-ledger bridge in a different
writable region. No mutable section may escape these two domains. ELF identity,
section bounds/kinds/permissions and writable load coverage bind a pristine bank
template: initialized data is copied from the fully linked executable, while
BSS and padding are zero. The template's digest and loaded ELF identity must
match, and the runtime must be quiescent before the first write.

The generated Session/renderer is unchanged. Only its initial backing-init call
is replaced by an epoch-ready check: the host runner initializes backing once,
retires service parents through the real ledger, and explicitly reopens a new
owner generation. The kernel heap is never reinitialized between lifetimes.
This harness contract does not change native kernel C callbacks or service APIs.
The existing pinned native-built FreeType/HarfBuzz archives are reused; the Zig
bridge is rebuilt from current source for this experiment.

Use an 8 MiB charged peer allocation to overwrite reclaimed backing and retain
that other owner's data across subsequent service epochs. Two separate negative
runtimes test insufficient restoration. Restoring only the pool/controller flags
leaves HarfBuzz's language registry stale; restoring BSS after another consumer
poisons the library bank leaves initialized data invalid. Each negative runtime
is discarded after failure, not treated as quiescent/recovered. In a third
runtime, retire the service, lend/poison the entire library bank, restore the
full pristine template and render again. Run three lifetimes, comparing all
sixteen forced-auto-hint hashes with the independent sanitized host baseline.
Check peer bytes and persistent kernel metadata after restoration, then peer
bytes after retirement. Finally free the peer and require full heap recovery.

Host unit tests require wrong-image, corrupt-template and live-library refusal
before any write, and reject malformed/out-of-bank/extra writable sections.
Executable/runtime code and font inputs are read-only. Forbidden runtime entry
points stop at a basic-block hook; an explicit abort control checks enforcement.
A fixed 32 KiB test stack has guard bytes and unmapped boundaries; this is not
new instruction-by-instruction stack-peak or arbitrary-font evidence.

This stage does not change native firmware or qualify a native restart. Native
integration must store/read the pristine initializer outside the loaned bank,
bind it to final image addresses and authorize writes only after ACK/EXIT/resource
cleanup/reap. It must also introduce a new service/session epoch, rebuild queue
and caller state, and prevent stale callbacks/frames before clearing anything.
The existing native stack gate and font entry deliberately remain one-shot.
Native Flash placement, loader mappings, extra initializer/decoder footprint,
restart failure handling, native SD font IO and physical Tab5 reuse remain open.


The final experiment passes 199 Python tests and shellcheck. Three positive
lifetimes (two restarts) reproduce all 48 expected matrix hashes with zero
unsupported/runtime-malloc/allocation-record failure counters. Raw font backing
peak is 1,310,976 B each time; retained service backing is 65,792 B before owner
retirement. The peer's 8,388,480 payload bytes (8 MiB charged) remain intact;
after its release the standalone heap recovers all original 15,072,576 B.
Persistent kernel metadata digests are identical before/after each library reset.

The controller-only control faults at `lang_find_or_insert` reading
`0xa5a5a5a5`, after reclaimed backing was overwritten by the peer. The BSS-only
control after a destructive bank loan reaches the renderer freshness trap
before rendering. These controls show two distinct missing obligations; they
are not a claim that arbitrary library resets are safe.

This linked standalone bank has 18,756 B of initialized data, 1,157 B of declared
BSS and zero-filled padding in a 32,768 B template. Only 119 initialized 32-bit
words are nonzero. An offset-u16/value-u32 representation would have 714 B of
patch payload before identity/header/validation/decoder overhead. This is a
format estimate only; no compact codec or native Flash/RAM budget is qualified.
The standalone absolute addresses and matrix-only globals differ from native
firmware, so the standalone template must never be applied to the native bank.
Source, target, initializer, fault and recovery hashes are bound in
[`2026-10-28-font-library-restart.json`](../measurements/2026-10-28-font-library-restart.json).
