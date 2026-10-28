#ifndef NIHOS_FATFS_CARD_H
#define NIHOS_FATFS_CARD_H
#include <stdint.h>
#include "nihos_fatfs_backend.h"
typedef struct nih_fatfs_card nih_fatfs_card;
typedef struct {
    uint32_t status, generation, sectors, kind, partition, first, count;
    uint32_t bytes, crc, repeated_crc, file_name_crc, reads, destroyed;
    uint32_t charged, cleared, recovered;
} nih_fatfs_card_report;
uint32_t nih_fatfs_card_bytes(void);
/* Serialized trusted owner. Context/path/Backend remain pinned through RPC
 * drain and handle revocation, until destroy. No client or IRQ pointers.
 * Mount returns 1 on success, 0 after clean rejection, -1 on unproved rollback;
 * failure leaves *context unchanged. At most one live card. Output context
 * and report must be disjoint from each other and the C workspace.
 */
int nih_fatfs_card_mount(void *, uint32_t bytes, uint32_t sectors,
    uint32_t generation, nih_fatfs_card **context, nih_fatfs_card_report *);
nih_fatfs_backend *nih_fatfs_card_backend(nih_fatfs_card *, uint32_t generation);
const char *nih_fatfs_card_path(nih_fatfs_card *, uint32_t generation);
uint32_t nih_fatfs_card_reads(nih_fatfs_card *, uint32_t generation);
/* Stale identity returns 0 without touching the active card. Busy teardown
 * returns -1 and retains context/session/pin. Success clears the C workspace
 * and invalidates accessors. End the device session and release broker memory
 * only after success. All public VFS/RPC references must already be gone. */
int nih_fatfs_card_destroy(nih_fatfs_card *, uint32_t generation);
/* Stable fenced device session; workspace stays pinned through return.
 * 1: prefix read twice, 0: rejected/unsuitable input after clean teardown,
 * -1: teardown unproved, caller must retain session/workspace and stop.
 * Scans at most 64 root entries, chooses a nonempty regular file <=1 MiB,
 * reads at most 4096 bytes twice. No file names or contents are logged.
 */
int nih_fatfs_card_read(void *, uint32_t bytes, uint32_t sectors,
                       uint32_t generation, nih_fatfs_card_report *);
#endif
