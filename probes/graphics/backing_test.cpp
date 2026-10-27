#include "buddy_backing.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "backing check failed: %s:%d: %s\n", __FILE__, __LINE__, #x); abort(); } } while (0)
int main() {
    graphics_backing_ensure();
    CHECK(nih_graphics_backing_raw_used() == 0 && nih_graphics_backing_recovered() == 1);
    CHECK(!nih_graphics_backing_acquire(0) && !nih_graphics_backing_acquire(1));
    void *small = nih_graphics_backing_acquire(65536);
    void *large = nih_graphics_backing_acquire(4 * 65536);
    void *other = nih_graphics_backing_acquire(65536);
    CHECK(small && large && other && nih_graphics_backing_parents() == 2);
    CHECK(nih_graphics_backing_raw_used() == 2 * 1024 * 1024 + 128 * 1024);
    CHECK(!nih_graphics_backing_acquire(2 * 1024 * 1024));
    CHECK(nih_graphics_backing_release((void *)(uintptr_t)1) == -1);
    CHECK(nih_graphics_backing_release((char *)large + 1) == -1);
    memset(other, 0x73, 65536);
    CHECK(nih_graphics_backing_release(large) == 0);
    CHECK(nih_graphics_backing_release(large) == -1);
    for (unsigned i = 0; i < 65536; ++i) CHECK(((unsigned char *)other)[i] == 0x73);
    CHECK(nih_graphics_backing_release(small) == 0 && nih_graphics_backing_parents() == 1);
    CHECK(nih_graphics_backing_release(other) == 0 && nih_graphics_backing_recovered() == 1);

    // A second actual ledger task owns memory in the same buddy heap.
    unsigned char *peer = (unsigned char *)nih_graphics_backing_peer_allocate(512 * 1024 - 128);
    CHECK(peer); memset(peer, 0x3c, 512 * 1024 - 128);
    small = nih_graphics_backing_acquire(65536);
    large = nih_graphics_backing_acquire(4 * 65536);
    CHECK(small && large && nih_graphics_backing_parents() == 2);
    CHECK(nih_graphics_backing_retire() == 0 && nih_graphics_backing_loan_count() == 0);
    CHECK(nih_graphics_backing_parents() == 0 && nih_graphics_backing_raw_used() == 512 * 1024);
    CHECK(!nih_graphics_backing_acquire(65536) && nih_graphics_backing_release(small) == -1);
    for (unsigned i = 0; i < 512 * 1024 - 128; ++i) CHECK(peer[i] == 0x3c);
    CHECK(nih_graphics_backing_reopen() == 0);
    CHECK(nih_graphics_backing_release(large) == -1); // before any address reuse
    other = nih_graphics_backing_acquire(65536); CHECK(other);
    CHECK(nih_graphics_backing_release(other) == 0);
    CHECK(nih_graphics_backing_peer_release() == 0 && nih_graphics_backing_recovered() == 1);
    // Real buddy exhaustion (not injected malloc failure) is recoverable.
    peer = (unsigned char *)nih_graphics_backing_peer_allocate(8 * 1024 * 1024 - 128);
    CHECK(peer);
    peer[0] = 0xa7; peer[8 * 1024 * 1024 - 129] = 0x7a;
    unsigned char *peer2 = (unsigned char *)nih_graphics_backing_peer_allocate(4 * 1024 * 1024 - 128);
    CHECK(peer2); peer2[0] = 0xb4;
    small = nih_graphics_backing_acquire(65536); CHECK(small);
    size_t fragmented_free = nih_graphics_backing_initial_free() - nih_graphics_backing_raw_used();
    size_t fragmented_largest = nih_graphics_backing_largest_free();
    CHECK(fragmented_free > 2 * 1024 * 1024 && fragmented_largest < 2 * 1024 * 1024);
    CHECK(!nih_graphics_backing_acquire(4 * 65536));
    CHECK(nih_graphics_backing_parents() == 1);
    CHECK(peer[0] == 0xa7 && peer[8 * 1024 * 1024 - 129] == 0x7a && peer2[0] == 0xb4);
    CHECK(nih_graphics_backing_peer_release() == 0);
    large = nih_graphics_backing_acquire(4 * 65536); CHECK(large);
    CHECK(nih_graphics_backing_release(large) == 0 && nih_graphics_backing_release(small) == 0);
    CHECK(nih_graphics_backing_peer_release() == 0 && nih_graphics_backing_recovered() == 1);
    printf("{\"status\":\"pass\",\"task_parent_limit\":2,\"service_retirement_recovered\":true,"
        "\"peer_survives_retirement\":true,\"full_heap_recovered\":true,\"initial_free\":%zu,"
        "\"fragmentation_recovered\":true,\"fragmented_free_bytes\":%zu,\"fragmented_largest_block\":%zu,"
        "\"backing_controller_host_bytes\":%zu}\n",
        nih_graphics_backing_initial_free(), fragmented_free, fragmented_largest,
        nih_graphics_backing_control_bytes());
}
