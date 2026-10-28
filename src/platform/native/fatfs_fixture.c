/* CPU-only immutable Flash fixture; no SD commands, DMA or media writes. */
#include <stdint.h>
#include <string.h>
#include "fatfs_fixture_data.h"
extern void nih_fatfs_fixture_after_read(void);
uint32_t nih_fatfs_fixture_sectors(void) { return NIH_FATFS_FIXTURE_SECTORS; }
uint32_t nih_fatfs_fixture_id(void) { return NIH_FATFS_FIXTURE_ID; }
int nih_fatfs_fixture_read(void *context, uint32_t lba, uint8_t output[512]) {
    (void)context;
    if (!output || lba >= NIH_FATFS_FIXTURE_SECTORS) return -1;
    size_t low = 0, high = sizeof nih_fatfs_fixture_index / sizeof *nih_fatfs_fixture_index;
    while (low < high) {
        size_t middle = low + (high - low) / 2;
        if (nih_fatfs_fixture_index[middle].lba < lba) low = middle + 1;
        else high = middle;
    }
    memset(output, 0, 512);
    if (low < sizeof nih_fatfs_fixture_index / sizeof *nih_fatfs_fixture_index && nih_fatfs_fixture_index[low].lba == lba) {
        const nih_fixture_entry *entry = &nih_fatfs_fixture_index[low];
        uint32_t end = (uint32_t)entry->offset + entry->length, written = 0;
        if (end > sizeof nih_fatfs_fixture_payload || entry->length % 2) return -1;
        for (uint32_t at = entry->offset; at < end; at += 2) {
            uint32_t count = nih_fatfs_fixture_payload[at];
            if (!count || count > 512 - written) return -1;
            memset(output + written, nih_fatfs_fixture_payload[at + 1], count);
            written += count;
        }
        if (written != 512) return -1;
    }
    nih_fatfs_fixture_after_read();
    return 0;
}
