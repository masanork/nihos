# WAMR integration boundary for nihos

Status: experimental host runtime plus a CPU0-owned native emulator fixture.
WAMR is not enabled in the normal OS profile and has not run on physical hardware. Exact evidence and source
provenance: [RV32 compile](../measurements/2026-10-29-wamr-rv32-compile.md),
[host runtime](../measurements/2026-10-29-wamr-host.md), and
[fixed buddy arenas](../measurements/2026-10-29-wamr-buddy-arena.md), plus the
[native emulator fixture](../measurements/2026-10-29-wamr-native-emulator.md).

## Findings before porting

The host usage-aware allocator experiment and fault injection are recorded
[here](../measurements/2026-10-29-wamr-quota-faults.md). Separate native
registration avoids a reproduced combined-initialization deadlock. UBSan
reports unresolved alignment errors in
both host interpreter modes; a passing ordinary run does not close that gate.
A limited [alignment experiment](../measurements/2026-10-29-wamr-alignment-lab.md)
passes the current host fixture under ASan/UBSan with an experimental classic
patch and split access; the fast path and broader configurations remain open.
The earlier quota adapter uses host malloc and cannot be shipped as the nihos
memory implementation. A later experimental adapter uses the existing nihos
buddy heap with caller-borrowed 128 KiB runtime and 256 KiB linear regions.
Normal return, invalid-range trap, quota rejection, and all 74 injected
allocation failures recover both arenas in the current host fixture. The later
emulator fixture closes one concrete placement and execution path; general task
concurrency, arbitrary modules, service integration and device qualification
remain open.

## First executable fixture

Use one permanent runtime owner, one classic-interpreter instance, no WASI,
JIT, AOT or app threads. Begin with a fixed embedded test module, bounded
synchronous imports, a fixed maximum one-page memory and instruction metering.
Treat the instance as untrusted input even though its first fixture is built
in. Runtime/host ownership must outlive every call and be reclaimed on normal
return, trap and rejected module. Run repeatedly in the host test before RV32.

Keep runtime metadata pool, Wasm linear memory, module bytes, operand stack,
C stack and host-service buffers in separate accounting categories. The
current host pool does not own the platform-mapped linear memory; a pool limit
alone is not an app-wide memory quota. Establish quotas and overflow/OOM
semantics for each before accepting arbitrary modules.

## Module admission boundary

Admission is now a pure policy step before PSRAM allocation or WAMR entry. Its
input is a parsed manifest, the measured bytes/digest, platform limits, and an
attestation state supplied by a different trust component. It fail-closes on
schema and SDK ABI, identity, known and granted services, memory/instruction/
byte quotas, exact length and SHA-256, then origin-specific trust. Built-in
content requires `image_bound`; signed packages require `verified`; unsigned
developer content is disabled unless an explicit development limit enables it.

The emulator now exercises a [canonical package boundary](nihos-app-package.md)
that fixes the exact signed bytes and separates trusted-key status, revocation,
rollback and signature verification from application policy. The raw Wasm is a
build input but is not linked independently. An experimental Ed25519 closure
parses and admits the exact package on RV32 and supplies its authenticated
payload as WAMR's only linked load source. The earlier `image_bound` path remains
a policy mode for built-in content, but is not the origin used by this fixture
and must not be presented as a publisher signature.
Production signature/key algorithms, publisher key lifecycle, persistent trust
storage, a qualified storage adapter, and UI consent remain undecided. The
two-slot host model fixes install ordering and a package-sequence/trust-epoch
record. A separate model orders authenticated trust snapshots before an external
monotonic epoch. Neither is connected to a nihos medium or protected counter.
An experimental boot coordinator now composes those journals in the required
order and returns application bytes only after current trust re-admission. Its
full closure compiles for RV32 and its host test rejects concurrent owners,
active recovery authority, revoked packages and future trust epochs. The WAMR
emulator fixture now copies build-generated journal images into private mutable
media, recovers sequence 1, proves a commit-write interruption recovers sequence
1 through a fresh coordinator, then retries sequence 2, replaces the coordinator
again, and loads only recovered sequence 2. This verifies the native contract in one
process; it does not use a persistent or power-qualified nihos medium.
Only the package trust layer may construct `verified`; WAMR and host services
must not infer trust from a module-provided flag.

## Platform obligations

