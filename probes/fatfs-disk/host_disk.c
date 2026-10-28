#define _POSIX_C_SOURCE 200809L
#define _FILE_OFFSET_BITS 64
#include "host_disk.h"
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static int image = -1;
static uint64_t image_bytes, reads, writes, out_of_range, exhausted;
static uint64_t region_first, region_count;
static uint64_t read_budget = 8192;
static uint64_t patch_offset;
static size_t patch_length;
static unsigned char patch_data[512];

int host_disk_open(const char *path, uint64_t create_bytes) {
    struct stat info;
    if (image >= 0) return -1;
    if (create_bytes > INT64_MAX || (create_bytes % 512) != 0) return -1;
#ifdef NIHOS_FIXTURE_WRITER
    /* O_EXCL protects existing paths; the runner owns its output directory. */
    if (create_bytes == 0) return -1;
    image = open(path, O_RDWR | O_CREAT | O_EXCL, 0600);
    if (image < 0) return -1;
    if (ftruncate(image, (off_t)create_bytes) != 0) {
        (void)close(image);
        image = -1;
        return -1;
    }
#else
    if (create_bytes != 0) return -1;
    image = open(path, O_RDONLY);
    if (image < 0) return -1;
#endif
    if (fstat(image, &info) != 0 || !S_ISREG(info.st_mode) || info.st_size < 512 || (info.st_size % 512) != 0) {
        (void)close(image);
        image = -1;
        return -1;
    }
    image_bytes = (uint64_t)info.st_size;
    region_first = 0;
    region_count = image_bytes / 512;
    reads = writes = out_of_range = exhausted = 0;
    read_budget = 8192;
    patch_length = 0;
    return 0;
}

int host_disk_close(void) {
    if (image < 0) return -1;
    int status = close(image);
    image = -1;
    return status;
}

uint64_t host_disk_reads(void) { return reads; }
uint64_t host_disk_writes(void) { return writes; }
uint64_t host_disk_bytes(void) { return image_bytes; }
uint64_t host_disk_out_of_range(void) { return out_of_range; }
uint64_t host_disk_budget_exhaustions(void) { return exhausted; }
void host_disk_set_budget(uint64_t budget) { read_budget = budget; }
int host_disk_select_region(uint64_t first, uint64_t count) {
    if (count == 0 || first >= image_bytes / 512 || count > image_bytes / 512 - first) return -1;
    region_first = first;
    region_count = count;
    return 0;
}
int host_disk_set_patch(uint64_t offset, const unsigned char *data, size_t length) {
    if (length > sizeof patch_data || offset > image_bytes || length > image_bytes - offset) return -1;
    patch_offset = offset;
    patch_length = length;
    memcpy(patch_data, data, length);
    return 0;
}

DSTATUS disk_status(BYTE drive) {
    if (drive != 0 || image < 0) return STA_NOINIT;
#ifdef NIHOS_FIXTURE_WRITER
    return 0;
#else
    return STA_PROTECT;
#endif
}
DSTATUS disk_initialize(BYTE drive) { return disk_status(drive); }

static int byte_range(LBA_t sector, UINT count, uint64_t *offset, size_t *amount) {
    uint64_t sectors = region_count;
#ifndef NIHOS_FIXTURE_WRITER
    if (count > 8) { out_of_range++; return -1; } /* 4 KiB public read quantum. */
#endif
    if (count == 0 || sector >= sectors || count > sectors - sector || (uint64_t)count * 512 > SIZE_MAX) {
        out_of_range++;
        return -1;
    }
    *offset = (region_first + (uint64_t)sector) * 512;
    *amount = (size_t)count * 512;
    return 0;
}

DRESULT disk_read(BYTE drive, BYTE *buffer, LBA_t sector, UINT count) {
    uint64_t offset;
    size_t amount;
    if (drive != 0 || image < 0) return RES_NOTRDY;
    if (byte_range(sector, count, &offset, &amount) != 0) return RES_PARERR;
    if (reads >= read_budget) { exhausted++; return RES_ERROR; }
    reads++;
    size_t done = 0;
    while (done < amount) {
        ssize_t got = pread(image, buffer + done, amount - done, (off_t)(offset + done));
        if (got < 0 && errno == EINTR) continue;
        if (got <= 0) return RES_ERROR;
        done += (size_t)got;
    }
    /* Read-only overlay: malformed metadata never changes the source image. */
    uint64_t begin = offset > patch_offset ? offset : patch_offset;
    uint64_t end = offset + amount < patch_offset + patch_length ? offset + amount : patch_offset + patch_length;
    if (patch_length != 0 && begin < end) memcpy(buffer + (size_t)(begin - offset), patch_data + (size_t)(begin - patch_offset), (size_t)(end - begin));
    return RES_OK;
}

DRESULT disk_write(BYTE drive, const BYTE *buffer, LBA_t sector, UINT count) {
    writes++;
#ifdef NIHOS_FIXTURE_WRITER
    uint64_t offset;
    size_t amount;
    if (drive != 0 || image < 0) return RES_NOTRDY;
    if (byte_range(sector, count, &offset, &amount) != 0) return RES_PARERR;
    size_t done = 0;
    while (done < amount) {
        ssize_t put = pwrite(image, buffer + done, amount - done, (off_t)(offset + done));
        if (put < 0 && errno == EINTR) continue;
        if (put <= 0) return RES_ERROR;
        done += (size_t)put;
    }
    return RES_OK;
#else
    (void)drive; (void)buffer; (void)sector; (void)count;
    return RES_WRPRT;
#endif
}

DRESULT disk_ioctl(BYTE drive, BYTE command, void *buffer) {
    if (drive != 0 || image < 0) return RES_NOTRDY;
    switch (command) {
        case GET_SECTOR_COUNT: *(LBA_t *)buffer = (LBA_t)region_count; return RES_OK;
        case GET_SECTOR_SIZE: *(WORD *)buffer = 512; return RES_OK;
        case GET_BLOCK_SIZE: *(DWORD *)buffer = 1; return RES_OK;
#ifdef NIHOS_FIXTURE_WRITER
        case CTRL_SYNC: return fsync(image) == 0 ? RES_OK : RES_ERROR;
#endif
        default: return RES_PARERR;
    }
}
