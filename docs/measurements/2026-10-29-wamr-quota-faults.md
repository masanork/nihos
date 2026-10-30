# WAMR allocation quotas and failure injection

Date: 2026-10-29. Host-only investigation, uncommitted SDK worktree based on
`c0ff17d5ea6802eed4769a5b588da1735dbfbd32`. WAMR is upstream 2.4.5 at
`25bd7eb63e828e4bd242cc9b38d260b4b31c6605`. The fixed one-page module SHA-256
is `ee0808605e2c4ee9d5383c93c8b812e9289df069c8b139ca3b950bda0f444d25`.

## Separated allocation accounting

The results below are the earlier 58-allocation fixture. The module has since
gained additional tests, so current allocation counts may differ. Run
`sh probes/wamr-quota/run.sh` after `probes/wamr-host/run.sh`. This builds
WAMR with usage-aware allocation and a **host test adapter** that uses system
`malloc`, tracks requested bytes and blocks separately for runtime and linear
memory, and enforces per-category quotas. It is serialized and not a fixed
arena, nihos allocator, thread-safe allocator or protection boundary. The wasm
file buffer, allocator headers, C stack, executable and other host allocations
are outside these numbers. `realloc` allocates first, preserves the old pointer
and bytes on failure, and may conservatively reject an in-place resize.

With a 128 KiB runtime quota and 64 KiB linear quota, the fixed app ran; the
observed requested-byte peaks were 21,714 and 65,536 respectively. A 65,535
byte linear quota failed before linear allocation. In both cases outstanding
adapter-tracked bytes and blocks were zero after cleanup. A single-allocation
fault at each of 58 allocation attempts in the baseline path made the fixture
fail cleanly and return tracked bytes and blocks to zero (58/58). This does not
cover every WAMR execution path, malformed module, callback, host heap leak,
thread schedule, or device. [Result log](evidence/2026-10-29-wamr-quota/results.log).

## Init failure deadlock and bounded workaround

With native imports included in `wasm_runtime_full_init`, injecting failure at
the first allocation timed out. A host sample captured `wasm_runtime_full_init`
waiting on `os_mutex_lock` ([stack](evidence/2026-10-29-wamr-quota/hang-stack.log)).
In the pinned source, failed native registration calls `wasm_runtime_destroy`
inside the full-init internal path; both the outer full-init and destroy paths
acquire the same runtime mutex. This source-level explanation is consistent
with the observed hang on this macOS configuration. The negative control is
bounded by a two-second subprocess timeout. This is not a claim about every
WAMR version or platform.

The fixture instead initializes with zero native symbols, then calls
`wasm_runtime_register_natives` separately and destroys an initialized runtime
on registration failure. All 58 fault cases above used this path. WAMR's
[embedding documentation](https://github.com/bytecodealliance/wasm-micro-runtime/blob/25bd7eb63e828e4bd242cc9b38d260b4b31c6605/doc/embed_wamr.md)
also describes separate registration. This workaround is not a general fix for
all initialization failures, and the upstream code is unchanged.

## UBSan observations: unresolved

The initial successful functional run does not pass UBSan. On AArch64 macOS,
`UBSAN_OPTIONS=halt_on_error=1` stopped the classic interpreter on a misaligned
`WASMBranchBlock` access; the standard WAMR pool reproduces this independently
of the test adapter. A fast-interpreter build also stopped on a separate
misaligned pointer store in the loader. [Classic report](evidence/2026-10-29-wamr-quota/ubsan-classic.log),
[fast report](evidence/2026-10-29-wamr-quota/ubsan-fast.log).
Run `sh probes/wamr-host/run-ubsan.sh classic` or `fast` to reproduce; a
nonzero exit is the observed diagnostic, not a passing test. These are host
64-bit reports. Their cause and relevance to RV32 have not been established;
do not infer either that RV32 is safe or that it exhibits the same fault.

## RV32 compile-only update

The RV32 compile-only configuration now also enables usage-aware allocation,
matching the host experiment. The whole-archive relocatable object reports
text 154,389, data 24 and BSS 72 bytes, SHA-256
`633188db5c2fc073f7676277c1790d7ec34c3381f059d0d1ec9b297b079bcfe5`.
[Undefined symbols](evidence/2026-10-29-wamr-quota/rv32-undefined.txt) remain.
It is not a closed link or final firmware size. No nihos platform, emulator
runtime or physical-device result follows from it.
