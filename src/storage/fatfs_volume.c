/* Read-only volume admission. Geometry limits follow the pinned FatFs R0.16
 * profile (ff.c check_fs/mount_volume); upstream provenance is in
 * tools/bootstrap-fatfs.py. This does not replace its filesystem checks.
 */
#include "nihos_fatfs_volume.h"
#include <string.h>

static uint32_t le16(const uint8_t *p) {
    return (uint32_t)p[0] | (uint32_t)p[1] << 8;
}
static uint32_t le32(const uint8_t *p) {
    return le16(p) | le16(p + 2) << 16;
}
static uint64_t le64(const uint8_t *p) {
    return (uint64_t)le32(p) | (uint64_t)le32(p + 4) << 32;
}
static int signature(const uint8_t *p) { return p[510] == 0x55 && p[511] == 0xaa; }
static int power2(uint32_t n) { return n && !(n & (n - 1)); }

/* No on-disk offset is used as a physical address here. The owner-selected
 * first LBA is authoritative; hidden-sector/PartitionOffset fields are not.
 */
static nih_volume_status boot(const uint8_t *p, uint64_t container, nih_fatfs_volume *v) {
    uint64_t total, fat, overhead, clusters, needed;
    uint32_t spc, fats, reserved, roots;
    if (!memcmp(p + 3, "EXFAT   ", 8)) {
        if (!signature(p) || p[0] != 0xeb || p[1] != 0x76 || p[2] != 0x90)
            return NIH_VOLUME_CORRUPT;
        for (unsigned i = 11; i < 64; ++i) if (p[i]) return NIH_VOLUME_CORRUPT;
        /* Pinned FatFs supports one FAT and a 16-bit sector cluster size. */
        if (le16(p + 104) != 0x100 || p[108] != 9 || p[109] > 15 || p[110] != 1)
            return NIH_VOLUME_UNSUPPORTED;
        total = le64(p + 72);
        uint64_t fat_start = le32(p + 80), heap = le32(p + 88);
        fat = le32(p + 84);
        clusters = le32(p + 92);
        uint64_t root = le32(p + 96);
        spc = UINT32_C(1) << p[109];
        if (!total || total > container || fat_start < 24 || !fat ||
            heap < fat_start + fat || clusters < 256 || clusters > 0x7ffffffd ||
            root < 2 || root >= clusters + 2 || heap + clusters * spc > total ||
            (clusters + 2) * 4 > fat * 512) return NIH_VOLUME_CORRUPT;
        v->kind = NIH_VOLUME_EXFAT;
    } else {
        /* A type label alone is not evidence of a valid FAT volume. */
        int jump = p[0] == 0xeb || p[0] == 0xe9 || p[0] == 0xe8;
        int label = !memcmp(p + 54, "FAT", 3) || !memcmp(p + 82, "FAT32   ", 8);
        int legacy = le16(p + 11) == 512 && power2(p[13]) && le16(p + 14) &&
                     (p[16] == 1 || p[16] == 2) && le16(p + 17) && le16(p + 22);
        if (!jump || (!legacy && !label)) return NIH_VOLUME_NOT_FOUND;
        if (!signature(p) || le16(p + 11) != 512) return NIH_VOLUME_CORRUPT;
        spc = p[13]; fats = p[16]; reserved = le16(p + 14); roots = le16(p + 17);
        total = le16(p + 19);
        if (!total) total = le32(p + 32);
        fat = le16(p + 22);
        if (!fat) fat = le32(p + 36);
        if (!power2(spc) || !reserved || (fats != 1 && fats != 2) || roots % 16 ||
            !fat || fat >= 0x200000 || total < 64 || total > container)
            return NIH_VOLUME_CORRUPT;
        overhead = reserved + fat * fats + roots / 16;
        if (overhead >= total) return NIH_VOLUME_CORRUPT;
        clusters = (total - overhead) / spc;
        if (clusters <= 32 || clusters > 0x0ffffff5) return NIH_VOLUME_CORRUPT;
        v->kind = clusters <= 0xff5 ? NIH_VOLUME_FAT12 :
                  clusters <= 0xfff5 ? NIH_VOLUME_FAT16 : NIH_VOLUME_FAT32;
        if (v->kind == NIH_VOLUME_FAT32) {
            uint64_t root = le32(p + 44);
            if (roots || le16(p + 22) || le16(p + 42) || root < 2 || root >= clusters + 2 ||
                memcmp(p + 82, "FAT32   ", 8))
                return NIH_VOLUME_CORRUPT;
            needed = (clusters + 2) * 4;
        } else {
            if (!roots || !le16(p + 22)) return NIH_VOLUME_CORRUPT;
            needed = v->kind == NIH_VOLUME_FAT16 ? (clusters + 2) * 2 :
                     ((clusters + 2) * 3 + 1) / 2;
        }
        if (needed > fat * 512) return NIH_VOLUME_CORRUPT;
    }
    v->count = total;
    v->container_count = container;
    return NIH_VOLUME_OK;
}

