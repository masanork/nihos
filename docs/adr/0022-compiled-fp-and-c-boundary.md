# ADR 0022: Compiler-generated FP tasks and an explicit ILP32F C boundary

- Status: accepted; bounded emulator qualification
- Date: 2026-10-26

## Decision

Add a third `compiled` build mode beside the integer and raw-bank floating
fixtures. The pinned Zig compiler chooses ILP32F when F is enabled. Keep
that standard hard-float ABI for this mode, including its C helpers, rather
than forcing incompatible ELF objects together. Existing modes retain ILP32.

This mode enables F in the compilation target, but enforces integer kernel
instructions in the resulting binary. Only task code in `.fp_app` and the
named raw context-transfer helpers may contain FP operations or FP CSR
accesses. An instruction audit checks executable RV32 16/32-bit encodings;
it rejects FP arithmetic, loads/stores, fused operations and fcsr-family
access outside the approved regions. Live IRQ dispatch still requires
FS=Off and MIE=0. This supersedes the no-F *compilation target* rule of ADR
0021 only for compiled mode; the kernel instruction rule is retained.

## Arithmetic, ABI and preemption

Zig FP tasks call C functions with three f32 arguments and an f32 result;
a C helper calls a Zig-exported calculation in the reverse direction.
An independent integer oracle supplies exact IEEE bits for 16 dyadic test
vectors. FP contraction is disabled in C and strict mode is used in Zig.
The fixture also alternates RNE/RTZ between tasks and uses an inexact
halfway addition that must produce different results and retain the NX flag.

Two busy tasks per hart carry compiler-managed FP values while running
without voluntary yields. Lifecycle tasks hold an FP value across sleep
and yield. A protocol wrapper holds an FP value across the shared native
IPI service, whose event waits and running-task self-IPI retain their earlier
qualification. Compiler-generated code uses callee-saved FP registers; the
kernel continues to save all 32 registers plus fcsr for opted-in contexts.

The captured PC must fall inside `.fp_app` on at least four timer interrupts
per owner. Merely assigning an FP bank to a task cannot satisfy this test.
The final ELF must also contain generated FP instructions from both C and
Zig. These observations show actual generated FP code under preemption,
not a throughput or same-cycle execution measurement.

Each activation still checks an initially zero physical bank. The compiled
fixture verifies the saved rounding/flag state before reaping and checks
arithmetic results during execution. Raw floating mode independently retains
the complete signature check on every register and the final saved bank.
Both modes require balanced copies, capture accounting and final integer
bootstrap quiescence. No task stack or heap is added.

## Aggregate ABI finding and adapter

A direct Zig declaration of a C two-float structure argument/result did not
match the pinned caller/callee behavior in this test. The expected x result
of 0.5 was observed as 0.25. Layout checks agreed on size 8, alignment 4 and
y offset 4; scalar float calls and the reverse callback passed. This is a
recorded toolchain-boundary finding, not a determination of an upstream root
cause or a general statement about every aggregate ABI.

Use a thin C adapter with input/output structure pointers and a scalar
float delta. The by-value structure call then occurs within the C translation
unit. Both members are checked against exact bits on every probe iteration.
Do not expose the direct by-value declaration as a qualified Zig interface.
This keeps C assets usable through a narrow, reviewable boundary while
leaving direct aggregate ABI support as a distinct gate.

## Build and qualification

Normal architecture CI builds and audits six ELFs (two revision profiles,
three modes) without IDF. The native workflow boots all three modes without
PSRAM and sequentially builds the three physical images using their shared
stock loader. The audit can run with `--elf-only`, so kernel FP instruction
checks do not depend on an installed SDK or emulator.

The integer oracle adds a host test. Twenty log-validator tests require
the requested mode and generated-code PC captures; three decoder tests
distinguish compressed integer stack operations and machine CSRs from FP
instructions. Deliberate kernel FP, wrong ABI and misplaced app-code mutants
are rejected in local ELF checks. The existing integer and raw-bank smokes
remain independent regressions.

This step qualifies the tested single-precision scalar/callback and
pointer-aggregate interfaces. Direct by-value aggregates, variadic calls,
f64, general libc behavior, migration, nested traps, physical rev1 behavior,
PSRAM/display and protection domains remain separate work. No Quake FPS or
production compiler-ABI completeness is asserted.

## References

- [ADR 0021: Native FP ownership](0021-native-opt-in-floating-contexts.md)
- [Compiled task code](../../src/arch/riscv32/compiled_fp.zig)
- [C boundary and its limitation](../../probes/native_fp/README.md)
- [Independent integer oracle](../../src/kernel/fp_vectors.zig)
- [ELF and instruction audit](../../tools/check-native-image.py)
