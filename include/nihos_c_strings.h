#ifndef NIHOS_C_STRINGS_H
#define NIHOS_C_STRINGS_H
#include <stddef.h>
#ifdef NIH_C_TEST_PREFIX
#define NIH_C_NAME(name) nih_c_##name
#else
#define NIH_C_NAME(name) name
#endif
/* Standard C byte/string contracts: readable buffers and terminating NULs are
 * caller requirements. No allocation, locale, global state or interrupt mask.
 * memcpy/memmove/memset/memcmp/strlen are supplied by pinned Zig compiler_rt. */
void *NIH_C_NAME(memchr)(const void *data, int byte, size_t length);
int NIH_C_NAME(strcmp)(const char *left, const char *right);
int NIH_C_NAME(strncmp)(const char *left, const char *right, size_t length);
char *NIH_C_NAME(strchr)(const char *text, int byte);
char *NIH_C_NAME(strcpy)(char *destination, const char *source);
char *NIH_C_NAME(strrchr)(const char *text, int byte);
size_t NIH_C_NAME(strspn)(const char *text, const char *accept);
size_t NIH_C_NAME(strcspn)(const char *text, const char *reject);
double NIH_C_NAME(fabs)(double value);
#endif