The [native owner fixture](../measurements/2026-10-30-wamr-native-owner.md)
now binds admitted graphics rights to each WAMR instance through private custom
data. Native imports reject missing rights, inactive/mismatched owners and
detached contexts; teardown deactivates and detaches each owner before instance
destruction. This is executed on RV32 under the emulator while retaining the
single-CPU0 synchronous service model.
The [surface extension](../measurements/2026-10-30-wamr-native-surface.md) now
passes authorized imports to the existing native renderer. A guarded, padded
64x16 RGB565 surface is borrowed from the private stack and detached before
release. Native checks verify background/first-glyph pixels, no frame-checksum
change on rejected calls, padding/guard integrity and both instance lifecycles.
The [owner-dispatch extension](../measurements/2026-10-30-wamr-native-events.md)
adds a synthetic two-state input model and counted synchronous frames. Invalid
input, an already open scope, a stopped owner and graphics calls outside a
scope are rejected. The busy probe simulates an open scope; it does not qualify
concurrent callers or interrupt re-entry.
The [external UART fixture](../measurements/2026-10-30-wamr-native-uart.md)
then connects ROM console RX to that owner, using READY-triggered emulator
injection and a bounded receive loop. Both a valid input/quit sequence and the
no-input timeout run release owners, surface and arenas before completion or
the expected fixture failure diagnostic.
The same candidate passes a six-case UART failure matrix covering partial
input, early quit, receive overflow, invalid order and a fourth frame request,
as well as no input. Failure counters and complete cleanup are checked per case.
The [full-surface extension](../measurements/2026-10-30-wamr-native-full-surface.md)
gives the owner a separate 32 KiB rendering segment and checks the app's entire
160x80 logical output. This removes frame storage from the call stack and keeps
surface lifetime within the one PSRAM lease; scanout publication remains open.

- **Execution ownership:** only the designated owner may enter WAMR; interrupt
  handlers and other harts must not call it. Verify what WAMR's global state,
  mutexes and callbacks require under this model before choosing actual locks.
  No-op mutexes and fabricated thread IDs are not a production port.
- **Memory:** provide correctly aligned, bounded allocation and mapping with
  explicit owner/lifetime, failure and reclamation. Do not assume the existing
  task C allocator's 4096-byte maximum can supply a 64 KiB linear memory.
  No PMP/MMU means no native hardware isolation; WAMR checks must stay enabled.
- **C and architecture:** use the existing pinned compatibility boundary where
  valid, independently account for format/string/math and software-FP helper
  needs, and verify actual calling convention and no unavailable instructions.
  Do not silently pull a hosted libc or ESP-IDF/FreeRTOS into native boot.
- **Time, stack and termination:** implement monotonic time and honest stack
  boundaries; specify what execution limits mean across Wasm and host calls.
  A guest trap or task termination must not assume Rust `Drop` ran. Long or
  blocking host services need their own bounded cancellation design.
- **Services:** validate Wasm offsets and lengths before mapping; define copying,
  UTF-8/ASCII behavior, rights, lifetime and maximum sizes. Display/input remain
  owner-mediated; don't expose native pointers or DMA memory to Wasm.

## Acceptance order

1. Host fault injection: undersized metadata/linear arenas, malformed modules,
   out-of-range imports, unsupported text, budget exhaustion, and repeated
   instantiate/trap/destroy. Sixteen invalid-memory trap cycles already return
   the WAMR pool to baseline; OS-mapped linear memory and app-owned resources
   still need independent leak and OOM checks. The fixed buddy fixture now also
   rejects a 65,535-byte linear quota, proves that a 64 KiB runtime arena is too
   small for this path, and passes 74/74 allocation failures with full recovery.
2. Symbol-closed RV32 link with explicit platform/C/math implementations and an
   audit of section sizes and instruction set. A reproducible link-only ELF now
   has zero undefined symbols using WAMR's math, nihos C compatibility helpers,
   and Zig compiler runtime. The compile/test model
   covers nonrecursive single-owner mutexes and reduces platform obligations to
   monotonic time and an honest native-stack boundary, but neither hook is
   connected to nihos. This satisfies symbol closure, not boot, runtime, stack,
   scheduler, or memory-placement acceptance.
3. Emulator: a fixed Rust module now instantiates from a task-owned PSRAM lease,
   calls bounded drawing imports, propagates a host error, rejects invalid text,
   traps an invalid range, stops a spin at 10,000 instructions and returns both
   buddy arenas before the existing dual-core qualification reaches 300 rounds.
   A second fresh copy of the same fixed module now completes after the first
   trap-heavy lifecycle returns every tracked allocation to its baseline.
   Before both lifecycles, the native owner parses the canonical package and
   admits it only when the trusted key, revocation/rollback snapshot, strict
   Ed25519 signature, SDK ABI, graphics grant, quotas, length and recomputed
   SHA-256 all match. Only its authenticated payload is copied into the mutable
   WAMR buffers. A one-byte-truncated package is rejected as a native negative
   control, and the structural audit rejects any separately linked raw-Wasm
   blob.
   Multiple application identities and general service/task scheduling remain
   open.
4. Physical Tab5: matching candidate bytes, real display/input, internal RAM and
   PSRAM/stack peaks, latency and cancellation/ownership tests. Separate visual
   confirmation and cold-power evidence from emulator results.
