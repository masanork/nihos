#ifndef NIHOS_FATFS_SAFETY_H
#define NIHOS_FATFS_SAFETY_H
#include <stdint.h>
#include "ff.h"

typedef enum {
    NIH_RO_OK, NIH_RO_CORRUPT, NIH_RO_LIMIT, NIH_RO_CANCELLED, NIH_RO_IO, NIH_RO_LOOKUP
} nih_ro_status;
typedef struct {
    uint32_t remaining;
    uint32_t steps;
    int (*cancelled)(void *context);
    void *context;
    FRESULT fat_result;
} nih_ro_control;
/* Identity is directory start cluster + entry offset, scoped by mount epoch.
   It does not depend on file size or the file's first data cluster. */
typedef struct { uint32_t directory_cluster, entry_offset; } nih_ro_identity;
static inline uint64_t nih_ro_identity_key(nih_ro_identity identity) {
    return (uint64_t)identity.directory_cluster << 32 | identity.entry_offset;
}
nih_ro_status nih_ro_open(FIL *file, const char *path, nih_ro_identity *identity, nih_ro_control *control);
nih_ro_status nih_ro_directory(DIR *directory, const char *path, nih_ro_control *control);
const char *nih_ro_status_name(nih_ro_status status);
#endif
