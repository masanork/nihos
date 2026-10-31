/* SQLite rollback-journal VFS over the caller-owned checkpoint store. */
#include "sqld_internal.h"
#include <string.h>

static int code(int rc, int io) {
 if (!rc) return SQLITE_OK;
 if (rc==NIH_STORE_FULL) return SQLITE_FULL;
 return io;
}
static uint32_t key(const char *path) {
 if (!path) return 0;
 if (!strcmp(path,"main.db")) return 1;
 if (!strcmp(path,"main.db-journal")) return 2;
 return 0;
}
static int close_file(sqlite3_file *raw) {
 struct nih_sql_file *f=(void *)raw;
 f->owner->files[f->key-1]=NULL;
 f->base.pMethods=NULL;
 return SQLITE_OK;
}
static int read_file(sqlite3_file *raw, void *out, int length, sqlite3_int64 offset) {
 struct nih_sql_file *f=(void *)raw;
 if (offset<0 || length<0 || offset>INT64_MAX-length) return SQLITE_IOERR_READ;
 memset(out,0,(size_t)length);
 uint64_t size=0;if (nih_store_stat(f->owner->store,f->key,&size)) return SQLITE_IOERR_READ;
 int wanted=length;
 if ((uint64_t)offset>=size) return length ? SQLITE_IOERR_SHORT_READ : SQLITE_OK;
 if ((uint64_t)length>size-(uint64_t)offset) wanted=(int)(size-(uint64_t)offset);
 int done=0;
 while (done<wanted) {
  int n=wanted-done; if (n>4096) n=4096;
  int rc=nih_store_read(f->owner->store,f->key,(uint64_t)offset+(unsigned)done,(uint8_t *)out+done,(size_t)n);
  if (rc<0) return SQLITE_IOERR_READ;
  done+=rc;
  if (rc<n) return SQLITE_IOERR_SHORT_READ;
 }
 return wanted==length ? SQLITE_OK : SQLITE_IOERR_SHORT_READ;
}
static int write_file(sqlite3_file *raw, const void *data, int length, sqlite3_int64 offset) {
 struct nih_sql_file *f=(void *)raw;
 if (!(f->flags&SQLITE_OPEN_READWRITE)) return SQLITE_READONLY;
 if (offset<0 || length<0 || offset>INT64_MAX-length) return SQLITE_IOERR_WRITE;
 int done=0;
 while (done<length) {
  int n=length-done; if (n>4096) n=4096;
  int rc=nih_store_write(f->owner->store,f->key,(uint64_t)offset+(unsigned)done,(const uint8_t *)data+done,(size_t)n);
  if (rc) return code(rc,SQLITE_IOERR_WRITE);
  done+=n;
 }
 return SQLITE_OK;
}
static int truncate_file(sqlite3_file *raw, sqlite3_int64 size) {
 struct nih_sql_file *f=(void *)raw;
 if (!(f->flags&SQLITE_OPEN_READWRITE)) return SQLITE_READONLY;
 if (size<0) return SQLITE_IOERR_TRUNCATE;
 return code(nih_store_resize(f->owner->store,f->key,(uint64_t)size),SQLITE_IOERR_TRUNCATE);
}
static int sync_file(sqlite3_file *raw, int flags) {
 (void)flags; /* The store always supplies the stronger complete-root barrier. */
 return code(nih_store_sync(((struct nih_sql_file *)raw)->owner->store),SQLITE_IOERR_FSYNC);
}
static int size_file(sqlite3_file *raw, sqlite3_int64 *out) {
 struct nih_sql_file *f=(void *)raw; uint64_t size=0;
 int rc=nih_store_stat(f->owner->store,f->key,&size);
 if (rc || size>INT64_MAX) return SQLITE_IOERR_FSTAT;
 *out=(sqlite3_int64)size; return SQLITE_OK;
}
static int lock_file(sqlite3_file *raw, int level) {
 struct nih_sql_file *f=(void *)raw;
 if (!nih_sqld_is_owner(f->owner) || level<SQLITE_LOCK_SHARED || level>SQLITE_LOCK_EXCLUSIVE) return SQLITE_IOERR_LOCK;
 /* Admission permits exactly one handle per fixed file and one connection,
  * under an exclusive media lease. No second/external writer is admitted. */
 if (level>f->lock) f->lock=level;
 return SQLITE_OK;
}
static int unlock_file(sqlite3_file *raw, int level) {
 struct nih_sql_file *f=(void *)raw;
 if (level!=SQLITE_LOCK_NONE && level!=SQLITE_LOCK_SHARED) return SQLITE_IOERR_UNLOCK;
 if (level>f->lock) return SQLITE_IOERR_UNLOCK;
 f->lock=level; return SQLITE_OK;
}
static int reserved(sqlite3_file *raw,int *out) { *out=((struct nih_sql_file *)raw)->lock>=SQLITE_LOCK_RESERVED; return SQLITE_OK; }
static int control(sqlite3_file *f,int op,void *arg) { (void)f;(void)op;(void)arg;return SQLITE_NOTFOUND; }
static int sector(sqlite3_file *f) { (void)f;return 4096; }
static int characteristics(sqlite3_file *f) { (void)f;return 0; }
static const sqlite3_io_methods methods={.iVersion=1,.xClose=close_file,.xRead=read_file,.xWrite=write_file,
 .xTruncate=truncate_file,.xSync=sync_file,.xFileSize=size_file,.xLock=lock_file,.xUnlock=unlock_file,
 .xCheckReservedLock=reserved,.xFileControl=control,.xSectorSize=sector,.xDeviceCharacteristics=characteristics};
