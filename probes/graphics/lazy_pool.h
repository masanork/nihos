#ifndef NIHOS_GRAPHICS_LAZY_POOL_H
#define NIHOS_GRAPHICS_LAZY_POOL_H
#include <stddef.h>
#include <stdint.h>

// Host experiment: backing is acquired on demand. Not a native allocator ABI.
// A single font worker serializes calls; owners are client lifetimes, not locks.
class LazyPool {
public:
    LazyPool() = default;
    LazyPool(const LazyPool &) = delete;
    LazyPool &operator=(const LazyPool &) = delete;
#ifndef NIHOS_GRAPHICS_ALLOCATION_RECORDS
#define NIHOS_GRAPHICS_ALLOCATION_RECORDS 256
#endif
    static constexpr unsigned owners = 4, record_count = NIHOS_GRAPHICS_ALLOCATION_RECORDS, span_count = 64;
    static_assert(record_count == 256 || record_count == 512 || record_count == 1024, "supported probe capacities");
    static constexpr size_t page_bytes = 65536, alignment = 16;
    size_t total_limit = 2 * 1024 * 1024;
    size_t owner_limit[owners] = {512 * 1024, 1024 * 1024, 1024 * 1024, 1024 * 1024};
    size_t reserved = 0, peak = 0, owner_reserved[owners] = {};
    size_t attempts = 0, failures = 0, fail_at = 0;
    size_t live_records = 0, peak_records = 0, record_failures = 0;
    void *allocate(unsigned owner, size_t bytes);
    bool release(unsigned owner, void *pointer);
    void *resize(unsigned owner, void *pointer, size_t bytes);
    size_t capacity(unsigned owner, const void *pointer) const;
    size_t live_bytes(unsigned owner) const;
    bool valid() const;
    void begin_operation(size_t failure = 0) {
        attempts = failures = record_failures = 0; fail_at = failure; peak = reserved; peak_records = live_records;
    }
private:
    struct Record {
        void *pointer = nullptr;
        uint32_t requested = 0, usable = 0;
        uint16_t span = 0, owner = 0;
    } records[record_count];
    struct Span {
        unsigned char *base = nullptr;
        uint32_t bytes = 0;
        uint16_t owner = 0, live = 0;
    } spans[span_count];
    unsigned active_end = 0;
    int find(unsigned owner, const void *pointer) const;
    bool gap(unsigned span, size_t bytes, size_t *offset) const;
};
#endif
