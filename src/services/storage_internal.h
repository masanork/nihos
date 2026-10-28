/* Private littlefs implementation state, all inside caller-owned workspace. */
#ifndef NIHOS_STORAGE_INTERNAL_H
#define NIHOS_STORAGE_INTERNAL_H
#include "nihos_storage.h"
#include "lfs.h"
struct nih_ro {
    lfs_t fs;
    struct lfs_config cfg;
    struct lfs_file_config file_cfg;
    lfs_file_t file;
    lfs_dir_t directory;
    struct lfs_info info;
    uint8_t read_cache[512], prog_cache[512], file_cache[512], data[512], lookahead[8];
    char path[256], selected[256];
    nih_ro_sector_read read;
    void *context;
    uint32_t capacity, logical_size, reads, denied, remaining, bytes, max_reads;
    uint32_t owner, handle, next_handle, file_size;
    uint8_t mounted, opened, poisoned;
};
_Static_assert(sizeof(struct nih_ro) <= NIH_RO_WORKSPACE_BYTES, "workspace too small");
#endif