typedef struct { uint64_t first, count; uint8_t type; } partition;
static int supported(uint8_t type) {
    return type == 0x01 || type == 0x04 || type == 0x06 || type == 0x07 ||
           type == 0x0b || type == 0x0c || type == 0x0e;
}
static nih_volume_status discover(nih_fatfs_sector_read read_sector, void *context,
    uint64_t sectors, uint32_t selection, uint8_t *scratch, nih_fatfs_volume *v) {
    if (read_sector(context, 0, scratch)) return NIH_VOLUME_IO;
    uint32_t reads = 1;
    if (selection == NIH_VOLUME_AUTO || selection == NIH_VOLUME_WHOLE) {
        nih_volume_status status = boot(scratch, sectors, v);
        if (status == NIH_VOLUME_OK) {
            v->layout = NIH_VOLUME_SUPERFLOPPY;
            v->reads = reads;
            return status;
        }
        if (status != NIH_VOLUME_NOT_FOUND || selection == NIH_VOLUME_WHOLE) return status;
    }
    if (!signature(scratch)) return NIH_VOLUME_NOT_FOUND;
    partition parts[4];
    int unsupported = 0;
    for (unsigned i = 0; i < 4; ++i) {
        const uint8_t *p = scratch + 446 + i * 16;
        parts[i] = (partition){ .first = le32(p + 8), .count = le32(p + 12), .type = p[4] };
        if (!p[4]) {
            for (unsigned j = 0; j < 16; ++j) if (p[j]) return NIH_VOLUME_CORRUPT;
            continue;
        }
        if ((p[0] != 0 && p[0] != 0x80) || !parts[i].first || !parts[i].count ||
            parts[i].first >= sectors || parts[i].count > sectors - parts[i].first)
            return NIH_VOLUME_CORRUPT;
        if (p[4] == 0xee || p[4] == 0x05 || p[4] == 0x0f || p[4] == 0x85) unsupported = 1;
        for (unsigned j = 0; j < i; ++j) {
            if (parts[j].count && parts[i].first < parts[j].first + parts[j].count &&
                parts[j].first < parts[i].first + parts[i].count) return NIH_VOLUME_CORRUPT;
        }
    }
    if (unsupported) return NIH_VOLUME_UNSUPPORTED;
    unsigned found = 0;
    for (unsigned i = 0; i < 4; ++i) {
        if (selection && selection != i + 1) continue;
        if (!parts[i].type) continue;
        if (!supported(parts[i].type)) {
            if (selection) return NIH_VOLUME_UNSUPPORTED;
            continue;
        }
        if (read_sector(context, (uint32_t)parts[i].first, scratch)) return NIH_VOLUME_IO;
        ++reads;
        nih_fatfs_volume candidate = {0};
        nih_volume_status status = boot(scratch, parts[i].count, &candidate);
        if (status == NIH_VOLUME_NOT_FOUND && !selection) continue;
        if (status != NIH_VOLUME_OK) return status;
        if (++found > 1) return NIH_VOLUME_AMBIGUOUS;
        candidate.first = parts[i].first;
        candidate.layout = NIH_VOLUME_MBR;
        candidate.partition = i + 1;
        *v = candidate;
    }
    v->reads = reads;
    return found ? NIH_VOLUME_OK : NIH_VOLUME_NOT_FOUND;
}

nih_volume_status nih_fatfs_volume_probe(nih_fatfs_sector_read read_sector,
    void *context, uint64_t device_sectors, uint32_t selection,
    uint8_t scratch[512], nih_fatfs_volume *output) {
    if (!read_sector || !scratch || !output || !device_sectors ||
        device_sectors > (UINT64_C(1) << 32) || selection > NIH_VOLUME_WHOLE)
        return NIH_VOLUME_INVALID;
    uintptr_t a = (uintptr_t)scratch, b = (uintptr_t)output;
    if (a <= b ? b - a < 512 : a - b < sizeof *output) return NIH_VOLUME_INVALID;
    nih_fatfs_volume result = {0};
    nih_volume_status status = discover(read_sector, context, device_sectors, selection, scratch, &result);
    memset(scratch, 0, 512);
    if (status == NIH_VOLUME_OK) *output = result;
    return status;
}
