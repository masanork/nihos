#ifndef NIHOS_FATFS_VOLUME_H
#define NIHOS_FATFS_VOLUME_H
#include "nihos_fatfs_disk.h"

/* Trusted owner admission, before disk_bind/backend_mount. No allocation,
 * writes, controller reset or global FatFs state. The callback has the same
 * fenced-return contract as diskio. Hold the device session across probe,
 * bind and mount; this result is neither a media identity nor a capability.
 * 512-byte sectors, <=2^32 sectors. GPT/extended MBR are unsupported.
 */
enum { NIH_VOLUME_AUTO = 0, NIH_VOLUME_WHOLE = 5 };
typedef enum {
    NIH_VOLUME_OK, NIH_VOLUME_INVALID, NIH_VOLUME_IO, NIH_VOLUME_CORRUPT,
    NIH_VOLUME_UNSUPPORTED, NIH_VOLUME_AMBIGUOUS, NIH_VOLUME_NOT_FOUND
} nih_volume_status;
typedef enum { NIH_VOLUME_SUPERFLOPPY = 1, NIH_VOLUME_MBR = 2 } nih_volume_layout;
typedef enum { NIH_VOLUME_FAT12 = 1, NIH_VOLUME_FAT16, NIH_VOLUME_FAT32,
               NIH_VOLUME_EXFAT } nih_volume_kind;
typedef struct {
    uint64_t first, count, container_count;
    uint32_t layout, kind, partition, reads;
} nih_fatfs_volume;

/* selection: AUTO, WHOLE, or the physical MBR slot 1..4. AUTO accepts a valid
 * superfloppy first, otherwise exactly one supported primary FAT/exFAT volume.
 * Validate ALL primary intervals before reading any partition. Return a view
 * narrowed to the VBR-declared length, never the unused container tail.
 * At most five sector reads. With valid arguments, scratch is cleared on all
 * returning paths; output is published only on success. Output and scratch
 * must not overlap. Geometry admission is not full filesystem validation:
 * mount, chain checks and operation budgets remain mandatory.
 */
nih_volume_status nih_fatfs_volume_probe(nih_fatfs_sector_read read_sector,
    void *context, uint64_t device_sectors, uint32_t selection,
    uint8_t scratch[512], nih_fatfs_volume *output);
#endif
