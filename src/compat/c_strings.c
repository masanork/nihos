/* Small allocation-free additions to Zig compiler_rt, not a general libc. */
#include "nihos_c_strings.h"
#include <stdint.h>
_Static_assert(sizeof(double) == 8 && __DBL_MANT_DIG__ == 53 && __DBL_MAX_EXP__ == 1024,
               "fabs requires IEEE binary64");
void *NIH_C_NAME(memchr)(const void *data, int byte, size_t length) {
    const unsigned char *bytes = data;
    const unsigned char match = (unsigned char)byte;
    for (size_t i = 0; i < length; ++i) if (bytes[i] == match) return (void *)(bytes + i);
    return NULL;
}
int NIH_C_NAME(strcmp)(const char *left, const char *right) {
    const unsigned char *a = (const unsigned char *)left, *b = (const unsigned char *)right;
    while (*a && *a == *b) { ++a; ++b; }
    return (int)*a - (int)*b;
}
int NIH_C_NAME(strncmp)(const char *left, const char *right, size_t length) {
    const unsigned char *a = (const unsigned char *)left, *b = (const unsigned char *)right;
    for (size_t i = 0; i < length; ++i) {
        if (a[i] != b[i] || !a[i]) return (int)a[i] - (int)b[i];
    }
    return 0;
}
char *NIH_C_NAME(strcpy)(char *destination, const char *source) {
    char *start = destination;
    do { *destination++ = *source; } while (*source++);
    return start;
}
char *NIH_C_NAME(strchr)(const char *text, int byte) {
    const unsigned char match = (unsigned char)byte;
    for (;;) {
        if ((unsigned char)*text == match) return (char *)text;
        if (!*text) return NULL;
        ++text;
    }
}
char *NIH_C_NAME(strrchr)(const char *text, int byte) {
    const unsigned char match = (unsigned char)byte;
    const char *last = NULL;
    do {
        if ((unsigned char)*text == match) last = text;
    } while (*text++);
    return (char *)last;
}
static int contains(const char *set, unsigned char byte) {
    for (; *set; ++set) if ((unsigned char)*set == byte) return 1;
    return 0;
}
size_t NIH_C_NAME(strspn)(const char *text, const char *accept) {
    size_t length = 0;
    while (text[length] && contains(accept, (unsigned char)text[length])) ++length;
    return length;
}
size_t NIH_C_NAME(strcspn)(const char *text, const char *reject) {
    size_t length = 0;
    while (text[length] && !contains(reject, (unsigned char)text[length])) ++length;
    return length;
}
double NIH_C_NAME(fabs)(double value) {
    union { double value; uint64_t bits; } representation = { .value = value };
    representation.bits &= UINT64_C(0x7fffffffffffffff);
    return representation.value;
}
