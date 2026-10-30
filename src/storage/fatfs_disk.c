/* Read-only FatFs diskio bridge to a fenced synchronous sector callback.
 * No filesystem, DMA, allocator, scheduler or partition discovery policy here.
 */
#include "nihos_fatfs_disk.h"
#include "ff.h"
#include "diskio.h"
#include <string.h>

#if FF_FS_READONLY != 1 || FF_MIN_SS != 512 || FF_MAX_SS != 512 || FF_VOLUMES != 1 || FF_LBA64 != 1
#error "FatFs disk bridge requires read-only, one volume, 512-byte sectors and 64-bit LBA"
#endif

static nih_fatfs_disk *active;
static uint64_t last_epoch;

static int matches(nih_fatfs_disk *disk, uint64_t epoch) {
    return disk && active == disk && disk->epoch == epoch;
}

int nih_fatfs_disk_bind(nih_fatfs_disk *disk, nih_fatfs_sector_read read_sector,
                      void *context, uint64_t device_sectors, uint64_t first,
                      uint64_t count, uint64_t epoch) {
    if (active) return NIH_FATFS_BUSY;
    if (!disk || !read_sector || !device_sectors || device_sectors > (UINT64_C(1) << 32) ||
            !count || first >= device_sectors || count > device_sectors - first) return NIH_FATFS_INVALID;
    if (!epoch || epoch <= last_epoch) return NIH_FATFS_STALE;
    memset(disk, 0, sizeof *disk);
    disk->read_sector = read_sector;
    disk->context = context;
    disk->first = first;
    disk->count = count;
    disk->epoch = last_epoch = epoch;
    disk->state = NIH_FATFS_READY;
    active = disk;
    return NIH_FATFS_OK;
}

int nih_fatfs_disk_arm(nih_fatfs_disk *disk, uint64_t epoch, uint32_t sectors) {
    if (!matches(disk, epoch)) return NIH_FATFS_STALE;
    if (disk->busy) return NIH_FATFS_BUSY;
    if (disk->state != NIH_FATFS_READY || sectors > NIH_FATFS_READ_BUDGET) return NIH_FATFS_INVALID;
    disk->remaining = sectors;
    return NIH_FATFS_OK;
}

int nih_fatfs_disk_invalidate(nih_fatfs_disk *disk, uint64_t epoch) {
    if (!matches(disk, epoch)) return NIH_FATFS_STALE;
    disk->state = NIH_FATFS_REMOVED;
    return NIH_FATFS_OK;
}

int nih_fatfs_disk_detach(nih_fatfs_disk *disk, uint64_t epoch) {
    if (!matches(disk, epoch)) return NIH_FATFS_STALE;
    if (disk->busy || disk->retained) return NIH_FATFS_BUSY;
    memset(disk->scratch, 0, sizeof disk->scratch);
    disk->state = NIH_FATFS_DETACHED;
    disk->remaining = 0;
    disk->read_sector = NULL;
    disk->context = NULL;
    active = NULL;
    return NIH_FATFS_OK;
}

int nih_fatfs_disk_retain(nih_fatfs_disk *disk, uint64_t epoch) {
    if (!matches(disk, epoch)) return NIH_FATFS_STALE;
    if (disk->busy || disk->retained) return NIH_FATFS_BUSY;
    if (disk->state != NIH_FATFS_READY) return NIH_FATFS_INVALID;
    disk->retained = 1;
    return NIH_FATFS_OK;
}
int nih_fatfs_disk_release(nih_fatfs_disk *disk, uint64_t epoch) {
    if (!matches(disk, epoch)) return NIH_FATFS_STALE;
    if (disk->busy) return NIH_FATFS_BUSY;
    if (!disk->retained) return NIH_FATFS_INVALID;
    disk->retained = 0;
    return NIH_FATFS_OK;
}

DSTATUS disk_status(BYTE drive) {
    if (drive || !active || active->state != NIH_FATFS_READY) return STA_NOINIT | STA_PROTECT;
    return STA_PROTECT;
}

/* Never clears faults or reinitializes hardware implicitly. */
DSTATUS disk_initialize(BYTE drive) { return disk_status(drive); }

DRESULT disk_read(BYTE drive, BYTE *buffer, LBA_t sector, UINT count) {
    if (drive || !active || active->state != NIH_FATFS_READY || active->busy) return RES_NOTRDY;
    nih_fatfs_disk *disk = active;
    if (!buffer || !count || count > NIH_FATFS_IO_BYTES / 512 ||
            sector >= disk->count || count > disk->count - sector) return RES_PARERR;
    if (count > disk->remaining) {
        disk->state = NIH_FATFS_BUDGET_EXHAUSTED;
        return RES_ERROR;
    }
    disk->busy = 1;
    DRESULT result = RES_ERROR;
    for (UINT i = 0; i < count; ++i) {
        --disk->remaining;
        ++disk->reads;
        int failed = disk->read_sector(disk->context, (uint32_t)(disk->first + sector + i),
                                       disk->scratch + i * 512);
        if (failed && disk->state == NIH_FATFS_READY)
            disk->state = failed == NIH_STORAGE_READ_REMOVED ? NIH_FATFS_REMOVED : NIH_FATFS_IO_FAILED;
        if (disk->state != NIH_FATFS_READY) goto done;
    }
    /* Publish the whole disk_read only after every sector has returned safely.
     * This does not make a multi-call f_read or a filesystem transaction atomic.
     */
    memmove(buffer, disk->scratch, (size_t)count * 512);
    result = RES_OK;
done:
    disk->busy = 0;
    return result;
}

DRESULT disk_write(BYTE drive, const BYTE *buffer, LBA_t sector, UINT count) {
    (void)drive; (void)buffer; (void)sector; (void)count;
    return RES_WRPRT;
}

DRESULT disk_ioctl(BYTE drive, BYTE command, void *buffer) {
    if (drive || !active || active->state != NIH_FATFS_READY || active->busy) return RES_NOTRDY;
    if (!buffer) return RES_PARERR;
    switch (command) {
        case GET_SECTOR_COUNT: *(LBA_t *)buffer = (LBA_t)active->count; return RES_OK;
        case GET_SECTOR_SIZE: *(WORD *)buffer = 512; return RES_OK;
        case GET_BLOCK_SIZE: *(DWORD *)buffer = 1; return RES_OK;
        default: return RES_PARERR; /* No sync, trim or write API. */
    }
}
