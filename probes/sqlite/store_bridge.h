#ifndef NIH_SQLITE_STORE_BRIDGE_H
#define NIH_SQLITE_STORE_BRIDGE_H
#include <stdint.h>
typedef struct { uint32_t slot, reserved; uint64_t generation; } NihStoreHandle;
int nih_store_open(uint32_t kind, NihStoreHandle *out);
int nih_store_read(const NihStoreHandle *, uint64_t offset, void *data, uint32_t bytes, uint32_t *actual);
int nih_store_write(const NihStoreHandle *, uint64_t offset, const void *data, uint32_t bytes);
int nih_store_resize(const NihStoreHandle *, uint64_t length);
int nih_store_size(const NihStoreHandle *, uint64_t *length);
int nih_store_sync(const NihStoreHandle *);
void nih_store_cutpoint(uint32_t kind);
int nih_store_vfs_selftest(void);
int nih_sqlite_store_run(const char *command);
#endif
