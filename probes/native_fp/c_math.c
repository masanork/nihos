#include "abi.h"

#define FP_APP __attribute__((noinline, section(".fp_app")))

FP_APP float nih_fp_c_mix(float a, float b, float c)
{
    return ((a * b) + c) * 0.5f;
}

FP_APP float nih_fp_c_call_zig(float a, float b, float c)
{
    return nih_fp_zig_mix(a, b, c);
}

FP_APP nih_fp_pair nih_fp_c_pair(nih_fp_pair value, float delta)
{
    nih_fp_pair result = { value.x + delta, value.y - delta };
    return result;
}

/* Keep the by-value aggregate call inside C. The pinned Zig aggregate
 * lowering does not match Clang's ILP32F pair convention in this fixture. */
FP_APP void nih_fp_c_pair_into(const nih_fp_pair *value, float delta, nih_fp_pair *result)
{
    *result = nih_fp_c_pair(*value, delta);
}

FP_APP float nih_fp_c_round(float value)
{
    /* At 1.0 this is 1.5 ulps: RNE and RTZ differ and both set NX. */
    return value + 0x1.8p-23f;
}
