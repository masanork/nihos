#include "host_disk.h"
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void require(FRESULT result, const char *operation) {
    if (result != FR_OK) { fprintf(stderr, "%s: FatFs result %d\n", operation, (int)result); exit(1); }
}
static void save(const char *name, const void *bytes, UINT length) {
    FIL file;
    UINT written = 0;
    require(f_open(&file, name, FA_CREATE_NEW | FA_WRITE), "create");
    require(f_write(&file, bytes, length, &written), "write");
    if (written != length) exit(1);
    require(f_close(&file), "close");
}

int main(int argc, char **argv) {
    if (argc != 3) return 2;
    BYTE format;
    uint64_t size;
    DWORD cluster = 512;
    int expected;
    if (strcmp(argv[2], "fat12") == 0) { format = FM_FAT | FM_SFD; size = 1024u * 1024u; expected = FS_FAT12; }
    else if (strcmp(argv[2], "fat16") == 0) { format = FM_FAT | FM_SFD; size = 16u * 1024u * 1024u; expected = FS_FAT16; }
    else if (strcmp(argv[2], "fat32") == 0) { format = FM_FAT32 | FM_SFD; size = 64u * 1024u * 1024u; expected = FS_FAT32; }
    else if (strcmp(argv[2], "mbr-fat32") == 0) { format = FM_FAT32; size = 64u * 1024u * 1024u; expected = FS_FAT32; }
    else if (strcmp(argv[2], "exfat") == 0) { format = FM_EXFAT | FM_SFD; size = UINT64_C(6) * 1024 * 1024 * 1024; cluster = 4096; expected = FS_EXFAT; }
    else return 2;
    if (host_disk_open(argv[1], size) != 0) { perror("fixture image"); return 1; }
    unsigned char workspace[32768];
    const MKFS_PARM options = { .fmt = format, .n_fat = 1, .align = 1, .n_root = 512, .au_size = cluster };
    require(f_mkfs("", &options, workspace, sizeof workspace), "mkfs");
    FATFS fs;
    require(f_mount(&fs, "", 1), "mount");
    if (fs.fs_type != expected) { fprintf(stderr, "wrong format: %u\n", fs.fs_type); return 1; }
    static const char memo[] = "nihos read-only fixture\n";
    static const char japanese[] = "日本語・か\xe3\x82\x99・𠮷\n";
    save("Memo.txt", memo, sizeof memo - 1);
    save("Long filename for alias.txt", "alias\n", 6);
    save("empty-a.txt", "", 0);
    save("empty-b.txt", "", 0);
    char long_ascii[256], long_utf8[766];
    memset(long_ascii, 'a', 251);
    memcpy(long_ascii + 251, ".txt", 5);
    save(long_ascii, "max-ascii\n", 10);
    for (size_t i = 0; i < 251; i++) memcpy(long_utf8 + i * 3, "漢", 3);
    memcpy(long_utf8 + 753, ".txt", 5);
    save(long_utf8, "max-utf8\n", 9);
    require(f_mkdir("教材"), "mkdir");
    save("教材/漢字𠮷.txt", japanese, sizeof japanese - 1);
    save("教材/か\xe3\x82\x99.txt", "decomposed\n", 11);
    save("教材/が.txt", "composed\n", 9);

    FIL fragmented, spacer;
    require(f_open(&fragmented, "fragment.bin", FA_CREATE_NEW | FA_WRITE), "fragment create");
    require(f_open(&spacer, "spacer.bin", FA_CREATE_NEW | FA_WRITE), "spacer create");
    UINT cluster_bytes = (UINT)fs.csize * 512;
    if (cluster_bytes > sizeof workspace) return 1;
    for (unsigned int i = 0; i < 8; i++) {
        UINT written;
        memset(workspace, (int)(0x30 + i), cluster_bytes);
        require(f_write(&fragmented, workspace, cluster_bytes, &written), "fragment write");
        if (written != cluster_bytes) return 1;
        memset(workspace, 0xee, cluster_bytes);
        require(f_write(&spacer, workspace, cluster_bytes, &written), "spacer write");
        if (written != cluster_bytes) return 1;
    }
    DWORD first_cluster = fragmented.obj.sclust;
    require(f_close(&fragmented), "fragment close");
    require(f_close(&spacer), "spacer close");

    uint64_t big_size = 0;
    if (fs.fs_type == FS_EXFAT) {
        FIL big;
        UINT written;
        big_size = UINT64_C(0x100002000);
        require(f_open(&big, "large.bin", FA_CREATE_NEW | FA_WRITE), "big create");
        require(f_expand(&big, big_size, 1), "big allocate");
        const uint64_t offsets[] = { UINT64_C(0x7ffffff8), UINT64_C(0xfffffff8), UINT64_C(0x100001ff0) };
        for (size_t i = 0; i < sizeof offsets / sizeof offsets[0]; i++) {
            unsigned char marker[16];
            for (unsigned int j = 0; j < sizeof marker; j++) marker[j] = (unsigned char)(0xa0 + i * 16 + j);
            require(f_lseek(&big, offsets[i]), "big seek");
            if (f_tell(&big) != offsets[i]) return 1;
            require(f_write(&big, marker, sizeof marker, &written), "big marker");
            if (written != sizeof marker) return 1;
        }
        require(f_close(&big), "big close");
    }
    FILINFO alias;
    require(f_stat("Long filename for alias.txt", &alias), "alias stat");
    printf("{\"format\":\"%s\",\"fs_type\":%u,\"image_bytes\":%" PRIu64 ",\"cluster_bytes\":%u,"
           "\"fragment_first_cluster\":%" PRIu32 ",\"fat_byte\":%" PRIu64 ",\"volume_byte\":%" PRIu64 ","
           "\"data_byte\":%" PRIu64 ",\"big_size\":%" PRIu64 ",\"alias\":\"%s\"}\n",
           argv[2], fs.fs_type, size, cluster_bytes, first_cluster, (uint64_t)fs.fatbase * 512,
           (uint64_t)fs.volbase * 512, (uint64_t)fs.database * 512, big_size, alias.altname);
    require(f_mount(NULL, "", 0), "unmount");
    if (host_disk_close() != 0) return 1;
    return 0;
}
