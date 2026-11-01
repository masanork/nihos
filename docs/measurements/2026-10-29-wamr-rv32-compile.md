# WAMR RV32 compile-only and bounded Wasm memory

Date: 2026-10-29. Source is the uncommitted Rust SDK worktree based on
`c0ff17d5ea6802eed4769a5b588da1735dbfbd32`. WAMR 2.4.5 is obtained from
its upstream repository and pinned to commit `25bd7eb63e828e4bd242cc9b38d260b4b31c6605`;
it is not vendored. See [the host experiment](2026-10-29-wamr-host.md) for
provenance, license and the earlier host-only memory accounting.

## One-page application fixture

At the time of this recorded run, `sh probes/wamr-host/run-small.sh` built the
module below. The fixture has since gained nested-call and 64-bit tests; see
[the later alignment experiment](2026-10-29-wamr-alignment-lab.md) for its new
module hash and results.
The same test app is linked with a 16 KiB Wasm stack and one 64 KiB initial and
maximum page. It passed both the Node import checks and WAMR classic-interpreter
checks, including the deliberately infinite loop, out-of-bounds import, invalid
text, and rejection of `memory.grow(1)`. Sixteen fresh load/instantiate/invalid-memory
trap/destroy cycles returned the WAMR runtime pool to its original free count;
this checks that pool, not OS-mapped linear memory or all host allocations.
The test host C source SHA-256 is
`bc4dd926711b35014d73404b92388a0424055d290b9f3e4016862d0ffcf2f3d1`.
The 64 KiB is the configured accessible
linear memory of this small fixture, not the runtime's total memory or a proven
stack requirement. The module SHA-256 is
`ee0808605e2c4ee9d5383c93c8b812e9289df069c8b139ca3b950bda0f444d25`.
[Host log](evidence/2026-10-29-wamr-rv32-compile/small-wasm.log).

## Cross-compilation and whole-archive inventory

Run `NIHOS_RISCV_CC=/path/to/riscv32-esp-elf-gcc sh probes/wamr-rv32/run-compile.sh`.
With Espressif GCC 14.2.0, WAMR classic interpreter sources compiled for
`rv32imac_zicsr_zifencei`, `ilp32`, software bounds checks and instruction
metering. The compile-only platform header contains placeholder C types and
now includes the tested single-owner platform model and WAMR's minimal-platform
math implementation. It is still not a kernel port. The whole archive was
combined with `ld -r`
solely to list undefined symbols. The resulting relocatable object identifies
as ELF32 RISC-V, RVC, soft-float; its SHA-256 is
`a04f400599a582e25db7cac8fc2cc4337ca668d047c56434f80ee704f28f41f9`.

The combined object's aggregate `size` output is text 169,505, data 24, BSS
72 bytes. It includes the whole archive and has not undergone final application
linking or garbage collection; this is **not** final firmware size, runtime RAM,
or a prediction of Tab5 memory consumption. The pinned upstream loader emitted
an unused-variable warning in the initial full build.

[Undefined symbols](evidence/2026-10-29-wamr-rv32-compile/undefined.txt) include
the two nihos owner hooks, optional condition/string conversion paths, C
utilities, and compiler-runtime functions. Some are internal
to optional code that final linking may discard; this list is not a minimal
required API. Resolving names alone would not establish correct concurrency,
allocation ownership or safety. The later
[reachable fixed-arena experiment](2026-10-29-wamr-buddy-arena.md) performs
garbage collection, supplies the nihos compatibility subset and Zig compiler
runtime, and produces a symbol-closed probe. Neither result is a nihos platform
port, emulator execution, or device execution.
