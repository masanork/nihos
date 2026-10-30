#ifndef NIHOS_STORAGE_PROBE_H
#define NIHOS_STORAGE_PROBE_H
#include <stdint.h>
#include "nihos_storage.h"
/* Boot-only singleton, synchronous, no allocation or write API. These are
 * qualification operations, not a runtime filesystem service. */
typedef struct {
    uint32_t status, error_code, passes, block_size, block_count;
    uint32_t entries, files, directories, directory_digest;
    uint32_t file_bytes, file_crc, file_name_digest, reads, denied_writes;
} nih_storage_report;
int nih_storage_read(uint32_t lba, void *sector);
typedef struct {
    uint32_t status, opens, closes, cancelled, rejected, read_calls, workspace_bytes, used_bytes, cleared;
} nih_storage_api_report;
void nih_storage_probe(void *workspace, uint32_t bytes, uint32_t sectors,
                       nih_storage_report *report, nih_storage_api_report *api);
#endif
