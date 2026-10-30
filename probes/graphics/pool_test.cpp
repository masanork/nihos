#include "lazy_pool.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "pool check failed: %s:%d: %s\n", __FILE__, __LINE__, #x); abort(); } } while (0)

int main() {
    LazyPool pool;
    CHECK(pool.reserved == 0 && pool.valid());
    void *a = pool.allocate(1, 33), *b = pool.allocate(2, 40);
    CHECK(a && b && pool.reserved == 2 * LazyPool::page_bytes);
    memset(b, 0x5a, 40);
    CHECK(!pool.release(2, a) && !pool.release(1, (char *)a + 1));
    CHECK(!pool.release(1, (void *)(uintptr_t)1));
    CHECK(pool.release(1, a) && pool.owner_reserved[1] == 0);
    CHECK(!pool.release(1, a));
    for (unsigned i = 0; i < 40; ++i) CHECK(((unsigned char *)b)[i] == 0x5a);
    // Reuse an interior record hole while the higher record remains live.
    a = pool.allocate(1, 64); CHECK(a && pool.valid());
    CHECK(pool.release(1, a) && pool.valid());
    CHECK(pool.release(2, b) && pool.reserved == 0);

    a = pool.allocate(1, 33); CHECK(a);
    size_t usable = pool.capacity(1, a);
    memset(a, 0xc7, usable);
    CHECK(pool.resize(1, a, 1) == a);
    pool.begin_operation(1);
    CHECK(!pool.resize(1, a, 100000));
    CHECK(pool.capacity(1, a) == usable);
    for (size_t i = 0; i < usable; ++i) CHECK(((unsigned char *)a)[i] == 0xc7);
    pool.begin_operation();
    b = pool.resize(1, a, 100000); CHECK(b);
    for (size_t i = 0; i < usable; ++i) CHECK(((unsigned char *)b)[i] == 0xc7);
    CHECK(pool.release(1, b) && pool.reserved == 0);
    CHECK(!pool.allocate(1, SIZE_MAX) && !pool.allocate(LazyPool::owners, 16));
    CHECK(!pool.allocate(1, 0) && pool.release(1, nullptr));

    pool.owner_limit[1] = LazyPool::page_bytes;
    a = pool.allocate(1, 60000); CHECK(a); memset(a, 0xd1, 60000);
    CHECK(!pool.resize(1, a, 70000));
    for (unsigned i = 0; i < 60000; ++i) CHECK(((unsigned char *)a)[i] == 0xd1);
    CHECK(pool.release(1, a)); pool.owner_limit[1] = 1024 * 1024;
    void *records[LazyPool::record_count];
    for (void *&pointer : records) { pointer = pool.allocate(1, 16); CHECK(pointer); }
    CHECK(!pool.allocate(1, 16));
    CHECK(pool.live_records == LazyPool::record_count && pool.peak_records == LazyPool::record_count);
    CHECK(pool.record_failures == 1);
    for (void *pointer : records) CHECK(pool.release(1, pointer));
    CHECK(pool.reserved == 0 && pool.live_records == 0 && pool.valid());

    // Interleaved lifetimes, fragmentation, realloc moves and byte preservation.
    void *live[48] = {};
    uint32_t random = 0x51c7a93u;
    for (unsigned step = 0; step < 3000; ++step) {
        random = random * 1664525u + 1013904223u;
        unsigned slot = random % 48, owner = slot % 2 + 1;
        if (live[slot]) {
            size_t previous = pool.capacity(owner, live[slot]);
            for (size_t i = 0; i < previous; ++i) CHECK(((unsigned char *)live[slot])[i] == (unsigned char)slot);
            if (random & 0x100) {
                CHECK(pool.release(owner, live[slot])); live[slot] = nullptr;
            } else {
                size_t bytes = (random >> 9) % 17000 + 1;
                void *next = pool.resize(owner, live[slot], bytes);
                if (next) {
                    size_t capacity = pool.capacity(owner, next);
                    for (size_t i = 0; i < (previous < capacity ? previous : capacity); ++i)
                        CHECK(((unsigned char *)next)[i] == (unsigned char)slot);
                    live[slot] = next; memset(next, slot, capacity);
                }
            }
        } else {
            live[slot] = pool.allocate(owner, (random >> 8) % 17000 + 1);
            if (live[slot]) memset(live[slot], slot, pool.capacity(owner, live[slot]));
        }
        CHECK(pool.valid());
    }
    for (unsigned slot = 0; slot < 48; ++slot)
        if (live[slot]) CHECK(pool.release(slot % 2 + 1, live[slot]));
    CHECK(pool.reserved == 0 && pool.valid());
    printf("{\"pool_checks\":\"pass\",\"churn_operations\":3000,\"controller_host_bytes\":%zu}\n", sizeof(pool));
}
