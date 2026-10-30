#ifndef NIHOS_C_FORMAT_H
#define NIHOS_C_FORMAT_H
#include <stdarg.h>
#include <stddef.h>
#ifdef NIH_C_TEST_PREFIX
#define NIH_C_FORMAT_NAME(name) nih_c_##name
#else
#define NIH_C_FORMAT_NAME(name) name
#endif
/* Allocation-free integer/string subset used by the WAMR classic runtime:
 * flags -+ #0, numeric or * width/precision, hh/h/l/ll/j/z/t lengths, and
 * conversions %, c, s, d, i, u, o, x, X, p. Floating conversions are rejected. */
int NIH_C_FORMAT_NAME(vsnprintf)(char *output, size_t capacity,
                                const char *format, va_list arguments);
int NIH_C_FORMAT_NAME(snprintf)(char *output, size_t capacity,
                               const char *format, ...);
#endif
