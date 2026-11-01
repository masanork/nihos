# WAMR interpreter alignment investigation

Date: 2026-10-29. Research in the uncommitted nihos SDK worktree based on
`c0ff17d5ea6802eed4769a5b588da1735dbfbd32`. WAMR source is the pinned 2.4.5
commit `25bd7eb63e828e4bd242cc9b38d260b4b31c6605`. A separate ignored checkout
holds the experiment; the upstream checkout and production build remain
unchanged. The [experimental patch](../../probes/wamr-host/patches/classic-frame-align-experiment.patch)
has SHA-256 `da8b7979c4d7d60eacb9ea85c37889f2f31f8020e975f2794cc87743336e98c9`.
It is not an adopted dependency fix.

## Counterexample and experiment

On AArch64 macOS, a UBSan report identified classic interpreter access to
`WASMBranchBlock` at a 4-byte but not 8-byte aligned address. In this version,
classic frame sizes are rounded to 4 bytes and the branch area follows a
variable count of 4-byte cells. Pointer-containing frames and branch blocks
have 8-byte alignment on this host. This is a source-based explanation for the
observed addresses, not a proof covering every interpreter configuration.

The local experiment rounds classic frame sizes to pointer alignment and adds
padding before the branch area. It deliberately leaves the fast interpreter's
frame-size rule unchanged. It is run with
`WASM_CPU_SUPPORTS_UNALIGNED_ADDR_ACCESS=0`, using WAMR's split access path;
the patch alone does not fix every C unaligned access when that flag is 1.

Run `sh probes/wamr-host/run-alignment-lab.sh`. It checks the exact upstream
revision and patch, builds stock and patched classic interpreters with
ASan/UBSan, and executes the same one-page Wasm module. The module exercises
drawing, invalid input, out-of-range and invalid-text imports, 20 nested calls,
a 64-bit value, memory growth rejection, an instruction-metered infinite loop
and 16 instantiate/trap/destroy cycles. The stock negative control reproduced
the `WASMBranchBlock` UBSan failure; the patched plus split-access run passed
this fixture. With the same patched/sanitized source and host quota adapter,
74/74 baseline allocation fault points reclaimed tracked bytes and blocks.
[Stock](evidence/2026-10-29-wamr-alignment-lab/stock.log),
[patched](evidence/2026-10-29-wamr-alignment-lab/patched.log), and
[summary](evidence/2026-10-29-wamr-alignment-lab/results.log) are retained.
The module SHA-256 was
`4b226889e627af9ce64ee0b5529d1418cd60afc80944d315ed2b64026dde1710`.

These tests do not establish correctness for GC, exception handling, profiling,
other architectures, arbitrary Wasm programs or concurrency. The original
combined-initialization allocation-failure deadlock remains a separate issue;
this experiment uses separate import registration for the quota test. The fast
interpreter loader's alignment report remains unresolved. No change is proposed
for merging or deployment from this small experiment alone.

## RV32 relevance

`NIHOS_RISCV_CC=/path/to/riscv32-esp-elf-gcc sh probes/wamr-rv32/run-compile.sh`
now compiles [static ABI assertions](../../probes/wamr-rv32/abi_probe.c). For
the selected feature flags and ILP32 build, pointer size and the alignment of
`WASMInterpFrame` and `WASMBranchBlock` are 4 bytes, their relevant offsets are
4-aligned, and WAMR selects its split-access path. The host's 8-byte structural
alignment counterexample therefore does not directly establish the same fault
on this RV32 configuration. It also does not prove the RV32 allocator, frame
bounds, Wasm engine or application safe: no closed link or RV32 execution has
been achieved. [Compile log](evidence/2026-10-29-wamr-alignment-lab/rv32-compile.log).
