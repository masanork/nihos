#include "host_disk.h"
#include <errno.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

_Static_assert(FF_FS_READONLY == 1, "reader must have write APIs compiled out");
_Static_assert(sizeof(FSIZE_t) == 8 && sizeof(LBA_t) == 8, "64-bit file offsets and LBA required");

static int number(const char *text, uint64_t *result) {
    char *end;
    if (*text < '0' || *text > '9') return -1;
    errno = 0;
    unsigned long long value = strtoull(text, &end, 0);
    if (errno != 0 || *end != '\0') return -1;
    *result = (uint64_t)value;
    return 0;
}
static int valid_path(const char *path) {
    size_t length = strlen(path), start = 0;
    if (length == 0 || length > 511 || strchr(path, ':') != NULL || strchr(path, '\\') != NULL) return 0;
    for (size_t i = 0; i <= length; i++) {
        if (path[i] == '/' || path[i] == '\0') {
            size_t part = i - start;
            if (part == 0 || (part == 1 && path[start] == '.') ||
                (part == 2 && path[start] == '.' && path[start + 1] == '.')) return 0;
            start = i + 1;
        }
    }
    return 1;
}
static void string(const char *value) {
    putchar('"');
    for (const unsigned char *p = (const unsigned char *)value; *p != 0; p++) {
        if (*p == '"' || *p == '\\') { putchar('\\'); putchar(*p); }
        else if (*p < 32) printf("\\u%04x", *p);
        else putchar(*p);
    }
    putchar('"');
}
static void statistics(void) {
    printf(",\"disk_reads\":%" PRIu64 ",\"disk_writes\":%" PRIu64 ",\"out_of_range\":%" PRIu64
           ",\"budget_exhaustions\":%" PRIu64 "}\n",
           host_disk_reads(), host_disk_writes(), host_disk_out_of_range(), host_disk_budget_exhaustions());
}
static int configure_overlay(void) {
    const char *budget = getenv("NIHOS_FATFS_READ_BUDGET");
    const char *offset = getenv("NIHOS_FATFS_PATCH_OFFSET");
    const char *hex = getenv("NIHOS_FATFS_PATCH_HEX");
    uint64_t value;
    if (budget != NULL) {
        if (number(budget, &value) != 0) return -1;
        host_disk_set_budget(value);
    }
    if ((offset == NULL) != (hex == NULL)) return -1;
    if (offset != NULL) {
        unsigned char bytes[512];
        size_t length = strlen(hex);
        if (number(offset, &value) != 0 || length % 2 != 0 || length > sizeof bytes * 2) return -1;
        for (size_t i = 0; i < length / 2; i++) {
            unsigned int byte;
            char pair[3] = { hex[i * 2], hex[i * 2 + 1], 0 };
            if (strspn(pair, "0123456789abcdefABCDEF") != 2 || sscanf(pair, "%x", &byte) != 1) return -1;
            bytes[i] = (unsigned char)byte;
        }
        return host_disk_set_patch(value, bytes, length / 2);
    }
    return 0;
}

static uint32_t le32(const unsigned char *p) {
    return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}
static uint64_t le64(const unsigned char *p) { return (uint64_t)le32(p) | (uint64_t)le32(p + 4) << 32; }
static int boot_signature(const unsigned char *boot) { return boot[510] == 0x55 && boot[511] == 0xaa; }
static int volume_header(const unsigned char *boot) {
    return memcmp(boot + 3, "EXFAT   ", 8) == 0 || (boot[11] == 0 && boot[12] == 2);
}
/* Host-side policy adapter: one superfloppy or one basic MBR partition.
   Rebase the selected region so FatFs cannot follow metadata outside it. */
static int select_volume(void) {
    unsigned char boot[512];
    uint64_t first = 0, count = host_disk_bytes() / 512;
    if (disk_read(0, boot, 0, 1) != RES_OK || !boot_signature(boot)) return -1;
    if (!volume_header(boot)) {
        unsigned int found = 0;
        for (size_t i = 0; i < 4; i++) {
            const unsigned char *part = boot + 446 + i * 16;
            if (part[4] == 0) continue;
            if (++found > 1) return -1;
            if (part[4] != 1 && part[4] != 4 && part[4] != 6 && part[4] != 7 &&
                part[4] != 0x0b && part[4] != 0x0c && part[4] != 0x0e) return -1;
            first = le32(part + 8);
            count = le32(part + 12);
        }
        if (found != 1 || first == 0 || count == 0 || first >= host_disk_bytes() / 512 || count > host_disk_bytes() / 512 - first) return -1;
        if (disk_read(0, boot, first, 1) != RES_OK || !boot_signature(boot) || !volume_header(boot)) return -1;
    }
    uint64_t declared;
    if (memcmp(boot + 3, "EXFAT   ", 8) == 0) {
        if (boot[108] != 9) return -1;
        declared = le64(boot + 72);
    } else {
        declared = (uint64_t)boot[19] | (uint64_t)boot[20] << 8;
        if (declared == 0) declared = le32(boot + 32);
    }
    if (declared == 0 || declared > count) return -1;
    return host_disk_select_region(first, declared);
}

