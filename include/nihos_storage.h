#ifndef NIHOS_STORAGE_H
#define NIHOS_STORAGE_H
#include <stdint.h>
/* Trusted, synchronous, single-owner C backend. The runtime must serialize
 * entry and supply the owner identity; this is not an untrusted syscall ABI.
 * One open file per session, canonical absolute paths, <=512 bytes per read.
 * No allocation/write API. Tokens live only for this workspace's lifetime.
 * Workspace must be aligned to 8 bytes and remain valid until destroy. */
#define NIH_RO_WORKSPACE_BYTES 8192u
#define NIH_RO_PATH_MAX 255u
#define NIH_RO_READ_MAX 512u
typedef struct nih_ro nih_ro;
typedef int (*nih_ro_sector_read)(void *context, uint32_t lba, void *sector);
typedef struct { uint32_t type, size; } nih_ro_info;
enum { NIH_RO_INVAL=-22, NIH_RO_IO=-5, NIH_RO_BUSY=-16, NIH_RO_BADF=-9,
       NIH_RO_OWNER=-13, NIH_RO_NODEV=-19, NIH_RO_LIMIT=-27 };
/* Init requires an unused/quiesced workspace. No outstanding session/token
 * may survive reinitialization; mounted sessions must be destroyed first. */
nih_ro *nih_ro_init(void *workspace, uint32_t bytes, nih_ro_sector_read read, void *context);
int nih_ro_mount(nih_ro *session, uint32_t sectors);
int nih_ro_stat(nih_ro *session, const char *path, uint32_t length, nih_ro_info *info);
int nih_ro_open(nih_ro *session, uint32_t owner, const char *path, uint32_t length, uint32_t *handle);
/* Returns bytes read (0 at EOF), or a negative error. Offsets beyond EOF and
 * lengths above READ_MAX fail. IO/metadata errors poison the mounted session:
 * close/release/unmount/destroy remain available for cleanup. */
int nih_ro_read_at(nih_ro *session, uint32_t owner, uint32_t handle, uint32_t offset, void *buffer, uint32_t length);
int nih_ro_close(nih_ro *session, uint32_t owner, uint32_t handle);
int nih_ro_release_owner(nih_ro *session, uint32_t owner);
int nih_ro_unmount(nih_ro *session);
/* Closes outstanding file and unmounts. On success clears the whole supplied
 * workspace; callers must not use session pointers afterward. */
int nih_ro_destroy(nih_ro *session);
#endif
