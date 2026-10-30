#include "nihos_c_format.h"
#include "nihos_c_sort.h"
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int compare_int(const void *left, const void *right) {
    const int a=*(const int *)left, b=*(const int *)right;
    return (a>b)-(a<b);
}
struct named { const char *name; unsigned value; };
static int compare_named(const void *left, const void *right) {
    return strcmp(((const struct named *)left)->name,
                  ((const struct named *)right)->name);
}
static uint32_t random_state=1;
static uint32_t random_word(void) {
    random_state=random_state*UINT32_C(1664525)+UINT32_C(1013904223);
    return random_state;
}
#define FORMAT_CASE(format, ...) do { \
    char expected[128], actual[128]; \
    int a=snprintf(expected,sizeof(expected),format,__VA_ARGS__); \
    int b=nih_c_snprintf(actual,sizeof(actual),format,__VA_ARGS__); \
    assert(a==b && strcmp(expected,actual)==0); \
} while (0)

int main(void) {
    struct named exports[]={{"memory",0},{"nih_probe_bad_text",1},{"nih_probe_grow",2},
        {"nih_probe_nested",3},{"nih_probe_raw_text",4},{"nih_probe_spin",5},
        {"nih_probe_wide",6},{"nih_rust_app_frame",7}};
    struct named key={"nih_rust_app_frame",0};
    nih_c_qsort(exports,sizeof(exports)/sizeof(exports[0]),sizeof(exports[0]),compare_named);
    const struct named *named=nih_c_bsearch(&key,exports,sizeof(exports)/sizeof(exports[0]),sizeof(exports[0]),compare_named);
    assert(named && named->value==7);
    for (size_t length=0; length<=64; ++length) {
        int expected[64], actual[64];
        for (size_t i=0; i<length; ++i) expected[i]=actual[i]=(int)(random_word()%23)-11;
        qsort(expected,length,sizeof(expected[0]),compare_int);
        nih_c_qsort(actual,length,sizeof(actual[0]),compare_int);
        assert(memcmp(expected,actual,length*sizeof(actual[0]))==0);
        for (int key=-13; key<=13; ++key) {
            const int *found=nih_c_bsearch(&key,actual,length,sizeof(actual[0]),compare_int);
            assert((found!=NULL)==(bsearch(&key,expected,length,sizeof(expected[0]),compare_int)!=NULL));
            if (found) assert(*found==key);
        }
    }
    assert(nih_c_abs(-7)==7 && nih_c_abs(0)==0 && nih_c_abs(9)==9);
    FORMAT_CASE("%s", "module load failed");
    FORMAT_CASE("%-12.4s", "abcdef");
    FORMAT_CASE("%+08d/% i", -123, 7);
    FORMAT_CASE("%u %#x %#X %#o", 4000000000u, 0x2au, 0x2au, 9u);
    FORMAT_CASE("%hhd %hu %ld %llu", (int)-120, (unsigned)65530, -1234567L, 1234567890123ULL);
    FORMAT_CASE("%jd %zu %td", (intmax_t)INT64_MIN, (size_t)12345, (ptrdiff_t)-33);
    FORMAT_CASE("%*.*s:%c:%%", -9, 3, "abcdef", 'Z');
    char expected[5], actual[5];
    int a=snprintf(expected,sizeof(expected),"error-%08x",0x1234u);
    int b=nih_c_snprintf(actual,sizeof(actual),"error-%08x",0x1234u);
    assert(a==b && memcmp(expected,actual,sizeof(actual))==0);
    assert(nih_c_snprintf(NULL,0,"%s-%u","length",42u)==9);
    assert(nih_c_snprintf(actual,sizeof(actual),"%f",1.0)==-1);
    const char *unsigned_formats[]={"%u","%08u","%.5u","%#x","%#08x","%-12X","%o"};
    const char *signed_formats[]={"%d","%+d","% 9d","%09d","%-11.6d"};
    for (size_t i=0; i<1000; ++i) {
        const unsigned int u=random_word();
        const int d=(int)random_word();
        for (size_t j=0; j<sizeof(unsigned_formats)/sizeof(unsigned_formats[0]); ++j) {
            a=snprintf(expected,sizeof(expected),unsigned_formats[j],u);
            b=nih_c_snprintf(actual,sizeof(actual),unsigned_formats[j],u);
            assert(a==b && strcmp(expected,actual)==0);
        }
        for (size_t j=0; j<sizeof(signed_formats)/sizeof(signed_formats[0]); ++j) {
            a=snprintf(expected,sizeof(expected),signed_formats[j],d);
            b=nih_c_snprintf(actual,sizeof(actual),signed_formats[j],d);
            assert(a==b && strcmp(expected,actual)==0);
        }
    }
    puts("nihos C sort/format compatibility subset: ok");
    return 0;
}
