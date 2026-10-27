/* Narrow shim over pinned FatFs internals. Keep upstream source unmodified.
   Including the verified translation unit makes get_fat/follow_path available
   without exporting private upstream types or adding a second FAT parser. */
#include "ff.c"
#include "safety.h"

_Static_assert(FF_DEFINED == 80386 && FF_FS_READONLY && !FF_FS_RPATH, "pinned read-only FatFs contract required");

static nih_ro_status tick(nih_ro_control *control) {
    if (control->cancelled && control->cancelled(control->context)) return NIH_RO_CANCELLED;
    if (control->remaining == 0) return NIH_RO_LIMIT;
    control->remaining--;
    control->steps++;
    return NIH_RO_OK;
}

static int is_end(BYTE format, DWORD value) {
    switch (format) {
        case FS_FAT12: return value >= 0xff8;
        case FS_FAT16: return value >= 0xfff8;
        case FS_FAT32: return value >= 0x0ffffff8;
        case FS_EXFAT: return value == 0x7fffffff;
        default: return 0;
    }
}

/* Brent cycle detection, constant workspace, and a shared step/cancel budget.
   A valid but too long chain returns LIMIT, never a false corruption result. */
static nih_ro_status chain(FFOBJID object, int directory, nih_ro_control *control) {
    FATFS *fs = object.fs;
    uint64_t bytes_per_cluster = (uint64_t)fs->csize * SS(fs);
    if (bytes_per_cluster == 0 || fs->n_fatent < 3) return NIH_RO_CORRUPT;
    uint64_t needed = object.objsize / bytes_per_cluster + (object.objsize % bytes_per_cluster != 0);
    if (directory && object.sclust == 0) {
        if (fs->fs_type == FS_FAT12 || fs->fs_type == FS_FAT16) return tick(control);
        if (fs->dirbase > UINT32_MAX) return NIH_RO_CORRUPT;
        object.sclust = (DWORD)fs->dirbase;
        object.stat = 0;
        object.objsize = 0;
        needed = 0;
    }
    if (object.sclust == 0) return needed == 0 ? tick(control) : NIH_RO_CORRUPT;
    if (object.sclust < 2 || object.sclust >= fs->n_fatent || needed > fs->n_fatent - 2) return NIH_RO_CORRUPT;
    if (fs->fs_type == FS_EXFAT && object.stat == 2) {
        nih_ro_status status = tick(control);
        if (status != NIH_RO_OK) return status;
        return needed != 0 && needed <= (uint64_t)fs->n_fatent - object.sclust ? NIH_RO_OK : NIH_RO_CORRUPT;
    }
    DWORD current = object.sclust, anchor = current;
    uint64_t power = 1, distance = 0, visited = 0;
    for (;;) {
        nih_ro_status status = tick(control);
        if (status != NIH_RO_OK) return status;
        DWORD next = get_fat(&object, current);
        visited++;
        if (next == 0xffffffff) return NIH_RO_IO;
        if (is_end(fs->fs_type, next)) return visited >= needed ? NIH_RO_OK : NIH_RO_CORRUPT;
        DWORD reserved = fs->fs_type == FS_FAT12 ? 0xff0 : fs->fs_type == FS_FAT16 ? 0xfff0 :
                         fs->fs_type == FS_FAT32 ? 0x0ffffff0 : 0x7ffffff7;
        if (next < 2 || next >= fs->n_fatent || next >= reserved || next == anchor) return NIH_RO_CORRUPT;
        distance++;
        if (distance == power) {
            anchor = next;
            power *= 2; /* Bound by uint32_t step budget, so no uint64_t wrap. */
            distance = 0;
        }
        current = next;
    }
}

static nih_ro_status lookup_result(FRESULT result, nih_ro_control *control) {
    control->fat_result = result;
    if (result == FR_OK) return NIH_RO_OK;
    return result == FR_DISK_ERR || result == FR_NOT_READY ? NIH_RO_IO :
           result == FR_INT_ERR ? NIH_RO_CORRUPT : NIH_RO_LOOKUP;
}

static int relative_name(const char *path, int allow_empty) {
    if (!path) return 0;
    size_t length = 0, start = 0;
    while (length < 512 && path[length]) length++;
    if (length == 512 || (!allow_empty && length == 0)) return 0;
    if (length == 0) return 1;
    for (size_t i = 0; i <= length; i++) {
        if (path[i] == ':' || path[i] == '\\') return 0;
        if (path[i] == '/' || path[i] == 0) {
            size_t size = i - start;
            if (size == 0 || (size == 1 && path[start] == '.') ||
                (size == 2 && path[start] == '.' && path[start + 1] == '.')) return 0;
            start = i + 1;
        }
    }
    return 1;
}

