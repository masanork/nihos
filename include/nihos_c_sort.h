#ifndef NIHOS_C_SORT_H
#define NIHOS_C_SORT_H
#include <stddef.h>
#ifdef NIH_C_TEST_PREFIX
#define NIH_C_SORT_NAME(name) nih_c_##name
#else
#define NIH_C_SORT_NAME(name) name
#endif
void NIH_C_SORT_NAME(qsort)(void *base, size_t count, size_t width,
                            int (*compare)(const void *, const void *));
void *NIH_C_SORT_NAME(bsearch)(const void *key, const void *base, size_t count,
                               size_t width,
                               int (*compare)(const void *, const void *));
int NIH_C_SORT_NAME(abs)(int value);
#endif
