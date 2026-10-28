#include "nihos_fatfs_disk.h"
/* Provided by sdmmc_probe.ownedRead: a quarantined DMA fence never returns. */
extern int32_t nih_storage_read(uint32_t lba, uint8_t sector[512]);
#if NIH_FATFS_CARD_RPC
extern void nih_fatfs_fixture_after_read(void);
#endif
int nih_fatfs_native_read(void *unused, uint32_t lba, uint8_t sector[512]) {
    (void)unused;
    int result=(int)nih_storage_read(lba, sector);
#if NIH_FATFS_CARD_RPC
    if (!result) nih_fatfs_fixture_after_read(); /* AFTER the actual DMA fence. */
#endif
    return result;
}
