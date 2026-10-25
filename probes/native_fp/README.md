# Native FP C boundary

`sh tools/run-native-smoke.sh compiled` builds these functions with ILP32F
and exercises them from compiler-generated Zig tasks on both native harts.
It checks three float arguments, a float result, C-to-Zig callbacks and a
two-float structure through a pointer adapter. An integer oracle supplies
exact expected bits; RNE/RTZ and the inexact flag are checked separately.

Use `nih_fp_c_pair_into` from Zig. The direct by-value `nih_fp_c_pair` call
did not agree with the pinned Zig 0.17.0 caller in bring-up: for x=0.25 and
delta=0.25, the observed x result was 0.25 instead of 0.5. The adapter keeps
that by-value call entirely within C. This observation is not a qualification
of arbitrary aggregate, variadic or double-precision C interfaces.

All FP task functions are placed in `.fp_app`. The ELF audit scans RV32
16/32-bit executable instructions, rejects FP operations outside that region
and the named raw-transfer helpers, and requires generated FP instructions
from both C and Zig. This audit and the runtime tests are separate evidence.
