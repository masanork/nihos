/* Minimal link-only runtime for standalone size measurements, not production. */
typedef __SIZE_TYPE__ size_t;
void *memcpy(void *dst, const void *src, size_t len) {
    unsigned char *d = dst;
    const unsigned char *s = src;
    for (size_t i = 0; i < len; ++i) d[i] = s[i];
    return dst;
}
void *memset(void *dst, int value, size_t len) {
    unsigned char *d = dst;
    for (size_t i = 0; i < len; ++i) d[i] = (unsigned char)value;
    return dst;
}
