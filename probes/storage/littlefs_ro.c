/* nihOS adapter for unmodified littlefs v2.11.3 (BSD-3-Clause).
 * Compile with LFS_READONLY and LFS_NO_MALLOC. Full-card littlefs volumes
 * with 512- or 4096-byte filesystem blocks only. Caller provides serialization
 * and a bounded 512-byte sector reader. */
#include "nihos_storage_probe.h"
#include "lfs.h"
#include <string.h>

static lfs_t fs;
static uint8_t read_cache[512], prog_cache[512], file_cache[512], data[512], lookahead[8];
static lfs_file_t file;
static lfs_dir_t directory;
static struct lfs_info info;
static char selected[256];
static uint32_t reads, denied, capacity, logical_size;
#define READ_LIMIT 8192u
#define ENTRY_LIMIT 128u
#define FILE_LIMIT 65536u

static int read_sector(const struct lfs_config *c, lfs_block_t block,
                       lfs_off_t off, void *buffer, lfs_size_t size) {
    (void)c;
    const uint32_t sectors_per_block = logical_size / 512u;
    if (block >= capacity / sectors_per_block || off > logical_size || size > logical_size-off ||
            off % 512u || size % 512u) return LFS_ERR_IO;
    for (uint32_t i = 0; i < size; i += 512u) {
        if (reads >= READ_LIMIT) return LFS_ERR_IO;
        ++reads;
        if (nih_storage_read(block * sectors_per_block + (off+i)/512u, (uint8_t *)buffer+i) != 0) return LFS_ERR_IO;
    }
    return 0;
}
static int deny_prog(const struct lfs_config *c, lfs_block_t block, lfs_off_t off,
                     const void *buffer, lfs_size_t size) {
    (void)c; (void)block; (void)off; (void)buffer; (void)size;
    ++denied;
    return LFS_ERR_IO;
}
static int deny_erase(const struct lfs_config *c, lfs_block_t block) {
    (void)c; (void)block;
    ++denied;
    return LFS_ERR_IO;
}
static int deny_sync(const struct lfs_config *c) {
    (void)c;
    ++denied;
    return LFS_ERR_IO;
}
static uint32_t fold(uint32_t digest, uint8_t byte) { return (digest ^ byte) * 16777619u; }
static uint32_t fold_word(uint32_t digest, uint32_t word) {
    for (unsigned i = 0; i < 4; ++i) digest = fold(digest, (uint8_t)(word >> (8 * i)));
    return digest;
}
static uint32_t name_digest(uint32_t digest, const char *name) {
    for (unsigned i = 0; name[i]; ++i) digest = fold(digest, (uint8_t)name[i]);
    return fold(digest, 0);
}

static int one_pass(const struct lfs_config *cfg, nih_storage_report *r) {
    int err = lfs_mount(&fs, cfg);
    if (err) return err;
    err = lfs_dir_open(&fs, &directory, "/");
    if (err) goto unmount;
    r->block_size = cfg->block_size;
    r->block_count = cfg->block_count;
    selected[0] = 0;
    uint32_t smallest = FILE_LIMIT + 1u;
    r->directory_digest = 0x811c9dc5u;
    for (;;) {
        err = lfs_dir_read(&fs, &directory, &info);
        if (err <= 0) break;
        if (strcmp(info.name, ".") == 0 || strcmp(info.name, "..") == 0) continue;
        if (++r->entries > ENTRY_LIMIT) { err = LFS_ERR_FBIG; break; }
        if (info.type == LFS_TYPE_REG) ++r->files;
        else if (info.type == LFS_TYPE_DIR) ++r->directories;
        else { err = LFS_ERR_CORRUPT; break; }
        r->directory_digest = name_digest(r->directory_digest, info.name);
        r->directory_digest = fold_word(r->directory_digest, info.type);
        r->directory_digest = fold_word(r->directory_digest, info.size);
        if (info.type == LFS_TYPE_REG && info.size != 0 && info.size < smallest) {
            smallest = info.size;
            memcpy(selected, info.name, strlen(info.name) + 1);
        }
    }
    {
        int close_err = lfs_dir_close(&fs, &directory);
        if (!err) err = close_err;
    }
    if (err) goto unmount;
    if (selected[0]) {
        const struct lfs_file_config file_cfg = {.buffer = file_cache};
        err = lfs_file_opencfg(&fs, &file, selected, LFS_O_RDONLY, &file_cfg);
        if (err) goto unmount;
        r->file_name_digest = name_digest(0x811c9dc5u, selected);
        uint32_t crc = UINT32_MAX;
        while (r->file_bytes < smallest) {
            uint32_t want = smallest - r->file_bytes;
            if (want > sizeof(data)) want = sizeof(data);
            lfs_ssize_t got = lfs_file_read(&fs, &file, data, want);
            if (got <= 0 || (uint32_t)got > want) { err = got < 0 ? (int)got : LFS_ERR_CORRUPT; break; }
            for (lfs_ssize_t i = 0; i < got; ++i) {
                crc ^= data[i];
                for (unsigned b = 0; b < 8; ++b) crc = (crc >> 1) ^ ((crc & 1) ? 0xedb88320u : 0);
            }
            r->file_bytes += (uint32_t)got;
        }
        if (!err && lfs_file_read(&fs, &file, data, 1) != 0) err = LFS_ERR_CORRUPT;
        r->file_crc = ~crc;
        {
            int close_err = lfs_file_close(&fs, &file);
            if (!err) err = close_err;
        }
    }
unmount:
    {
        int close_err = lfs_unmount(&fs);
        if (!err) err = close_err;
    }
    return err;
}

void nih_storage_probe(uint32_t sectors, nih_storage_report *report) {
    memset(report, 0, sizeof(*report));
    report->status = 3; report->error_code = (uint32_t)(-LFS_ERR_INVAL);
    reads = 0; denied = 0; capacity = sectors;
    struct lfs_config cfg = {
        .read = read_sector, .prog = deny_prog, .erase = deny_erase, .sync = deny_sync,
        .read_size = 512, .prog_size = 512, .block_size = 512, .block_count = sectors,
        .block_cycles = -1, .cache_size = 512, .lookahead_size = 8, .read_buffer = read_cache,
        .prog_buffer = prog_cache, .lookahead_buffer = lookahead,
    };
    // Do not interpret an unvalidated magic string as a superblock. Try two
    // bounded, supported geometries and let upstream validate the metadata.
    const uint32_t geometries[] = {512, 4096};
    for (unsigned geometry = 0; geometry < 2; ++geometry) {
        logical_size = geometries[geometry];
        if (sectors < logical_size/512u || sectors % (logical_size/512u)) continue;
        cfg.block_size = logical_size;
        cfg.block_count = sectors / (logical_size/512u);
        int err = 0;
        for (unsigned pass = 0; pass < 2; ++pass) {
            nih_storage_report current = {0};
            err = one_pass(&cfg, &current);
            if (!err && pass && (current.entries != report->entries || current.files != report->files ||
                    current.directories != report->directories || current.directory_digest != report->directory_digest ||
                    current.file_bytes != report->file_bytes || current.file_crc != report->file_crc ||
                    current.file_name_digest != report->file_name_digest)) err = LFS_ERR_CORRUPT;
            if (err) { report->status = 3; report->error_code = (uint32_t)(-err); break; }
            current.passes = pass + 1;
            current.status = current.file_bytes ? 2 : 1;
            *report = current;
        }
        if (!err || report->passes || (err != LFS_ERR_INVAL && err != LFS_ERR_CORRUPT)) break;
    }
    report->reads = reads; report->denied_writes = denied;
}