int main(int argc, char **argv) {
    if (argc < 3 || host_disk_open(argv[1], 0) != 0) return 2;
    if (configure_overlay() != 0) return 2;
    const char *command = argv[2];
    if (strcmp(command, "disk-write") == 0) {
        const BYTE sector[512] = { 0xa5 };
        DRESULT status = disk_write(0, sector, 0, 1);
        printf("{\"status\":\"%s\"", status == RES_WRPRT ? "WriteProtected" : "Unexpected"); statistics();
        return host_disk_close() == 0 && status == RES_WRPRT ? 0 : 2;
    }
    if (strcmp(command, "write-open") == 0) {
        /* A compiled read-only FatFs silently masks FA_WRITE. Reject the
           request at our contract boundary, before mount or file access. */
        printf("{\"status\":\"ReadOnly\""); statistics();
        return host_disk_close() == 0 ? 0 : 2;
    }
    if (strcmp(command, "raw-mount") != 0 && select_volume() != 0) {
        printf("{\"status\":\"MountError\",\"layer\":\"boot-policy\""); statistics();
        return host_disk_close() == 0 ? 0 : 2;
    }
    FATFS fs;
    FRESULT result = f_mount(&fs, "", 1);
    if (result != FR_OK) {
        printf("{\"status\":\"MountError\",\"fresult\":%d", (int)result); statistics();
        return host_disk_close() == 0 ? 0 : 2;
    }
    if (strcmp(command, "mount") == 0 || strcmp(command, "raw-mount") == 0) {
        printf("{\"status\":\"OK\",\"fs_type\":%u", fs.fs_type); statistics();
    } else if (strcmp(command, "list") == 0) {
        DIR directory;
        FILINFO item;
        result = f_opendir(&directory, "");
        printf("{\"entries\":[");
        unsigned int count = 0;
        while (result == FR_OK && count < 128) {
            result = f_readdir(&directory, &item);
            if (result != FR_OK || item.fname[0] == 0) break;
            if (count++ != 0) putchar(',');
            printf("{\"name\":"); string(item.fname);
            printf(",\"alias\":"); string(item.altname);
            printf(",\"size\":%" PRIu64 "}", (uint64_t)item.fsize);
        }
        if (result == FR_OK) result = f_closedir(&directory);
        printf("],\"status\":\"%s\",\"fresult\":%d", count == 128 ? "Limit" : result == FR_OK ? "OK" : "Error", (int)result);
        statistics();
    } else if (strcmp(command, "read") == 0 || strcmp(command, "raw-write-open") == 0) {
        if (argc != 6 || !valid_path(argv[3])) return 2;
        uint64_t offset, amount;
        if (number(argv[4], &offset) != 0 || number(argv[5], &amount) != 0 || amount > 4096 || amount > UINT64_MAX - offset) return 2;
        FIL file;
        result = f_open(&file, argv[3], (BYTE)(FA_READ | (strcmp(command, "raw-write-open") == 0 ? FA_WRITE : 0)));
        UINT got = 0;
        unsigned char bytes[4096];
        uint64_t size = 0;
        if (result == FR_OK) {
            size = f_size(&file);
            if (offset < size) {
                result = f_lseek(&file, offset);
                if (result == FR_OK && f_tell(&file) != offset) result = FR_INT_ERR;
                if (result == FR_OK) result = f_read(&file, bytes, (UINT)amount, &got);
            }
            FRESULT closed = f_close(&file);
            if (result == FR_OK) result = closed;
        }
        printf("{\"status\":\"%s\",\"fresult\":%d,\"size\":%" PRIu64 ",\"count\":%u,\"eof\":%s,\"hex\":\"",
               result == FR_OK ? "OK" : "Error", (int)result, size, got,
               offset >= size || got >= size - offset ? "true" : "false");
        for (UINT i = 0; i < got; i++) printf("%02x", bytes[i]);
        printf("\""); statistics();
    } else return 2;
    result = f_mount(NULL, "", 0);
    if (host_disk_close() != 0 || result != FR_OK) return 2;
    return 0;
}
