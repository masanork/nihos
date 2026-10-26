/* Host-only writable fixture generator. Never linked into target images. */
#include "lfs.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static unsigned char disk[64*512];
static uint32_t logical_size;
static int read_block(const struct lfs_config *c, lfs_block_t b, lfs_off_t o, void *p, lfs_size_t n) {
    (void)c;
    if (b >= sizeof(disk)/logical_size || o > logical_size || n > logical_size-o) return LFS_ERR_IO;
    memcpy(p, disk+b*logical_size+o, n); return 0;
}
static int prog_block(const struct lfs_config *c, lfs_block_t b, lfs_off_t o, const void *p, lfs_size_t n) {
    (void)c;
    if (b >= sizeof(disk)/logical_size || o > logical_size || n > logical_size-o) return LFS_ERR_IO;
    memcpy(disk+b*logical_size+o, p, n); return 0;
}
static int erase_block(const struct lfs_config *c, lfs_block_t b) {
    (void)c;
    if (b >= sizeof(disk)/logical_size) return LFS_ERR_IO;
    memset(disk+b*logical_size, 255, logical_size); return 0;
}
static int sync_block(const struct lfs_config *c) { (void)c; return 0; }
int main(int argc, char **argv) {
    if (argc != 3) return 1;
    logical_size=(uint32_t)strtoul(argv[2],NULL,10);
    if (logical_size != 512 && logical_size != 4096) return 1;
    lfs_t fs;
    struct lfs_config cfg = {.read=read_block, .prog=prog_block, .erase=erase_block, .sync=sync_block,
        .read_size=512, .prog_size=512, .block_size=logical_size, .block_count=sizeof(disk)/logical_size,
        .block_cycles=-1, .cache_size=512, .lookahead_size=8};
    memset(disk, 255, sizeof(disk));
    if (lfs_format(&fs, &cfg) || lfs_mount(&fs, &cfg) || lfs_mkdir(&fs, "dir")) return 2;
    lfs_file_t f;
    unsigned char payload[1300];
    for (unsigned i=0; i<sizeof(payload); ++i) payload[i]=(unsigned char)(i*17u+3u);
    if (lfs_file_open(&fs, &f, "hello.bin", LFS_O_WRONLY|LFS_O_CREAT) ||
        lfs_file_write(&fs, &f, payload, sizeof(payload)) != sizeof(payload) || lfs_file_close(&fs, &f)) return 3;
    if (lfs_file_open(&fs, &f, "empty", LFS_O_WRONLY|LFS_O_CREAT) || lfs_file_close(&fs, &f) || lfs_unmount(&fs)) return 4;
    FILE *out=fopen(argv[1], "wb");
    if (!out) return 5;
    int ok=fwrite(disk, 1, sizeof(disk), out)==sizeof(disk);
    return fclose(out) || !ok;
}
