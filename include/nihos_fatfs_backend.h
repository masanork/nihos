#ifndef NIHOS_FATFS_BACKEND_H
#define NIHOS_FATFS_BACKEND_H
#include "nihos_fatfs_disk.h"
typedef struct nih_fatfs_backend nih_fatfs_backend;
enum { NIH_FB_OK, NIH_FB_NOT_FOUND, NIH_FB_INVALID_NAME, NIH_FB_CORRUPT,
       NIH_FB_IO, NIH_FB_LIMIT, NIH_FB_STALE, NIH_FB_BUSY, NIH_FB_READ_ONLY,
       NIH_FB_NO_HANDLES, NIH_FB_REMOVED };
/* Trusted single owner, fixed 16 open files plus one staged lookup. No heap.
 * Root 1 means the volume root; subtree grants are not implemented here.
 * Unused workspace is 8-byte aligned, disjoint from disk/callback state and
 * pinned until destroy. Disk/controller must
 * already be bound/ready and must outlive this workspace. Every operation
 * includes the immutable disk epoch, including operations served from cache.
 * Return from any callback must imply a complete DMA fence, also on error.
 */
uint32_t nih_fatfs_backend_bytes(void);
nih_fatfs_backend *nih_fatfs_backend_init(void *workspace, uint32_t bytes,
                                        nih_fatfs_disk *disk, uint64_t epoch);
int nih_fatfs_backend_mount(nih_fatfs_backend *, uint64_t epoch);
/* lookup stages a guarded FIL; open consumes it without resolving a path.
 * An unconsumed lookup is closed by the next lookup or destroy (one slot).
 * Stable identity may be zero; it is directory cluster + entry offset and
 * is meaningful only within this mounted epoch and without external writers.
 */
int nih_fatfs_backend_lookup(nih_fatfs_backend *, uint64_t epoch, uint64_t root,
                            const char *path, uint32_t length, uint64_t *identity);
int nih_fatfs_backend_open(nih_fatfs_backend *, uint64_t epoch, uint64_t identity, uint64_t *token);
int nih_fatfs_backend_read(nih_fatfs_backend *, uint64_t epoch, uint64_t token,
                          uint64_t offset, void *output, uint32_t length,
                          uint32_t *transferred, uint32_t *eof);
int nih_fatfs_backend_close(nih_fatfs_backend *, uint64_t epoch, uint64_t token);
int nih_fatfs_backend_remove(nih_fatfs_backend *, uint64_t epoch);
/* Caller first detaches/revokes VFS handles after quiescence. Destroy drops
 * all private FILs and FatFs registration, clears backend_bytes() bytes and releases its
 * disk binding. Never call on a busy/quarantined controller or from an IRQ.
 */
int nih_fatfs_backend_destroy(nih_fatfs_backend *, uint64_t epoch);
#endif