/* Validate each containing directory before any lookup can scan its entries.
   The caller's read-only mount and single-owner lease prohibit mutation between
   validation, identity capture, and the final open. */
static nih_ro_status parents(const char *path, nih_ro_control *control) {
    DIR directory = {0};
    FRESULT result = f_opendir(&directory, "");
    nih_ro_status status = lookup_result(result, control);
    if (status != NIH_RO_OK) return status;
    DWORD ancestors[17]; /* Root plus at most 16 containing directories. */
    size_t depth = 1;
    ancestors[0] = directory.obj.sclust ? directory.obj.sclust :
                   directory.obj.fs->fs_type >= FS_FAT32 ? (DWORD)directory.obj.fs->dirbase : 0;
    status = chain(directory.obj, 1, control);
    result = f_closedir(&directory);
    if (status != NIH_RO_OK) return status;
    if (result != FR_OK) return lookup_result(result, control);
    char prefix[512];
    size_t length = strlen(path);
    if (length > 511) return NIH_RO_LIMIT;
    for (size_t i = 0; i < length; i++) {
        prefix[i] = path[i];
        if (path[i] != '/') continue;
        if (depth == sizeof ancestors / sizeof ancestors[0]) return NIH_RO_LIMIT;
        prefix[i] = 0;
        memset(&directory, 0, sizeof directory);
        result = f_opendir(&directory, prefix);
        status = lookup_result(result, control);
        if (status != NIH_RO_OK) return status;
        if (directory.obj.sclust < 2) status = NIH_RO_CORRUPT;
        for (size_t j = 0; j < depth; j++) {
            if (directory.obj.sclust == ancestors[j]) status = NIH_RO_CORRUPT;
        }
        if (status != NIH_RO_OK) { (void)f_closedir(&directory); return status; }
        ancestors[depth++] = directory.obj.sclust;
        status = chain(directory.obj, 1, control);
        result = f_closedir(&directory);
        if (status != NIH_RO_OK) return status;
        if (result != FR_OK) return lookup_result(result, control);
        prefix[i] = '/';
    }
    return NIH_RO_OK;
}

static FRESULT identity_of(const TCHAR *path, nih_ro_identity *identity) {
    FATFS *fs;
    DIR directory = {0};
    DEF_NAMEBUFF
    FRESULT result = mount_volume(&path, &fs, 0);
    if (result != FR_OK) return result;
    directory.obj.fs = fs;
    INIT_NAMEBUFF(fs);
    result = follow_path(&directory, path);
    if (result == FR_OK) {
        if (directory.fn[NSFLAG] & NS_NONAME || directory.obj.attr & AM_DIR) result = FR_INVALID_NAME;
        else {
            identity->directory_cluster = directory.obj.sclust ? directory.obj.sclust :
                                          fs->fs_type >= FS_FAT32 ? (DWORD)fs->dirbase : 0;
            identity->entry_offset = fs->fs_type == FS_EXFAT ? directory.blk_ofs : directory.dptr;
        }
    }
    FREE_NAMEBUFF();
    return result;
}

nih_ro_status nih_ro_open(FIL *file, const char *path, nih_ro_identity *identity, nih_ro_control *control) {
    if (!relative_name(path, 0)) return lookup_result(FR_INVALID_NAME, control);
    nih_ro_status status = parents(path, control);
    if (status != NIH_RO_OK) return status;
    status = tick(control);
    if (status != NIH_RO_OK) return status;
    status = lookup_result(identity_of(path, identity), control);
    if (status != NIH_RO_OK) return status;
    status = lookup_result(f_open(file, path, FA_READ), control);
    if (status != NIH_RO_OK) return status;
    status = chain(file->obj, 0, control);
    if (status != NIH_RO_OK) {
        (void)f_close(file);
        memset(file, 0, sizeof *file);
    }
    return status;
}

nih_ro_status nih_ro_directory(DIR *directory, const char *path, nih_ro_control *control) {
    if (!relative_name(path, 1)) return lookup_result(FR_INVALID_NAME, control);
    nih_ro_status status = parents(path, control);
    if (status != NIH_RO_OK) return status;
    status = tick(control);
    if (status != NIH_RO_OK) return status;
    status = lookup_result(f_opendir(directory, path), control);
    if (status != NIH_RO_OK) return status;
    status = chain(directory->obj, 1, control);
    if (status != NIH_RO_OK) (void)f_closedir(directory);
    return status;
}

const char *nih_ro_status_name(nih_ro_status status) {
    static const char *names[] = { "OK", "Corrupt", "BudgetExceeded", "Cancelled", "IoError", "LookupError" };
    return (unsigned int)status < sizeof names / sizeof names[0] ? names[status] : "Invalid";
}