static int open_file(sqlite3_vfs *vfs,sqlite3_filename path,sqlite3_file *raw,int flags,int *actual) {
 struct nih_sqld *s=vfs->pAppData; struct nih_sql_file *f=(void *)raw;
 memset(f,0,sizeof(*f)); uint32_t k=key(path);
 const int allowed=SQLITE_OPEN_READONLY|SQLITE_OPEN_READWRITE|SQLITE_OPEN_CREATE|SQLITE_OPEN_MAIN_DB|SQLITE_OPEN_MAIN_JOURNAL;
 if (!nih_sqld_is_owner(s) || !k || (flags&~allowed) || s->files[k-1]) return SQLITE_CANTOPEN;
 if (!(flags&(SQLITE_OPEN_READONLY|SQLITE_OPEN_READWRITE)) || ((flags&SQLITE_OPEN_READONLY)&&(flags&SQLITE_OPEN_READWRITE))) return SQLITE_CANTOPEN;
 uint64_t size=0; int rc=nih_store_stat(s->store,k,&size);
 if (rc==NIH_STORE_NOT_FOUND && (flags&SQLITE_OPEN_CREATE) && (flags&SQLITE_OPEN_READWRITE)) {
  rc=nih_store_create(s->store,k);
  if (!rc) rc=nih_store_sync(s->store);
 }
 if (rc) return code(rc,SQLITE_CANTOPEN);
 f->owner=s;f->key=k;f->flags=flags;f->base.pMethods=&methods;s->files[k-1]=f;
 if (actual) *actual=flags;
 return SQLITE_OK;
}
static int delete_file(sqlite3_vfs *vfs,const char *path,int syncdir) {
 struct nih_sqld *s=vfs->pAppData;uint32_t k=key(path);(void)syncdir;
 if (!k || s->files[k-1]) return SQLITE_IOERR_DELETE;
 int rc=nih_store_remove(s->store,k);
 if (rc==NIH_STORE_NOT_FOUND) return SQLITE_OK;
 if (!rc) rc=nih_store_sync(s->store);
 return code(rc,SQLITE_IOERR_DELETE);
}
static int access_file(sqlite3_vfs *vfs,const char *path,int flags,int *out) {
 struct nih_sqld *s=vfs->pAppData;uint32_t k=key(path);uint64_t n=0;(void)flags;
 *out=0;if (!k) return SQLITE_OK;
 int rc=nih_store_stat(s->store,k,&n);
 if (rc==NIH_STORE_NOT_FOUND) return SQLITE_OK;
 if (rc) return SQLITE_IOERR_ACCESS;
 *out=1;return SQLITE_OK;
}
static int fullpath(sqlite3_vfs *vfs,const char *path,int capacity,char *out) {
 (void)vfs;if (!key(path) || capacity<1 || strlen(path)>=(size_t)capacity) return SQLITE_CANTOPEN;
 memcpy(out,path,strlen(path)+1);return SQLITE_OK;
}
static int random_bytes(sqlite3_vfs *vfs,int n,char *out) { struct nih_sqld *s=vfs->pAppData;return s->platform.random(s->platform.context,(uint8_t *)out,n); }
static int sleep_us(sqlite3_vfs *vfs,int us) { struct nih_sqld *s=vfs->pAppData;return s->platform.sleep_us(s->platform.context,us); }
static int time_ms(sqlite3_vfs *vfs,sqlite3_int64 *out) { struct nih_sqld *s=vfs->pAppData;*out=s->platform.time_ms(s->platform.context);return *out>0 ? SQLITE_OK : SQLITE_IOERR; }
static int time_days(sqlite3_vfs *vfs,double *out) { sqlite3_int64 t=0;int rc=time_ms(vfs,&t);*out=(double)t/86400000.0;return rc; }
int nih_sqld_vfs_init(struct nih_sqld *s) {
 s->vfs=(sqlite3_vfs){.iVersion=2,.szOsFile=sizeof(struct nih_sql_file),.mxPathname=32,.zName="nihos-checkpoint",.pAppData=s,
 .xOpen=open_file,.xDelete=delete_file,.xAccess=access_file,.xFullPathname=fullpath,.xRandomness=random_bytes,
 .xSleep=sleep_us,.xCurrentTime=time_days,.xCurrentTimeInt64=time_ms};
 return sqlite3_vfs_register(&s->vfs,0);
}
void nih_sqld_vfs_done(struct nih_sqld *s) { sqlite3_vfs_unregister(&s->vfs); }
