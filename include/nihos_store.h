#ifndef NIHOS_STORE_H
#define NIHOS_STORE_H
#include <stddef.h>
#include <stdint.h>
/* Serialized owner API. All callbacks finish using buffers before returning.
 * sync must be a media barrier. The caller grants an exclusive 4 MiB region;
 * format is an explicit provisioning operation, never a mount fallback. */
#define NIH_STORE_BYTES (4u * 1024u * 1024u)
enum { NIH_STORE_IO=-5, NIH_STORE_NOT_FOUND=-2, NIH_STORE_INVALID=-22,
       NIH_STORE_BUSY=-16, NIH_STORE_FULL=-28, NIH_STORE_CORRUPT=-84 };
struct nih_store_device {
    void *context;
    int (*read)(void *, uint64_t, uint8_t *, size_t);
    int (*write)(void *, uint64_t, const uint8_t *, size_t);
    int (*sync)(void *);
};
size_t nih_store_size(void);
size_t nih_store_alignment(void);
int nih_store_mount(void *, size_t, const struct nih_store_device *, int format);
int nih_store_stat(void *, uint32_t key, uint64_t *size);
int nih_store_create(void *, uint32_t key);
int nih_store_read(void *, uint32_t key, uint64_t offset, uint8_t *, size_t);
int nih_store_write(void *, uint32_t key, uint64_t offset, const uint8_t *, size_t);
int nih_store_resize(void *, uint32_t key, uint64_t size);
int nih_store_remove(void *, uint32_t key);
int nih_store_sync(void *);
int nih_store_rollback(void *);
int nih_store_snapshot(void *, uint32_t *token);
int nih_store_release(void *, uint32_t token);
int nih_store_restore(void *, uint32_t token);
int nih_store_snapshot_valid(void *, uint32_t token);
int nih_store_collect(void *);
struct nih_store_space { uint64_t capacity, free_bytes, largest_run, index_free_bytes; };
int nih_store_space(void *, struct nih_store_space *);
int nih_store_verify(void *, uint32_t key);
uint64_t nih_store_generation(void *);
#endif
