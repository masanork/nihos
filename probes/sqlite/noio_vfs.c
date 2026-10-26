/* Host-only no-I/O fixture, not a persistent or production VFS. */
#include "sqlite3.h"
#include <string.h>
static int deny_open(sqlite3_vfs *v, const char *name, sqlite3_file *file, int flags, int *out) {
    (void)v; (void)name; (void)file; (void)flags; (void)out;
    return SQLITE_CANTOPEN;
}
static int deny_path(sqlite3_vfs *v, const char *name, int n, char *out) {
    (void)v; (void)name; (void)n; (void)out; return SQLITE_CANTOPEN;
}
static int no_random(sqlite3_vfs *v, int n, char *out) {
    (void)v; memset(out, 0x5a, (size_t)n); return n;
}
static int no_sleep(sqlite3_vfs *v, int n) { (void)v; return n; }
static int fixed_time(sqlite3_vfs *v, double *time) { (void)v; *time = 2440587.5; return SQLITE_OK; }
static sqlite3_vfs noio = {
    .iVersion = 1, .szOsFile = sizeof(sqlite3_file), .mxPathname = 64,
    .zName = "nihos-host-noio", .xOpen = deny_open, .xFullPathname = deny_path,
    .xRandomness = no_random, .xSleep = no_sleep, .xCurrentTime = fixed_time
};
int sqlite3_os_init(void) { return sqlite3_vfs_register(&noio, 1); }
int sqlite3_os_end(void) { return SQLITE_OK; }
