# WAMR fixed buddy arenas

Date: 2026-10-29. Experimental host execution and RV32 compile-only inventory
in the uncommitted SDK worktree based on
`c0ff17d5ea6802eed4769a5b588da1735dbfbd32`. WAMR is upstream 2.4.5 at
`25bd7eb63e828e4bd242cc9b38d260b4b31c6605`. This is not linked into nihos,
has not run in its emulator, and has no physical-device result.

## Ownership and reservation

[`arena.zig`](../../probes/wamr-arena/arena.zig) adapts the existing nihos
buddy heap to WAMR's usage-aware allocator. One serialized owner borrows two
disjoint, 64-byte-aligned regions supplied by its caller for the adapter's
whole lifetime:

- runtime metadata: 128 KiB reserved, 126,848 bytes initially usable;
- one-page Wasm linear memory: 256 KiB reserved, 253,824 bytes initially usable;
- total borrowed reservation: 393,216 bytes.

The regions are separate so a linear-memory request cannot consume runtime
metadata capacity. Initialization rejects null, misaligned, overlapping, and
wrong-sized regions. Allocation records are bounded at 128 live objects per
arena. Wrong-owner, unknown-pointer, double-free, invalid-kind, oversized, and
object-table-exhaustion cases are covered by the Zig test. The adapter has no
concurrent-call protection, stale-pointer protection after address reuse, or
physical placement policy; those remain responsibilities of the future nihos
owner.

## Host result

Run
`NIHOS_ZIG=/path/to/zig-0.17.0 sh probes/wamr-arena/run-aligned-sanitize.sh`.
It rebuilds the same fixed one-page Rust Wasm module, runs the arena unit test,
then uses WAMR's classic interpreter with the local alignment experiment and
split unaligned-access path. The module SHA-256 is
`4b226889e627af9ce64ee0b5529d1418cd60afc80944d315ed2b64026dde1710`.

The normal run requested peaks of 22,173 runtime bytes and 65,536 linear bytes.
Buddy block reservation peaked at 38,976 and 131,072 bytes respectively. The
normal call, an invalid guest-range trap, and a 65,535-byte linear quota failure
all returned both arenas to their initial free-byte counts with valid guards.
Injecting failure independently at all 74 baseline allocation attempts also
recovered both arenas. The final pass repeated the trap and 74/74 sweep with
WAMR under ASan/UBSan and the Zig adapter built ReleaseSafe.
[Concise result](evidence/2026-10-29-wamr-buddy-arena/results.log) and
[sanitizer result](evidence/2026-10-29-wamr-buddy-arena/sanitize.log) are
retained.

A temporary 64 KiB runtime-arena variant was a useful negative control: the
arena recovered fully, but the ordinary app did not complete. The adopted
experiment therefore remains at 128 KiB; this is fixture evidence, not a
general production minimum. [Negative result](evidence/2026-10-29-wamr-buddy-arena/runtime-64k-negative.log).

## RV32 inventory

`run-rv32-inventory.sh` rebuilds the adapter for
`rv32imac_zicsr_zifencei`/ILP32 and performs a reachability-only partial link.
The borrowed 384 KiB is not embedded in the adapter object. `arena.o` is 9,114
bytes text, zero data and 8,328 bytes BSS; its BSS is adapter metadata and the
bounded allocation tables. SHA-256 is
`3b2acd1f94e7cdb4c19388f40d0c503cd54c38fc778149ff00ab22f0f1b98726`.
The RV32 script omits debug sections; two consecutive rebuilds produced that
same hash.

The partially garbage-collected WAMR, arena, and freestanding C compatibility
inventory is 103,541 bytes text,
24 bytes data and 8,377 bytes BSS, SHA-256
`6babf9e870e461b6d4f0b693eec5688e151854e2b27a5b5c7fca6467fad6a2f9`.
The compile/test-only single-owner platform model rejects recursive mutex
entry and leaves only monotonic-time and real native-stack-boundary hooks to a
future nihos owner; its host contract test passes. The inventory still has
those two hooks plus Zig-supplied memory and compiler-runtime imports listed in
the [undefined-symbol inventory](evidence/2026-10-29-wamr-buddy-arena/rv32-undefined.txt).
The WAMR revision's own BSD-licensed minimal-platform math source supplies the
previously unresolved math API, adding 4,628 reachable text bytes. Its license
must be retained with any vendored WAMR source.

The added nihos C compatibility subset provides allocation-free,
non-recursive heapsort/binary search and integer/string-only bounded formatting.
Host differential tests compare sorting for lengths 0 through 64 and more than
12,000 formatting cases against the host C library. Floating formatting is
deliberately rejected and is not part of this WAMR configuration's reachable
format requirements. The same suite passes ASan/UBSan via
`probes/wamr-rv32/run-compat-sanitize.sh`.

## Symbol-closed RV32 probe

[`run-rv32-closed-link.sh`](../../probes/wamr-arena/run-rv32-closed-link.sh)
passes the remaining compiler helpers and memory routines to the same Zig
final linker used by native nihos. It first verifies the unstripped ELF has no
undefined symbols, then removes debug sections while retaining the symbol table
and verifies again. Two consecutive builds produced SHA-256
`fdbc5e3b888dcadd58ac3b22c0d87ff75ee0775e36f8cbc75311dd6847a89dde`.
The ELF is RV32 RVC soft-float and reports text 111,658, data 24 and BSS 418,036
bytes. The BSS includes the probe's concrete 128 KiB runtime arena, 256 KiB
linear arena, 16 KiB placeholder stack region, and adapter/runtime state.
[Result](evidence/2026-10-29-wamr-buddy-arena/closed-link.log).

This closes symbols only. Its monotonic-clock and stack-boundary functions are
explicit link placeholders; its entry is not wired to nihos startup, scheduler,
task ownership, imports, or the real Rust Wasm module. The ELF is not bootable,
has not executed under the nihos emulator, and is not a firmware size result.
The later [native emulator fixture](2026-10-29-wamr-native-emulator.md) supplies
a separate real owner and executable image; it does not retroactively turn this
link-only artifact into runtime evidence.
The relocatable inventory is not an executable or final firmware size. The
separate closed-link probe establishes symbol closure, but not runtime
correctness.
