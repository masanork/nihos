#include "nihos_fatfs_backend.h"
#include "safety.h"
#include "diskio.h"
#include <string.h>

_Static_assert(FF_FS_READONLY == 1 && FF_FS_LOCK == 0 && FF_FS_REENTRANT == 0 &&
               sizeof(FSIZE_t) == 8, "pinned single-owner read-only backend required");
enum { OPEN_LIMIT = 16, SLOT_COUNT = OPEN_LIMIT + 1, CHAIN_BUDGET = 8192 };
typedef struct { FIL file; uint64_t identity, token; int used; } file_slot;
struct nih_fatfs_backend {
    FATFS fs;
    file_slot slots[SLOT_COUNT];
    nih_fatfs_disk *disk;
    uint64_t epoch, next_token;
    int mounted, registered, busy, failure;
    char path[512];
    uint8_t output[NIH_FATFS_IO_BYTES];
};
static nih_fatfs_backend *live;
_Static_assert(_Alignof(nih_fatfs_backend) <= 8, "backend workspace alignment changed");

uint32_t nih_fatfs_backend_bytes(void) { return (uint32_t)sizeof(nih_fatfs_backend); }
static int match(nih_fatfs_backend *s, uint64_t epoch) {
    return s && live == s && s->epoch == epoch;
}
static int health(nih_fatfs_backend *s) {
    if (s->failure) return s->failure;
    if (s->disk->state == NIH_FATFS_REMOVED) s->failure = NIH_FB_REMOVED;
    else if (s->disk->state != NIH_FATFS_READY) s->failure = NIH_FB_IO;
    return s->failure;
}
static int begin(nih_fatfs_backend *s, uint64_t epoch) {
    if (!match(s, epoch)) return NIH_FB_STALE;
    if (s->busy) return NIH_FB_BUSY;
    int err = health(s);
    if (err) return err;
    if (!s->mounted) return NIH_FB_STALE;
    if (nih_fatfs_disk_arm(s->disk, epoch, NIH_FATFS_READ_BUDGET)) return NIH_FB_IO;
    s->busy = 1;
    return NIH_FB_OK;
}
static int result(nih_fatfs_backend *s, FRESULT value) {
    int err = health(s);
    if (err) return err;
    switch (value) {
        case FR_OK: return NIH_FB_OK;
        case FR_NO_FILE: case FR_NO_PATH: return NIH_FB_NOT_FOUND;
        case FR_INVALID_NAME: return NIH_FB_INVALID_NAME;
        case FR_INT_ERR: case FR_NO_FILESYSTEM: s->failure = NIH_FB_CORRUPT; break;
        default: s->failure = NIH_FB_IO; break;
    }
    return s->failure;
}
static void drop(file_slot *slot) {
    if (slot->used) (void)f_close(&slot->file);
    memset(slot, 0, sizeof *slot);
}
nih_fatfs_backend *nih_fatfs_backend_init(void *workspace, uint32_t bytes,
                                        nih_fatfs_disk *disk, uint64_t epoch) {
    if (live || !workspace || (uintptr_t)workspace % 8 || bytes < sizeof(nih_fatfs_backend) ||
            !disk) return NULL;
    uintptr_t w = (uintptr_t)workspace, d = (uintptr_t)disk;
    if (w <= d ? d - w < sizeof(nih_fatfs_backend) : w - d < sizeof *disk) return NULL;
    if (disk->epoch != epoch || disk->busy || disk->retained || nih_fatfs_disk_arm(disk, epoch, 0) ||
            nih_fatfs_disk_retain(disk, epoch)) return NULL;
    nih_fatfs_backend *s = workspace;
    memset(s, 0, sizeof *s);
    s->disk = disk;
    s->epoch = epoch;
    s->next_token = 1;
    live = s;
    return s;
}
static uint32_t le32(const uint8_t *p) {
    return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}
