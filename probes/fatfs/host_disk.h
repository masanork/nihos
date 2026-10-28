#ifndef NIHOS_HOST_DISK_H
#define NIHOS_HOST_DISK_H
#include <stddef.h>
#include <stdint.h>
#include "ff.h"
#include "diskio.h"

/* Private host images only; never a native/physical block driver. */
int host_disk_open(const char *path, uint64_t create_bytes);
int host_disk_close(void);
uint64_t host_disk_reads(void);
uint64_t host_disk_writes(void);
uint64_t host_disk_bytes(void);
uint64_t host_disk_out_of_range(void);
uint64_t host_disk_budget_exhaustions(void);
void host_disk_set_budget(uint64_t reads);
int host_disk_set_patch(uint64_t offset, const unsigned char *data, size_t length);
int host_disk_select_region(uint64_t first_sector, uint64_t sector_count);
#endif
