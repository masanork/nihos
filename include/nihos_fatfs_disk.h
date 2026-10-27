#ifndef NIHOS_FATFS_DISK_H
#define NIHOS_FATFS_DISK_H
#include <stdint.h>

/* Trusted single storage owner only. Not an IRQ API or a client syscall.
 * The owner retains this workspace, callback context and device session until
 * detach, and invalidates all old FatFs/VFS objects before rebinding a volume.
 * read_sector returns only after DMA is fenced, on success AND on error.
 * An unproved fence must retain/quarantine its resources and must not return
 * into FatFs cleanup (the current native nih_storage_read fails fatally).
 */
typedef int (*nih_fatfs_sector_read)(void *context, uint32_t lba, uint8_t sector[512]);
enum { NIH_FATFS_IO_BYTES = 4096, NIH_FATFS_READ_BUDGET = 8192 };
typedef enum { NIH_FATFS_DETACHED, NIH_FATFS_READY, NIH_FATFS_IO_FAILED,
               NIH_FATFS_REMOVED, NIH_FATFS_BUDGET_EXHAUSTED } nih_fatfs_disk_state;
typedef struct {
    nih_fatfs_sector_read read_sector;
    void *context;
    uint64_t first, count, epoch;
    uint32_t remaining, reads;
    nih_fatfs_disk_state state;
    int busy;
    uint8_t scratch[NIH_FATFS_IO_BYTES];
} nih_fatfs_disk;
enum { NIH_FATFS_OK, NIH_FATFS_INVALID, NIH_FATFS_BUSY, NIH_FATFS_STALE };

/* One FatFs drive 0, read-only, fixed 512-byte sectors, <=2 TiB device.
 * Selected partition bounds are supplied by a separately validated probe.
 * Hardware/controller and its timeout clock must already be ready; bind and
 * disk_initialize never power, prepare or reset the device. The native owner
 * must establish the nih_storage_controller_begin session first.
 * Epochs are strictly increasing for this owner lifetime; never wrap/reuse.
 * bind starts with no I/O budget; arm a bounded operation before f_mount etc.
 */
int nih_fatfs_disk_bind(nih_fatfs_disk *disk, nih_fatfs_sector_read read_sector,
                      void *context, uint64_t device_sectors, uint64_t first,
                      uint64_t count, uint64_t epoch);
int nih_fatfs_disk_arm(nih_fatfs_disk *disk, uint64_t epoch, uint32_t sectors);
int nih_fatfs_disk_invalidate(nih_fatfs_disk *disk, uint64_t epoch);
int nih_fatfs_disk_detach(nih_fatfs_disk *disk, uint64_t epoch);
/* Native adapter to the existing pinned, fenced nih_storage_read path. */
int nih_fatfs_native_read(void *unused, uint32_t lba, uint8_t sector[512]);
#endif
