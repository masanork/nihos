#define _POSIX_C_SOURCE 200809L
#define _FILE_OFFSET_BITS 64
#include "nihos_fatfs_disk.h"
#include "nihos_fatfs_volume.h"
#include "ff.h"
#include "diskio.h"
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static unsigned checks;
#define REQUIRE(x) do { ++checks; if (!(x)) { fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #x); exit(1); } } while (0)
static nih_fatfs_disk disk;
static uint64_t epoch;
static uint32_t calls, fail_at, invalidate_at, last_lba;
static int image = -1, reenter;
static int fail_result = NIH_STORAGE_READ_IO;

/* Host replacement for the existing native sector export. Each return is
 * synchronous; the MMIO/lease fence itself is covered by Zig owner tests.
 */
int32_t nih_storage_read(uint32_t lba, uint8_t buffer[512]) {
    last_lba = lba;
    ++calls;
    if (reenter) {
        uint8_t nested[512];
        REQUIRE(disk_read(0, nested, 0, 1) == RES_NOTRDY);
        REQUIRE(nih_fatfs_disk_arm(&disk, epoch, 10) == NIH_FATFS_BUSY);
        REQUIRE(nih_fatfs_disk_detach(&disk, epoch) == NIH_FATFS_BUSY);
        REQUIRE(nih_fatfs_disk_bind(&disk, nih_fatfs_native_read, NULL, 100, 0, 100, epoch + 1) == NIH_FATFS_BUSY);
    }
    if (image >= 0) {
        size_t done = 0;
        while (done < 512) {
            ssize_t got = pread(image, buffer + done, 512 - done, (off_t)((uint64_t)lba * 512 + done));
            if (got < 0 && errno == EINTR) continue;
            if (got <= 0) return -1;
            done += (size_t)got;
        }
    } else memset(buffer, (int)(lba & 255), 512);
    if (calls == invalidate_at) REQUIRE(nih_fatfs_disk_invalidate(&disk, epoch) == NIH_FATFS_OK);
    /* Model an error that writes caller-owned staging before returning. */
    return calls == fail_at ? fail_result : 0;
}

static void bind_disk(uint64_t device, uint64_t first, uint64_t count) {
    ++epoch;
    REQUIRE(nih_fatfs_disk_bind(&disk, nih_fatfs_native_read, NULL, device, first, count, epoch) == NIH_FATFS_OK);
    REQUIRE(nih_fatfs_disk_arm(&disk, epoch, NIH_FATFS_READ_BUDGET) == NIH_FATFS_OK);
    calls = fail_at = invalidate_at = 0;
    fail_result = NIH_STORAGE_READ_IO;
}
static void unchanged(const uint8_t *bytes, size_t count) {
    for (size_t i = 0; i < count; ++i) REQUIRE(bytes[i] == 0xa5);
}
static void detach_disk(void) {
    REQUIRE(nih_fatfs_disk_detach(&disk, epoch) == NIH_FATFS_OK);
    REQUIRE(disk_status(0) & STA_NOINIT);
    for (size_t i = 0; i < sizeof disk.scratch; ++i) REQUIRE(disk.scratch[i] == 0);
}

