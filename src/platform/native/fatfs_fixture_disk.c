#include "nihos_fatfs_disk.h"
extern uint32_t nih_fatfs_fixture_sectors(void);
extern int nih_fatfs_fixture_read(void *, uint32_t, uint8_t [512]);
uint32_t nih_fatfs_native_disk_bytes(void) { return sizeof(nih_fatfs_disk); }
int nih_fatfs_fixture_bind(void *workspace, uint64_t epoch) {
    uint32_t count = nih_fatfs_fixture_sectors();
    return nih_fatfs_disk_bind(workspace,nih_fatfs_fixture_read,0,count,0,count,epoch);
}
