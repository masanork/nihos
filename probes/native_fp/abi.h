#pragma once

typedef struct { float x, y; } nih_fp_pair;
_Static_assert(sizeof(nih_fp_pair) == 8, "FP pair ABI size");
_Static_assert(_Alignof(nih_fp_pair) == 4, "FP pair ABI alignment");

float nih_fp_zig_mix(float a, float b, float c);
float nih_fp_c_mix(float a, float b, float c);
float nih_fp_c_call_zig(float a, float b, float c);
nih_fp_pair nih_fp_c_pair(nih_fp_pair value, float delta);
void nih_fp_c_pair_into(const nih_fp_pair *value, float delta, nih_fp_pair *result);
float nih_fp_c_round(float value);
