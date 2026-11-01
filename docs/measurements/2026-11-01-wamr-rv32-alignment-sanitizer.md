# WAMR RV32 alignment instrumentation

This is an emulator-only investigation of pinned WAMR 2.4.5 commit
`25bd7eb63e828e4bd242cc9b38d260b4b31c6605`. The upstream source and ordinary
build remain unchanged. The opt-in headless profile compiles the RV32 WAMR C
archive with GCC `-fsanitize=alignment -fno-sanitize-recover=alignment` and
uses a test-only trap handler. It does not instrument all Zig, C support code,
assembly, ROM or hardware, and alignment instrumentation is not a general
memory-safety or isolation proof.

GCC's immutable UBSan metadata initially exceeded the linker's 48 KiB SRAM
heap floor. The test build moves only recognized metadata sections to the
WAMR read-only Flash region. The WAMR structural audit checks that section's
permissions. A deliberately misaligned RV32 load, compiled by the same
compiler and using metadata placed in the same read-only region, must hit the
trap and report its source line and address. This negative control passed.
The build guard confines both instrumentation and the deliberate fault to the
headless Wasm session emulator profile.

The [emulator runner](../../probes/wamr-rv32/run-alignment-emulator.sh) checks
the compiler flags and sanitizer references in the classic interpreter,
loader and runtime, then runs the six common-session cases with the pinned,
unpatched WAMR source. It requires normal completion and no alignment trap.
The same six cases are also run without instrumentation. These exercises cover
only the fixture's paths and do not establish safety of arbitrary Wasm modules,
all engine configurations or RV32 hardware. Instrumentation also changes code
and memory layout: the audited WAMR Flash text grows from 183,232 to 215,568
bytes and its Flash rodata from 32,171 to 88,859 bytes in these candidates.
These are section sizes, not device RAM or application-capacity measurements.

On the AArch64 host, the existing comparison still reproduces the stock classic
`WASMBranchBlock` alignment failure under UBSan. The local experimental patch
plus split-access configuration passes its bounded ASan/UBSan fixture and
74 allocation-failure cases. That host patch is not adopted in the RV32 build;
the two architectures' ABI layouts differ. The fast-interpreter loader finding
remains outside this classic-interpreter experiment.

Debug/ReleaseSafe, static analysis, Python regressions and native-session
emulator cases were also run. Exact identities, compiler settings, logs and the
negative-control disassembly are retained in the
[evidence record](evidence/2026-11-01-wamr-rv32-alignment-sanitizer/identity.json).
This does not qualify a device Wasm profile, physical Tab5, remote CI, UI
scanout or network/camera coexistence. A runtime adoption decision remains open.
