# WAMR RV32 alignment corpus handoff

Date: 2026-11-01

Status: implementation paused; reproducible investigation work is intentionally left in an isolated worktree for another agent.

## Resume point

- Repository: `masanork/nihos`
- Tracking issue: https://github.com/masanork/nihos/issues/104
- Worktree: `/private/tmp/nihos-rust-sdk-integration-20261030`
- Branch: `codex/rust-sdk-integration-20261030`
- Last committed base before this handoff: `fdbfbec5`
- Pinned WAMR: `WAMR-2.4.5`, commit `25bd7eb63e828e4bd242cc9b38d260b4b31c6605`
- The main worktree at `/Users/masanork/repo/nihos` was not modified by this investigation.

Do not delete this worktree. The corpus, experimental WAMR patch, generated build trees, and emulator logs are deliberately retained there. Start by running `git status`, reading this document, and reviewing the handoff commit rather than rebuilding the investigation from scratch.

## Goal and current boundary

The goal was to qualify the Rust Wasm application path on the RV32 native nihos emulator with a broader instruction corpus and runtime alignment instrumentation. The work has produced useful failing reproducers, but it has **not** established a safe device Wasm profile. Do not describe this state as production Rust SDK support, Tab5 qualification, or a completed WAMR adoption.

The existing common-session frame bridge and smaller emulator matrix remain useful evidence. This handoff adds a Rust Wasm corpus covering nested calls, wide values, unaligned guest memory, indirect calls, memory growth rejection, explicit trap handling, and recovery.

## Changes left in the handoff commit

- `probes/rust-wasm/`: optional `alignment-corpus` exports and a Node reference test.
- `probes/wamr-native/runner.c`: bounded corpus execution and failure diagnostics.
- `probes/wamr-rv32/run-alignment-corpus.sh`: positive emulator corpus driver.
- `probes/wamr-rv32/run-alignment-corpus-negative.sh`: expected loader-rejection control.
- `probes/wamr-rv32/check-alignment-corpus.py`: corpus/result audit.
- `probes/wamr-rv32/abi_probe.c`: table alignment assertion.
- `probes/wamr-rv32/run-compile.sh`: optional experimental WAMR table-alignment tree.
- `probes/wamr-rv32/patches/table-instance-align-experiment.patch`: experiment only; not approved for adoption.
- `tools/build-native-elf.sh` and `src/platform/native/main.zig`: guarded build flags and diagnostic output.

All new behavior is behind explicit corpus/sanitizer/table-fix flags. The WAMR patch is evidence-generating scaffolding, not a product fix.

## Reproduced findings

### 1. Rust linker encoding and selected WAMR feature policy differ

Without `wasm-ld --compress-relocations`, the Rust module's `call_indirect` uses padded LEB encodings. Node accepts it, while the selected WAMR build rejects it with:

```text
WASM module load failed: zero byte expected. The module uses reference types feature which is disabled in the runtime.
```

The negative control passes and records this distinction:

```sh
cd /private/tmp/nihos-rust-sdk-integration-20261030
sh probes/wamr-rv32/run-alignment-corpus-negative.sh
```

Retained log: `/private/tmp/nihos-corpus-negative-final.log`.

The compressed form (`--compress-relocations`) loads under the selected WAMR configuration and remains accepted by Node. The eventual SDK must make the linker/feature contract explicit rather than relying on an incidental build flag.

### 2. Stock WAMR table instance is misaligned on RV32

With the compressed corpus and RV32 alignment instrumentation, stock pinned WAMR traps before the corpus completes:

```text
NIHOS_WAMR_ALIGN_TRAP .../wasm_runtime.c line=000002e5 address=480416bc align_log2=00000003
```

Retained log: `build/wasm-alignment-corpus-sanitized-compressed/normal.log`.

The address is used as `WASMTableInstance`, whose required alignment is 8 bytes. The first table follows global data without sufficient alignment. The experimental patch aligns table placement and updates size/overflow calculations. It must be reviewed against upstream WAMR layout assumptions, multiple tables, table64, zero globals, and overflow cases before adoption.

### 3. Guest unaligned i64 access reaches misaligned C access

After applying the experimental table patch, the sanitizer advances to the intentionally unaligned guest `i64.store` and traps in the classic interpreter:

```text
NIHOS_WAMR_ALIGN_TRAP .../wasm_interp_classic.c line=00001208 address=48066151 align_log2=00000002
```

Retained log: `build/wasm-alignment-corpus-table-sanitized/normal.log`.

The failing interpreter path performs a wide store through a `uint32 *` derived from an unaligned guest address even though the target configuration reports no unaligned-address support. This needs a WAMR-side implementation or configuration decision that preserves Wasm's legal unaligned memory semantics without C undefined behavior.

### 4. Unsanitized compressed corpus passes, then native invariant fails

Stock WAMR without the alignment sanitizer prints `NIHOS_WAMR_CORPUS_PASS` twice, then terminates at:

```text
NIHOS_NATIVE_FAIL interrupt stack/MIE
```

Retained logs:

- `/private/tmp/nihos-corpus-stock-compressed.log`
- `build/wasm-alignment-corpus-stock-compressed/normal.log`

Do not treat the two pass markers as a successful session test. Determine whether the nested-call corpus exceeds the task stack, corrupts an interrupt invariant, or exposes a separate WAMR/nihOS lifecycle defect. The added diagnostic fields in `main.zig` should be rebuilt and used before changing stack limits.

### 5. Earlier host finding remains open

AArch64 UBSan had already reported misaligned `WASMInterpFrame`/`WASMBranchBlock` access in the classic interpreter. The limited experimental frame patch was not adopted. Evidence remains under:

`docs/measurements/evidence/2026-11-01-wamr-rv32-alignment-sanitizer/`

## Suggested next implementation sequence

1. Rebuild the unsanitized compressed corpus with the new interrupt diagnostic and identify the exact failed invariant. Measure task high-water/stack bounds before increasing any allocation.
2. Split the WAMR work into reviewable upstream-facing fixes:
   - table-instance allocation alignment and overflow accounting;
   - legal unaligned guest load/store handling for RV32 without C UB;
   - classic-interpreter frame/block alignment if still reproducible on the chosen build.
3. Add focused C/Wasm unit reproducers for each WAMR defect. Avoid accepting the combined experimental patch solely because the larger corpus advances farther.
4. Decide and document the Rust SDK Wasm feature/linker profile, including `--compress-relocations`, indirect-call/table support, and rejected proposal features.
5. Rerun the original emulator session matrix plus positive corpus, negative loader control, and sanitizer negative control from a clean build.
6. Only after emulator and host sanitizers are clean, run exact-candidate physical validation. Keep physical display/input, timing, scanout/cache, power-cycle, and remote-CI gates separate.

## Completion criteria

- The supported Rust-produced Wasm format and WAMR feature set are explicit and tested.
- Stock or intentionally patched WAMR runs the corpus without alignment traps or C UB.
- The native interrupt stack/MIE invariant remains valid after repeated corpus execution and teardown.
- The original common-session matrix has no regression and all allocations/session leases are reclaimed.
- Each adopted WAMR patch has a focused regression test and provenance/upstream disposition.
- Documentation distinguishes host, emulator, and exact-candidate physical evidence.

## Preservation notes

- Keep the branch and worktree until the issue is resolved or the investigation is deliberately abandoned.
- Build/log artifacts in this worktree are evidence, not tracked release artifacts.
- Do not merge the experimental WAMR patch to `main` as-is.
- Do not reset or clean the main worktree; it contains unrelated concurrent work.
