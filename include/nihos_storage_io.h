#ifndef NIHOS_STORAGE_IO_H
#define NIHOS_STORAGE_IO_H
#include <stdint.h>
/* Fenced synchronous nih_storage_read results. A negative return never proves
 * electrical removal by itself. REMOVED preserves a trusted removal result;
 * CANCELLED does not imply that the controller/session is reusable.
 * Existing consumers may continue treating every nonzero result as failure.
 * An unproved DMA fence does not return into caller cleanup. */
enum { NIH_STORAGE_READ_OK = 0, NIH_STORAGE_READ_IO = -1,
       NIH_STORAGE_READ_CANCELLED = -2, NIH_STORAGE_READ_REMOVED = -3 };
/* Internal trusted storage-owner hooks, not public syscalls.
 * Resident IRQ code may only publish notifications. The ordinary owner stops
 * DMA, detaches descriptors and hands back caches before releasing its lease.
 * Ticket 0 means no operation. Tickets never wrap within this owner lifetime.
 * stop returns 0 for a stale ticket or invalid reason; 1 accepts the request,
 * not proof of DMA completion. reason: 1 cancellation, 2 operation removed.
 * removed latches physical removal even while idle and denies new operations.
 * A fresh fully initialized owner is required for reinsertion.
 */
uint32_t nih_storage_io_active(void);
uint32_t nih_storage_io_stop(uint32_t ticket, uint32_t reason);
void nih_storage_io_removed(void);
/* Trusted ordinary owner, opt-in native FatFs fixture only. Begin returns a
 * 512-byte sector count and publishes its nonzero generation on success; zero
 * leaves generation unchanged. End is called after filesystem/disk teardown;
 * it returns 1 only for that generation and a fully fenced idle controller.
 * These functions do not discover, bind, or mount a filesystem. */
uint32_t nih_storage_fatfs_session_begin(uint32_t *generation);
uint32_t nih_storage_fatfs_session_end(uint32_t generation);
#endif
