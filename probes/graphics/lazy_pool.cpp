#include "lazy_pool.h"
#include <stdlib.h>
#include <string.h>
#ifdef NIHOS_GRAPHICS_BUDDY_BACKING
#include "buddy_backing.h"
#endif

int LazyPool::find(unsigned owner, const void *pointer) const {
    for (unsigned i = 0; i < record_count; ++i)
        if (records[i].pointer == pointer && records[i].owner == owner) return (int)i;
    return -1;
}

bool LazyPool::gap(unsigned index, size_t bytes, size_t *offset) const {
    const Span &span = spans[index];
    size_t start = 0;
    // Bounded metadata scan; this is deliberately not an IRQ-latency claim.
    for (unsigned pass = 0; pass <= record_count; ++pass) {
        if (start > span.bytes || bytes > span.bytes - start) return false;
        size_t next = start;
        for (const Record &r : records) {
            if (!r.pointer || r.span != index) continue;
            size_t at = (uintptr_t)r.pointer - (uintptr_t)span.base;
            if (at < start + bytes && start < at + r.usable && at + r.usable > next)
                next = at + r.usable;
        }
        if (next == start) { *offset = start; return true; }
        start = next;
    }
    return false;
}

void *LazyPool::allocate(unsigned owner, size_t bytes) {
    if (!bytes) return nullptr;
    ++attempts;
    auto reject = [this]() -> void * { ++failures; return nullptr; };
    if ((fail_at && attempts == fail_at) || owner >= owners ||
        bytes > UINT32_MAX - page_bytes) return reject();
    size_t usable = (bytes + alignment - 1) & ~(alignment - 1);
    unsigned record = record_count;
    for (unsigned i = 0; i < record_count; ++i)
        if (!records[i].pointer) { record = i; break; }
    if (record == record_count) return reject();
    unsigned selected = span_count;
    size_t offset = 0;
    for (unsigned i = 0; i < span_count; ++i)
        if (spans[i].base && spans[i].owner == owner && gap(i, usable, &offset)) {
            selected = i; break;
        }
    if (selected == span_count) {
        for (unsigned i = 0; i < span_count; ++i)
            if (!spans[i].base) { selected = i; break; }
        size_t backing, charge;
#ifdef NIHOS_GRAPHICS_BUDDY_BACKING
        charge = page_bytes;
        while (charge < usable + 128) {
            if (charge > SIZE_MAX / 2) return reject();
            charge *= 2;
        }
        backing = charge - 128; // use the full safe payload of each buddy block
#else
        backing = ((usable - 1) / page_bytes + 1) * page_bytes;
        charge = backing;
#endif
        if (selected == span_count || reserved > total_limit || charge > total_limit - reserved ||
            owner_reserved[owner] > owner_limit[owner] || charge > owner_limit[owner] - owner_reserved[owner])
            return reject();
        void *base = nullptr;
#ifdef NIHOS_GRAPHICS_BUDDY_BACKING
        graphics_backing_ensure();
        base = nih_graphics_backing_acquire(charge);
        if (!base) return reject();
#else
        if (posix_memalign(&base, 64, backing)) return reject();
#endif
        spans[selected] = { (unsigned char *)base, (uint32_t)backing, (uint16_t)owner, 0 };
        reserved += charge; owner_reserved[owner] += charge;
        if (reserved > peak) peak = reserved;
        offset = 0;
    }
    Span &span = spans[selected];
    void *pointer = span.base + offset;
    records[record] = { pointer, (uint32_t)bytes, (uint32_t)usable, (uint16_t)selected, (uint16_t)owner };
    ++span.live;
    return pointer;
}

bool LazyPool::release(unsigned owner, void *pointer) {
    if (!pointer) return true;
    int index = find(owner, pointer);
    if (index < 0) return false; // Never read metadata through the supplied pointer.
    Span &span = spans[records[index].span];
    records[index] = {};
    if (--span.live == 0) {
#ifdef NIHOS_GRAPHICS_BUDDY_BACKING
        reserved -= span.bytes + 128; owner_reserved[owner] -= span.bytes + 128;
#else
        reserved -= span.bytes; owner_reserved[owner] -= span.bytes;
#endif
#ifdef NIHOS_GRAPHICS_BUDDY_BACKING
        if (nih_graphics_backing_release(span.base)) abort();
#else
        free(span.base);
#endif
        span = {};
    }
    return true;
}

void *LazyPool::resize(unsigned owner, void *pointer, size_t bytes) {
    if (!pointer) return allocate(owner, bytes);
    int index = find(owner, pointer);
    if (index < 0) return nullptr;
    if (!bytes) { release(owner, pointer); return nullptr; }
    Record previous = records[index];
    if (bytes <= previous.usable) {
        records[index].requested = (uint32_t)bytes;
        return pointer;
    }
    void *next = allocate(owner, bytes);
    if (!next) return nullptr; // Preserve old address, capacity and every usable byte.
    memcpy(next, pointer, previous.usable);
    release(owner, pointer);
    return next;
}

size_t LazyPool::capacity(unsigned owner, const void *pointer) const {
    if (!pointer) return 0;
    int index = find(owner, pointer);
    return index < 0 ? 0 : records[index].usable;
}

size_t LazyPool::live_bytes(unsigned owner) const {
    size_t bytes = 0;
    for (const Record &r : records) if (r.pointer && r.owner == owner) bytes += r.requested;
    return bytes;
}

bool LazyPool::valid() const {
    size_t total = 0, per_owner[owners] = {};
    for (unsigned s = 0; s < span_count; ++s) {
        const Span &span = spans[s];
        if (!span.base) continue;
        if (span.owner >= owners || (uintptr_t)span.base % 64) return false;
#ifdef NIHOS_GRAPHICS_BUDDY_BACKING
        size_t charge = span.bytes + 128;
        if (charge < page_bytes || (charge & (charge - 1))) return false;
#else
        size_t charge = span.bytes;
        if (span.bytes % page_bytes) return false;
#endif
        total += charge; per_owner[span.owner] += charge;
        unsigned live = 0;
        for (unsigned i = 0; i < record_count; ++i) {
            const Record &a = records[i];
            if (!a.pointer || a.span != s) continue;
            ++live;
            uintptr_t at = (uintptr_t)a.pointer - (uintptr_t)span.base;
            if (a.owner != span.owner || (uintptr_t)a.pointer % alignment || !a.requested ||
                a.requested > a.usable || at > span.bytes || a.usable > span.bytes - at) return false;
            for (unsigned j = 0; j < i; ++j) {
                const Record &b = records[j];
                if (!b.pointer || b.span != s) continue;
                uintptr_t bt = (uintptr_t)b.pointer - (uintptr_t)span.base;
                if (at < bt + b.usable && bt < at + a.usable) return false;
            }
        }
        if (!live || live != span.live) return false;
    }
    for (const Record &r : records)
        if (r.pointer && (r.span >= span_count || !spans[r.span].base)) return false;
    if (total != reserved || total > total_limit) return false;
    for (unsigned owner = 0; owner < owners; ++owner)
        if (per_owner[owner] != owner_reserved[owner] || per_owner[owner] > owner_limit[owner]) return false;
    return true;
}
