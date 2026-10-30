/* Compile-time evidence only; no runtime platform implementation. */
#include <stddef.h>
#include "wasm_interp.h"
#include "wasm_exec_env.h"
_Static_assert(sizeof(void *) == 4, "RV32 pointer ABI required");
_Static_assert(_Alignof(WASMBranchBlock) == 4, "branch block alignment changed");
_Static_assert(_Alignof(WASMInterpFrame) == 4, "interpreter frame alignment changed");
_Static_assert(offsetof(WASMInterpFrame, lp) % 4 == 0, "cell base must be aligned");
_Static_assert(offsetof(WASMExecEnv, wasm_stack_u.bottom) % 4 == 0, "stack base must be aligned");
_Static_assert(WASM_CPU_SUPPORTS_UNALIGNED_ADDR_ACCESS == 0, "split access path required");
