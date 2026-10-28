#ifndef NIHOS_FATFS_CARD_H
#define NIHOS_FATFS_CARD_H
#include <stdint.h>
typedef struct {
    uint32_t status, generation, sectors, kind, partition, first, count;
    uint32_t bytes, crc, repeated_crc, file_name_crc, reads, destroyed;
    uint32_t charged, cleared, recovered;
} nih_fatfs_card_report;
uint32_t nih_fatfs_card_bytes(void);
/* Stable fenced device session; workspace stays pinned through return.
 * 1: prefix read twice, 0: rejected/unsuitable input after clean teardown,
 * -1: teardown unproved, caller must retain session/workspace and stop.
 * Scans at most 64 root entries, chooses a nonempty regular file <=1 MiB,
 * reads at most 4096 bytes twice. No file names or contents are logged.
 */
int nih_fatfs_card_read(void *, uint32_t bytes, uint32_t sectors,
                       uint32_t generation, nih_fatfs_card_report *);
#endif
