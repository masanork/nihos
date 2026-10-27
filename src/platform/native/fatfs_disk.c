#include "nihos_fatfs_disk.h"
/* Provided by sdmmc_probe.ownedRead: a quarantined DMA fence never returns. */
extern int32_t nih_storage_read(uint32_t lba, uint8_t sector[512]);
int nih_fatfs_native_read(void *unused, uint32_t lba, uint8_t sector[512]) {
    (void)unused;
    return (int)nih_storage_read(lba, sector);
}