static void contract(void) {
    uint8_t bytes[4096];
    REQUIRE(disk_read(0, bytes, 0, 1) == RES_NOTRDY);
    REQUIRE(nih_fatfs_disk_bind(&disk, nih_fatfs_native_read, NULL, 0, 0, 1, 1) == NIH_FATFS_INVALID);
    REQUIRE(nih_fatfs_disk_bind(&disk, nih_fatfs_native_read, NULL, (UINT64_C(1) << 32) + 1, 0, 1, 1) == NIH_FATFS_INVALID);
    REQUIRE(nih_fatfs_disk_bind(&disk, nih_fatfs_native_read, NULL, 100, 99, 2, 1) == NIH_FATFS_INVALID);
    bind_disk(100, 11, 8);
    REQUIRE(!(disk_initialize(0) & STA_NOINIT));
    REQUIRE(disk_status(0) & STA_PROTECT);
    LBA_t sectors = 0;
    WORD size = 0;
    REQUIRE(disk_ioctl(0, GET_SECTOR_COUNT, &sectors) == RES_OK && sectors == 8);
    REQUIRE(disk_ioctl(0, GET_SECTOR_SIZE, &size) == RES_OK && size == 512);
    REQUIRE(disk_ioctl(0, CTRL_SYNC, &size) == RES_PARERR);
    REQUIRE(disk_ioctl(0, GET_SECTOR_SIZE, NULL) == RES_PARERR);
    const uint64_t invalid[] = {8, 9, UINT64_MAX};
    for (size_t i = 0; i < sizeof invalid / sizeof invalid[0]; ++i)
        REQUIRE(disk_read(0, bytes, invalid[i], 1) == RES_PARERR);
    REQUIRE(disk_read(0, bytes, 7, 2) == RES_PARERR);
    REQUIRE(disk_read(0, bytes, 0, 0) == RES_PARERR);
    REQUIRE(disk_read(0, bytes, 0, 9) == RES_PARERR);
    REQUIRE(disk_read(0, NULL, 0, 1) == RES_PARERR);
    REQUIRE(disk_read(1, bytes, 0, 1) == RES_NOTRDY);
    REQUIRE(calls == 0);
    REQUIRE(disk_write(0, bytes, 0, 1) == RES_WRPRT && calls == 0);
    reenter = 1;
    REQUIRE(disk_read(0, bytes, 0, 8) == RES_OK && calls == 8 && last_lba == 18);
    reenter = 0;
    for (size_t i = 0; i < sizeof bytes; ++i) REQUIRE(bytes[i] == 11 + i / 512);
    REQUIRE(nih_fatfs_disk_arm(&disk, epoch, NIH_FATFS_READ_BUDGET + 1) == NIH_FATFS_INVALID);
    REQUIRE(nih_fatfs_disk_arm(&disk, epoch - 1, 1) == NIH_FATFS_STALE);
    REQUIRE(nih_fatfs_disk_detach(&disk, epoch - 1) == NIH_FATFS_STALE);
    REQUIRE(nih_fatfs_disk_invalidate(&disk, epoch - 1) == NIH_FATFS_STALE);
    REQUIRE(nih_fatfs_disk_arm(&disk, epoch, 1) == NIH_FATFS_OK);
    memset(bytes, 0xa5, sizeof bytes);
    REQUIRE(disk_read(0, bytes, 0, 2) == RES_ERROR && calls == 8);
    unchanged(bytes, sizeof bytes);
    REQUIRE(disk.state == NIH_FATFS_BUDGET_EXHAUSTED);
    REQUIRE(nih_fatfs_disk_arm(&disk, epoch, 100) == NIH_FATFS_INVALID);
    REQUIRE(disk_initialize(0) & STA_NOINIT);
    detach_disk();
    REQUIRE(nih_fatfs_disk_bind(&disk, nih_fatfs_native_read, NULL, 100, 0, 100, epoch) == NIH_FATFS_STALE);
    const int results[] = {NIH_STORAGE_READ_IO, NIH_STORAGE_READ_CANCELLED, NIH_STORAGE_READ_REMOVED, 9};
    for (unsigned kind = 0; kind < sizeof results / sizeof results[0]; ++kind)
    for (uint32_t failing = 1; failing <= 8; ++failing) {
        bind_disk(100, 0, 100);
        fail_at = failing;
        fail_result = results[kind];
        memset(bytes, 0xa5, sizeof bytes);
        REQUIRE(disk_read(0, bytes, 0, 8) == RES_ERROR && calls == failing);
        unchanged(bytes, sizeof bytes);
        REQUIRE(disk.state == (fail_result == NIH_STORAGE_READ_REMOVED ? NIH_FATFS_REMOVED : NIH_FATFS_IO_FAILED) && !disk.busy);
        REQUIRE(disk_read(0, bytes, 0, 1) == RES_NOTRDY && calls == failing);
        REQUIRE(disk_initialize(0) & STA_NOINIT);
        detach_disk();
    }
    for (uint32_t removed = 1; removed <= 8; ++removed) {
        bind_disk(100, 0, 100);
        invalidate_at = removed;
        memset(bytes, 0xa5, sizeof bytes);
        REQUIRE(disk_read(0, bytes, 0, 8) == RES_ERROR && calls == removed);
        unchanged(bytes, sizeof bytes);
        REQUIRE(disk.state == NIH_FATFS_REMOVED && !disk.busy);
        REQUIRE(disk_read(0, bytes, 0, 1) == RES_NOTRDY && calls == removed);
        detach_disk();
    }
    bind_disk(100, 0, 100);
    REQUIRE(nih_fatfs_disk_invalidate(&disk, epoch) == NIH_FATFS_OK);
    REQUIRE(disk_read(0, bytes, 0, 1) == RES_NOTRDY && calls == 0);
    REQUIRE(nih_fatfs_disk_arm(&disk, epoch, 100) == NIH_FATFS_INVALID);
    detach_disk();
    bind_disk(UINT64_C(1) << 32, UINT32_MAX, 1);
    REQUIRE(disk_read(0, bytes, 0, 1) == RES_OK && last_lba == UINT32_MAX);
    detach_disk();
    REQUIRE(nih_fatfs_disk_bind(&disk, nih_fatfs_native_read, NULL, 100, 0, 100, UINT64_MAX) == NIH_FATFS_OK);
    epoch = UINT64_MAX;
    detach_disk();
    REQUIRE(nih_fatfs_disk_bind(&disk, nih_fatfs_native_read, NULL, 100, 0, 100, 1) == NIH_FATFS_STALE);
    printf("{\"kind\":\"contract\",\"checks\":%u,\"workspace_bytes\":%zu,\"fenced_result_kinds\":4}\n", checks, sizeof disk);
}

