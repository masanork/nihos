/* Host-qualified managed two-object VFS. One SQLite connection, one binding.
 * No general pathname namespace, concurrent connections, WAL, mmap or DMA. */
#include "sqlite3.h"
#include "store_bridge.h"
#include <errno.h>
#include <sys/random.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

typedef struct {
    sqlite3_file base;
    NihStoreHandle handle;
    uint32_t kind;
    int lock;
} StoreFile;
static int opened[3];
static int main_opened_once;
static int kind_of(const char *name) {
    if (!name) return 0;
    if (!strcmp(name, "/main.db")) return 1;
    if (!strcmp(name, "/main.db-journal")) return 2;
    return 0;
}
static int mapped(int status, int io_error) {
    if (!status) return SQLITE_OK;
    if (status == -28) return SQLITE_FULL;
    return io_error;
}
static int close_file(sqlite3_file *file) {
    StoreFile *f = (StoreFile *)file;
    opened[f->kind] = 0;
    f->base.pMethods = 0;
    /* Grants belong to the storage binding, not a transient sqlite3_file.
     * Trusted bridge teardown cancels any remaining unsynced optimization. */
    return SQLITE_OK;
}
static int read_file(sqlite3_file *file, void *data, int amount, sqlite3_int64 offset) {
    StoreFile *f = (StoreFile *)file;
    if (amount < 0 || offset < 0) return SQLITE_IOERR_READ;
    if (amount == 0) return SQLITE_OK;
    uint32_t got = 0;
    memset(data, 0, (size_t)amount);
    int rc = nih_store_read(&f->handle, (uint64_t)offset, data, (uint32_t)amount, &got);
    if (rc) { memset(data, 0, (size_t)amount); return mapped(rc, SQLITE_IOERR_READ); }
    return got == (uint32_t)amount ? SQLITE_OK : SQLITE_IOERR_SHORT_READ;
}
static int write_file(sqlite3_file *file, const void *data, int amount, sqlite3_int64 offset) {
    StoreFile *f = (StoreFile *)file;
    if (amount < 0 || offset < 0) return SQLITE_IOERR_WRITE;
    if (amount == 0) return SQLITE_OK;
    return mapped(nih_store_write(&f->handle, (uint64_t)offset, data, (uint32_t)amount), SQLITE_IOERR_WRITE);
}
static int truncate_file(sqlite3_file *file, sqlite3_int64 length) {
    if (length < 0) return SQLITE_IOERR_TRUNCATE;
    return mapped(nih_store_resize(&((StoreFile *)file)->handle, (uint64_t)length), SQLITE_IOERR_TRUNCATE);
}
static int sync_file(sqlite3_file *file, int flags) {
    StoreFile *f = (StoreFile *)file;
    (void)flags;
    int rc = mapped(nih_store_sync(&f->handle), SQLITE_IOERR_FSYNC);
    if (rc == SQLITE_OK) nih_store_cutpoint(f->kind);
    return rc;
}
static int size_file(sqlite3_file *file, sqlite3_int64 *length) {
    uint64_t size = 0;
    int rc = mapped(nih_store_size(&((StoreFile *)file)->handle, &size), SQLITE_IOERR_FSTAT);
    if (size > INT64_MAX) return SQLITE_IOERR_FSTAT;
    *length = (sqlite3_int64)size;
    return rc;
}
static int lock_file(sqlite3_file *file, int lock) {
    StoreFile *f = (StoreFile *)file;
    if (lock < SQLITE_LOCK_SHARED || lock > SQLITE_LOCK_EXCLUSIVE) return SQLITE_IOERR_LOCK;
    if (lock > f->lock) f->lock = lock;
    return SQLITE_OK;
}
static int unlock_file(sqlite3_file *file, int lock) {
    StoreFile *f = (StoreFile *)file;
    if (lock != SQLITE_LOCK_SHARED && lock != SQLITE_LOCK_NONE) return SQLITE_IOERR_UNLOCK;
    if (lock < f->lock) f->lock = lock;
    return SQLITE_OK;
}
static int reserved_file(sqlite3_file *file, int *reserved) {
    *reserved = ((StoreFile *)file)->lock >= SQLITE_LOCK_RESERVED;
    return SQLITE_OK;
}
static int control_file(sqlite3_file *file, int op, void *arg) {
    (void)file; (void)op; (void)arg;
    return SQLITE_NOTFOUND;
}
static int sector_file(sqlite3_file *file) { (void)file; return 512; }
static int characteristics_file(sqlite3_file *file) { (void)file; return 0; }
static const sqlite3_io_methods methods = {
    .iVersion = 1, .xClose = close_file, .xRead = read_file, .xWrite = write_file,
    .xTruncate = truncate_file, .xSync = sync_file, .xFileSize = size_file,
    .xLock = lock_file, .xUnlock = unlock_file, .xCheckReservedLock = reserved_file,
    .xFileControl = control_file, .xSectorSize = sector_file, .xDeviceCharacteristics = characteristics_file
};
static int open_file(sqlite3_vfs *v, const char *name, sqlite3_file *file, int flags, int *out) {
    (void)v;
    StoreFile *f = (StoreFile *)file;
    memset(f, 0, sizeof(*f));
    int kind = kind_of(name);
    if (!kind || opened[kind] || !(flags & SQLITE_OPEN_READWRITE) ||
        (kind == 1 && (main_opened_once || !(flags & SQLITE_OPEN_MAIN_DB))) ||
        (kind == 2 && !(flags & SQLITE_OPEN_MAIN_JOURNAL))) return SQLITE_CANTOPEN;
    if (nih_store_open((uint32_t)kind, &f->handle)) return SQLITE_CANTOPEN;
    f->kind = (uint32_t)kind;
    f->base.pMethods = &methods;
    opened[kind] = 1;
    if (kind == 1) main_opened_once = 1;
    if (out) *out = SQLITE_OPEN_READWRITE;
    return SQLITE_OK;
}
static int delete_file(sqlite3_vfs *v, const char *name, int sync_dir) {
    (void)v; (void)sync_dir;
    if (kind_of(name) != 2 || opened[2]) return SQLITE_IOERR_DELETE;
    NihStoreHandle handle;
    if (nih_store_open(2, &handle)) return SQLITE_IOERR_DELETE;
    int rc = mapped(nih_store_resize(&handle, 0), SQLITE_IOERR_DELETE);
    if (rc == SQLITE_OK) rc = mapped(nih_store_sync(&handle), SQLITE_IOERR_DIR_FSYNC);
    return rc;
}
static int access_file(sqlite3_vfs *v, const char *name, int flags, int *out) {
    (void)v; (void)flags;
    *out = 0;
    int kind = kind_of(name);
    if (!kind) return SQLITE_OK;
    NihStoreHandle handle; uint64_t length = 0;
    if (nih_store_open((uint32_t)kind, &handle) || nih_store_size(&handle, &length)) return SQLITE_IOERR_ACCESS;
    *out = kind == 1 || length != 0;
    return SQLITE_OK;
}
static int full_path(sqlite3_vfs *v, const char *name, int bytes, char *out) {
    (void)v;
    if (!kind_of(name) || bytes < 0 || strlen(name) + 1 > (size_t)bytes) return SQLITE_CANTOPEN;
    memcpy(out, name, strlen(name) + 1);
    return SQLITE_OK;
}
static int randomness(sqlite3_vfs *v, int amount, char *out) {
    (void)v; int got = 0;
    while (got < amount) { int n = amount - got; if (n > 256) n = 256; if (getentropy(out + got, (size_t)n)) break; got += n; }
    return got;
}
static int sleep_us(sqlite3_vfs *v, int us) {
    (void)v; if (us <= 0) return 0;
    struct timespec t = { .tv_sec = us / 1000000, .tv_nsec = (long)(us % 1000000) * 1000 };
    while (nanosleep(&t, &t) && errno == EINTR) {}
    return us;
}
static int current_time(sqlite3_vfs *v, double *out) {
    (void)v; struct timespec t;
    if (clock_gettime(CLOCK_REALTIME, &t)) return SQLITE_ERROR;
    *out = 2440587.5 + ((double)t.tv_sec + (double)t.tv_nsec / 1e9) / 86400.0;
    return SQLITE_OK;
}
static sqlite3_vfs vfs = {
    .iVersion = 1, .szOsFile = sizeof(StoreFile), .mxPathname = 64, .zName = "nihos-store-host",
    .xOpen = open_file, .xDelete = delete_file, .xAccess = access_file, .xFullPathname = full_path,
    .xRandomness = randomness, .xSleep = sleep_us, .xCurrentTime = current_time
};
int sqlite3_os_init(void) { return sqlite3_vfs_register(&vfs, 1); }
int sqlite3_os_end(void) { return SQLITE_OK; }
int nih_store_vfs_selftest(void) {
    StoreFile f, duplicate;
    memset(&f, 0, sizeof(f));
    if (open_file(&vfs, "/escape", &f.base, SQLITE_OPEN_READWRITE | SQLITE_OPEN_MAIN_DB, 0) != SQLITE_CANTOPEN || f.base.pMethods) return 1;
    if (nih_store_open(1, &f.handle)) return 2;
    unsigned char bytes[23]; memset(bytes, 0xee, sizeof(bytes));
    if (read_file(&f.base, bytes, 23, INT64_C(0x100000000)) != SQLITE_IOERR_SHORT_READ) return 3;
    for (unsigned i = 0; i < sizeof(bytes); ++i) if (bytes[i]) return 4;
    memset(&duplicate, 0, sizeof(duplicate));
    if (open_file(&vfs, "/main.db", &duplicate.base, SQLITE_OPEN_READWRITE | SQLITE_OPEN_MAIN_DB, 0) != SQLITE_CANTOPEN || duplicate.base.pMethods) return 5;
    uint64_t before = 0, after = 0;
    if (nih_store_size(&f.handle, &before)) return 6;
    if (write_file(&f.base, 0, 0, INT64_C(0x100000000)) != SQLITE_OK ||
        read_file(&f.base, 0, 0, INT64_C(0x100000000)) != SQLITE_OK) return 7;
    if (nih_store_size(&f.handle, &after) || before != after) return 8;
    if (read_file(&f.base, 0, -1, 0) != SQLITE_IOERR_READ ||
        write_file(&f.base, 0, -1, 0) != SQLITE_IOERR_WRITE ||
        truncate_file(&f.base, -1) != SQLITE_IOERR_TRUNCATE) return 9;
    return 0;
}
