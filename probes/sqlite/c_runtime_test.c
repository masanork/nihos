#include "nihos_c_strings.h"
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static uint32_t random_state = 0x9e3779b9;
static uint32_t next(void) { random_state ^= random_state << 13; random_state ^= random_state >> 17; random_state ^= random_state << 5; return random_state; }
static int sign(int n) { return (n > 0) - (n < 0); }
static size_t offset(const char *base, const void *p) { return p ? (size_t)((const char *)p - base) : SIZE_MAX; }
#define CHECK(value) do { if (!(value)) { fprintf(stderr, "C runtime check failed line=%d\n", __LINE__); exit(1); } } while (0)
int main(void) {
    for (size_t round = 0; round < 4096; ++round) {
        char a[65], b[65], set[17];
        size_t an = next() % 65, bn = next() % 65, sn = next() % 17;
        for (size_t i = 0; i < an; ++i) a[i] = (char)(1 + next() % 255);
        for (size_t i = 0; i < bn; ++i) b[i] = (char)(1 + next() % 255);
        for (size_t i = 0; i < sn; ++i) set[i] = (char)(1 + next() % 255);
        a[an] = b[bn] = set[sn] = 0;
        if (round % 4 == 0) { memcpy(b, a, an + 1); bn = an; }
        char copied[67], reference[67];
        memset(copied, 0x5a, sizeof(copied));
        memset(reference, 0x5a, sizeof(reference));
        CHECK(nih_c_strcpy(copied + 1, a) == copied + 1);
        CHECK(strcpy(reference + 1, a) == reference + 1);
        CHECK(memcmp(copied, reference, sizeof(copied)) == 0);
        CHECK(sign(nih_c_strcmp(a, b)) == sign(strcmp(a, b)));
        for (size_t n = 0; n <= 64; ++n) {
            CHECK(sign(nih_c_strncmp(a, b, n)) == sign(strncmp(a, b, n)));
        }
        for (int c = -256; c < 512; c += 17) {
            CHECK(offset(a, nih_c_memchr(a, c, an + 1)) == offset(a, memchr(a, c, an + 1)));
            CHECK(offset(a, nih_c_strchr(a, c)) == offset(a, strchr(a, c)));
            CHECK(offset(a, nih_c_strrchr(a, c)) == offset(a, strrchr(a, c)));
        }
        CHECK(nih_c_memchr(a, 0, 0) == NULL);
        CHECK(offset(a, nih_c_strchr(a, 0)) == an);
        CHECK(offset(a, nih_c_strrchr(a, 0)) == an);
        CHECK(nih_c_strspn(a, set) == strspn(a, set));
        CHECK(nih_c_strcspn(a, set) == strcspn(a, set));
    }
    const uint64_t cases[] = {0, UINT64_C(0x8000000000000000), UINT64_C(0x3ff0000000000000),
        UINT64_C(0xbff0000000000000), UINT64_C(0x7ff0000000000000), UINT64_C(0xfff0000000000000),
        UINT64_C(0xfff8000000000042), UINT64_C(0xfff0000000000042), UINT64_C(0x8000000000000001)};
    for (size_t i = 0; i < sizeof cases / sizeof cases[0]; ++i) {
        union { uint64_t bits; double value; } input = { .bits = cases[i] }, output;
        output.value = nih_c_fabs(input.value);
        CHECK(output.bits == (cases[i] & UINT64_C(0x7fffffffffffffff)));
    }
    puts("C runtime host PASS: 4096 differential byte/string cases, binary64 sign/payload preservation");
    return 0;
}