static void read_text(const char *path, const char *expected) {
    FIL file;
    char bytes[128] = {0};
    UINT got = 0;
    REQUIRE(nih_fatfs_disk_arm(&disk, epoch, NIH_FATFS_READ_BUDGET) == NIH_FATFS_OK);
    REQUIRE(f_open(&file, path, FA_READ) == FR_OK);
    REQUIRE(f_read(&file, bytes, sizeof bytes, &got) == FR_OK);
    REQUIRE(got == strlen(expected) && memcmp(bytes, expected, got) == 0);
    REQUIRE(f_close(&file) == FR_OK);
}
static void read_image(const char *path, uint64_t first, unsigned expected_type) {
    image = open(path, O_RDONLY);
    struct stat info;
    REQUIRE(image >= 0 && fstat(image, &info) == 0 && S_ISREG(info.st_mode) && info.st_size >= 512 && info.st_size % 512 == 0);
    uint64_t total = (uint64_t)info.st_size / 512;
    uint8_t scratch[512];
    nih_fatfs_volume volume;
    REQUIRE(nih_fatfs_volume_probe(nih_fatfs_native_read,NULL,total,NIH_VOLUME_AUTO,scratch,&volume)==NIH_VOLUME_OK);
    REQUIRE(volume.first==first && volume.kind==expected_type && volume.count<=total-first);
    bind_disk(total, volume.first, volume.count);
    FATFS fs;
    REQUIRE(f_mount(&fs, "", 1) == FR_OK && fs.fs_type == expected_type);
    read_text("Memo.txt", "nihos read-only fixture\n");
    read_text("MEMO.TXT", "nihos read-only fixture\n");
    read_text("Long filename for alias.txt", "alias\n");
    read_text("empty-a.txt", "");
    read_text("empty-b.txt", "");
    read_text("教材/漢字𠮷.txt", "日本語・か\xe3\x82\x99・𠮷\n");
    FIL file;
    uint8_t bytes[4096];
    UINT got;
    REQUIRE(nih_fatfs_disk_arm(&disk, epoch, NIH_FATFS_READ_BUDGET) == NIH_FATFS_OK);
    REQUIRE(f_open(&file, "fragment.bin", FA_READ) == FR_OK);
    uint32_t cluster = fs.csize * 512;
    for (uint32_t offset = 0; offset < 8 * cluster;) {
        REQUIRE(f_read(&file, bytes, sizeof bytes, &got) == FR_OK && got != 0);
        for (UINT i = 0; i < got; ++i) REQUIRE(bytes[i] == 0x30 + (offset + i) / cluster);
        offset += got;
    }
    REQUIRE(f_close(&file) == FR_OK);
    if (fs.fs_type == FS_EXFAT) {
        REQUIRE(nih_fatfs_disk_arm(&disk, epoch, NIH_FATFS_READ_BUDGET) == NIH_FATFS_OK);
        REQUIRE(f_open(&file, "large.bin", FA_READ) == FR_OK && f_size(&file) > UINT32_MAX);
        const uint64_t offsets[] = {UINT64_C(0x7ffffff8), UINT64_C(0xfffffff8), UINT64_C(0x100001ff0)};
        for (size_t i = 0; i < sizeof offsets / sizeof offsets[0]; ++i) {
            REQUIRE(f_lseek(&file, offsets[i]) == FR_OK && f_tell(&file) == offsets[i]);
            REQUIRE(f_read(&file, bytes, 16, &got) == FR_OK && got == 16);
            for (UINT j = 0; j < got; ++j) REQUIRE(bytes[j] == 0xa0 + i * 16 + j);
        }
        REQUIRE(f_close(&file) == FR_OK);
    }
    REQUIRE(f_mount(NULL, "", 0) == FR_OK);
    uint32_t read_count = disk.reads;
    detach_disk();
    REQUIRE(close(image) == 0);
    printf("{\"kind\":\"image\",\"fs_type\":%u,\"checks\":%u,\"sector_reads\":%u,\"workspace_bytes\":%zu}\n",
           expected_type, checks, read_count, sizeof disk);
}
int main(int argc, char **argv) {
    if (argc == 1) contract();
    else if (argc == 4) read_image(argv[1], strtoull(argv[2], NULL, 10), (unsigned)strtoul(argv[3], NULL, 10));
    else return 2;
    return 0;
}
