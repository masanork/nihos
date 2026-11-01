/* Allocation-free, non-recursive C sorting/searching helpers. */
#include "nihos_c_sort.h"

static void swap_bytes(unsigned char *left, unsigned char *right, size_t width) {
    for (size_t i = 0; i < width; ++i) {
        const unsigned char byte = left[i];
        left[i] = right[i];
        right[i] = byte;
    }
}

static void sift(unsigned char *base, size_t root, size_t end, size_t width,
                 int (*compare)(const void *, const void *)) {
    while (end != 0 && root <= (end - 1) / 2) {
        size_t child = root * 2 + 1;
        if (child < end && compare(base + child * width,
                                   base + (child + 1) * width) < 0) ++child;
        if (compare(base + root * width, base + child * width) >= 0) return;
        swap_bytes(base + root * width, base + child * width, width);
        root = child;
    }
}

void NIH_C_SORT_NAME(qsort)(void *storage, size_t count, size_t width,
                            int (*compare)(const void *, const void *)) {
    if (!storage || !compare || count < 2 || width == 0) return;
    unsigned char *base = storage;
    size_t start = (count - 2) / 2 + 1;
    while (start != 0) {
        --start;
        sift(base, start, count - 1, width, compare);
    }
    for (size_t end = count - 1; end != 0; --end) {
        swap_bytes(base, base + end * width, width);
        sift(base, 0, end - 1, width, compare);
    }
}

void *NIH_C_SORT_NAME(bsearch)(const void *key, const void *storage,
                               size_t count, size_t width,
                               int (*compare)(const void *, const void *)) {
    if (!key || !storage || !compare || width == 0) return NULL;
    const unsigned char *base = storage;
    size_t low = 0, high = count;
    while (low < high) {
        const size_t middle = low + (high - low) / 2;
        const int order = compare(key, base + middle * width);
        if (order < 0) high = middle;
        else if (order > 0) low = middle + 1;
        else return (void *)(base + middle * width);
    }
    return NULL;
}

int NIH_C_SORT_NAME(abs)(int value) { return value < 0 ? -value : value; }