/* This layer consumes a selected region; it does not discover MBR/GPT. */
static int volume(nih_fatfs_backend *s) {
    uint8_t *boot = s->output;
    if (disk_read(0, boot, 0, 1) != RES_OK) return NIH_FB_IO;
    if (boot[510] != 0x55 || boot[511] != 0xaa) return NIH_FB_CORRUPT;
    uint64_t declared;
    if (!memcmp(boot + 3, "EXFAT   ", 8)) {
        if (boot[108] != 9) return NIH_FB_CORRUPT;
        declared = (uint64_t)le32(boot + 72) | (uint64_t)le32(boot + 76) << 32;
    } else {
        if (boot[11] != 0 || boot[12] != 2) return NIH_FB_CORRUPT;
        declared = (uint32_t)boot[19] | (uint32_t)boot[20] << 8;
        if (!declared) declared = le32(boot + 32);
    }
    return declared && declared <= s->disk->count ? NIH_FB_OK : NIH_FB_CORRUPT;
}
int nih_fatfs_backend_mount(nih_fatfs_backend *s, uint64_t epoch) {
    if (!match(s, epoch)) return NIH_FB_STALE;
    if (s->busy || s->mounted || s->registered) return NIH_FB_BUSY;
    int err = health(s);
    if (err) return err;
    if (nih_fatfs_disk_arm(s->disk, epoch, NIH_FATFS_READ_BUDGET)) return NIH_FB_IO;
    s->busy = 1;
    err = volume(s);
    if (!err) {
        s->registered = 1;
        err = result(s, f_mount(&s->fs, "", 1));
    }
    if (!err) s->mounted = 1;
    else s->failure = health(s) ? health(s) : err;
    s->busy = 0;
    return err;
}
int nih_fatfs_backend_lookup(nih_fatfs_backend *s, uint64_t epoch, uint64_t root,
                            const char *path, uint32_t length, uint64_t *identity) {
    if (!path || !identity || root != 1 || !length || length > 511 || memchr(path, 0, length)) return NIH_FB_INVALID_NAME;
    int err = begin(s, epoch);
    if (err) return err;
    file_slot *pending = NULL;
    for (unsigned i = 0; i < SLOT_COUNT; ++i) {
        if (s->slots[i].used == 1) drop(&s->slots[i]);
        if (!s->slots[i].used && !pending) pending = &s->slots[i];
    }
    if (!pending) { s->busy = 0; return NIH_FB_NO_HANDLES; }
    memcpy(s->path, path, length);
    s->path[length] = 0;
    nih_ro_identity found = {0};
    nih_ro_control control = {.remaining = CHAIN_BUDGET};
    nih_ro_status status = nih_ro_open(&pending->file, s->path, &found, &control);
    if (status == NIH_RO_OK) {
        pending->used = 1;
        pending->identity = *identity = nih_ro_identity_key(found);
    } else if (status == NIH_RO_LIMIT) err = NIH_FB_LIMIT;
    else if (status == NIH_RO_CORRUPT) err = s->failure = NIH_FB_CORRUPT;
    else err = result(s, control.fat_result == FR_OK ? FR_DISK_ERR : control.fat_result);
    if (health(s)) err = health(s);
    s->busy = 0;
    return err;
}
int nih_fatfs_backend_open(nih_fatfs_backend *s, uint64_t epoch, uint64_t identity, uint64_t *token) {
    if (!token) return NIH_FB_STALE;
    int err = begin(s, epoch);
    if (err) return err;
    unsigned opened = 0;
    file_slot *pending = NULL;
    for (unsigned i = 0; i < SLOT_COUNT; ++i) {
        if (s->slots[i].used == 2) ++opened;
        if (s->slots[i].used == 1 && s->slots[i].identity == identity) pending = &s->slots[i];
    }
    if (!pending) err = NIH_FB_STALE;
    else if (opened == OPEN_LIMIT || s->next_token == UINT64_MAX) err = NIH_FB_NO_HANDLES;
    else {
        pending->used = 2;
        pending->token = *token = s->next_token++;
    }
    s->busy = 0;
    return err;
}
int nih_fatfs_backend_read(nih_fatfs_backend *s, uint64_t epoch, uint64_t token,
                          uint64_t offset, void *output, uint32_t length,
                          uint32_t *transferred, uint32_t *eof) {
    if (!transferred || !eof || (!output && length) || length > NIH_FATFS_IO_BYTES) return NIH_FB_LIMIT;
    *transferred = *eof = 0;
    int err = begin(s, epoch);
    if (err) return err;
    file_slot *slot = NULL;
    for (unsigned i = 0; i < SLOT_COUNT; ++i)
        if (s->slots[i].used == 2 && s->slots[i].token == token) slot = &s->slots[i];
    if (!slot) { s->busy = 0; return NIH_FB_STALE; }
    uint64_t size = f_size(&slot->file);
    if (offset >= size) *eof = 1;
    else if (length) {
        UINT wanted = (UINT)(size - offset < length ? size - offset : length), got = 0;
        err = result(s, f_lseek(&slot->file, offset));
        if (!err && f_tell(&slot->file) != offset) err = s->failure = NIH_FB_CORRUPT;
        if (!err) err = result(s, f_read(&slot->file, s->output, wanted, &got));
        if (!err && got != wanted) err = s->failure = NIH_FB_CORRUPT;
        if (!err) {
            memcpy(output, s->output, got);
            *transferred = got;
            *eof = offset + got >= size;
        }
    }
    s->busy = 0;
    return err;
}
int nih_fatfs_backend_close(nih_fatfs_backend *s, uint64_t epoch, uint64_t token) {
    if (!match(s, epoch)) return NIH_FB_STALE;
    if (s->busy) return NIH_FB_BUSY;
    for (unsigned i = 0; i < SLOT_COUNT; ++i) {
        if (s->slots[i].used == 2 && s->slots[i].token == token) { drop(&s->slots[i]); return NIH_FB_OK; }
    }
    return NIH_FB_STALE;
}
int nih_fatfs_backend_remove(nih_fatfs_backend *s, uint64_t epoch) {
    if (!match(s, epoch)) return NIH_FB_STALE;
    s->failure = NIH_FB_REMOVED;
    return nih_fatfs_disk_invalidate(s->disk, epoch) ? NIH_FB_STALE : NIH_FB_OK;
}
int nih_fatfs_backend_destroy(nih_fatfs_backend *s, uint64_t epoch) {
    if (!match(s, epoch)) return NIH_FB_STALE;
    if (s->busy || s->disk->busy) return NIH_FB_BUSY;
    for (unsigned i = 0; i < SLOT_COUNT; ++i) drop(&s->slots[i]);
    if (s->registered) (void)f_mount(NULL, "", 0);
    if (nih_fatfs_disk_release(s->disk, epoch) || nih_fatfs_disk_detach(s->disk, epoch)) return NIH_FB_BUSY;
    memset(s, 0, sizeof *s);
    live = NULL;
    return NIH_FB_OK;
}
