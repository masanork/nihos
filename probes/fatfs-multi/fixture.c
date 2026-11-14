#define _POSIX_C_SOURCE 200809L
#define _DARWIN_C_SOURCE
/* Host-only, private throwaway image. Not a native storage backend. */
#include "host_disk.h"
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#if !defined(NIHOS_FIXTURE_WRITER) || FF_FS_READONLY != 0
#error "host fixture needs its isolated writable FatFs profile"
#endif
static char directory[] = "/tmp/nihos-fatfs-multi-XXXXXX";
static char image[128];
static FATFS fs;
static FIL files[2];
static unsigned open_mask;
static int active;
void nih_multi_fixture_destroy(void);

static int create(const char *path) {
    FIL file;
    if (f_open(&file, path, FA_CREATE_NEW | FA_WRITE) != FR_OK) return -1;
    return f_close(&file) == FR_OK ? 0 : -1;
}
int nih_multi_fixture_init(void) {
    if (active || !mkdtemp(directory)) return -1;
    size_t n = strlen(directory);
    memcpy(image, directory, n);
    memcpy(image + n, "/volume.img", sizeof "/volume.img");
    if (host_disk_open(image, 16u * 1024u * 1024u)) { (void)rmdir(directory); return -1; }
    active = 1;
    BYTE work[32768];
    const MKFS_PARM options = { .fmt = FM_FAT | FM_SFD, .n_fat = 1, .align = 1, .n_root = 512, .au_size = 512 };
    if (f_mkfs("", &options, work, sizeof work) != FR_OK || f_mount(&fs, "", 1) != FR_OK ||
        create("a.txt") || create("b.txt")) { nih_multi_fixture_destroy(); return -1; }
    return 0;
}
int nih_multi_fixture_open(unsigned index) {
    if (!active || index >= 2 || (open_mask & (1u << index))) return -1;
    if (f_open(&files[index], index ? "b.txt" : "a.txt", FA_WRITE) != FR_OK) return -1;
    open_mask |= 1u << index;
    return 0;
}
int nih_multi_fixture_write(unsigned index, unsigned long long offset, const unsigned char *data, unsigned length) {
    UINT written = 0;
    if (index >= 2 || !(open_mask & (1u << index)) || f_lseek(&files[index], offset) != FR_OK ||
        f_tell(&files[index]) != offset || f_write(&files[index], data, length, &written) != FR_OK || written != length) return -1;
    return 0;
}
int nih_multi_fixture_sync(unsigned index) {
    return index < 2 && (open_mask & (1u << index)) && f_sync(&files[index]) == FR_OK ? 0 : -1;
}
int nih_multi_fixture_close(unsigned index) {
    if (index >= 2 || !(open_mask & (1u << index))) return -1;
    if (f_close(&files[index]) != FR_OK) return -1;
    open_mask &= ~(1u << index);
    return 0;
}
int nih_multi_fixture_remount_check(void) {
    if (open_mask || f_mount(NULL, "", 0) != FR_OK || f_mount(&fs, "", 1) != FR_OK) return -1;
    for (unsigned i = 0; i < 2; ++i) {
        FIL file;
        UINT read = 0;
        char buf[4];
        if (f_open(&file, i ? "b.txt" : "a.txt", FA_READ) != FR_OK) return -1;
        if (f_read(&file, buf, sizeof buf, &read) != FR_OK || read != sizeof buf ||
            memcmp(buf, i ? "two!" : "one!", sizeof buf) || f_close(&file) != FR_OK) return -1;
    }
    return 0;
}
void nih_multi_fixture_destroy(void) {
    if (active) {
        for (unsigned i = 0; i < 2; ++i) if (open_mask & (1u << i)) (void)f_close(&files[i]);
        (void)f_mount(NULL, "", 0);
        (void)host_disk_close();
        (void)unlink(image);
        active = 0;
    }
    (void)rmdir(directory);
}
