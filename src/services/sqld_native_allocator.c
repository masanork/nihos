/* SQLite's bounded memsys5 owns this one boot-granted PSRAM arena. */
#include "sqlite3.h"
#include <stdint.h>
int sqlite3_os_init(void) { return SQLITE_OK; }
int sqlite3_os_end(void) { return SQLITE_OK; }
int nih_sqld_native_allocator(void *memory,uint32_t bytes) {
 if (!memory || ((uintptr_t)memory & 63) || bytes!=1024u*1024u) return SQLITE_MISUSE;
 int rc=sqlite3_config(SQLITE_CONFIG_HEAP,memory,(int)bytes,32);
 if (rc==SQLITE_OK) rc=sqlite3_initialize();
 return rc;
}
