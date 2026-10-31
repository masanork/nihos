/* Bounded single-owner service. The platform schedules step(), never an IRQ. */
#include "sqld_internal.h"
#include <limits.h>
#include <string.h>

static _Atomic(struct nih_sqld *) registered;
int nih_sqld_is_owner(struct nih_sqld *s) { return s && s->platform.identity(s->platform.context)==s->owner; }
size_t nih_sqld_size(void) { return sizeof(struct nih_sqld); }
size_t nih_sqld_alignment(void) { return _Alignof(struct nih_sqld); }
static int progress(void *raw) {
 struct nih_sqld *s=raw;
 return ++s->ticks>1024 ||
  (s->transaction_deadline && s->platform.monotonic_ms(s->platform.context)>=s->transaction_deadline) ||
  atomic_load_explicit(&s->cancelled,memory_order_acquire)==s->next_sequence;
}
static int authorize(void *ctx,int action,const char *a,const char *b,const char *db,const char *trigger) {
 (void)ctx;(void)a;(void)b;(void)db;(void)trigger;
 if (action==SQLITE_ATTACH || action==SQLITE_DETACH || action==SQLITE_PRAGMA || action==SQLITE_TRANSACTION || action==SQLITE_SAVEPOINT) return SQLITE_DENY;
 return SQLITE_OK;
}
static int open_db(struct nih_sqld *s) {
 int rc=sqlite3_open_v2("main.db",&s->db,SQLITE_OPEN_READWRITE|SQLITE_OPEN_CREATE,"nihos-checkpoint");
 if (rc!=SQLITE_OK) return rc;
 sqlite3_limit(s->db,SQLITE_LIMIT_LENGTH,4096);
 sqlite3_limit(s->db,SQLITE_LIMIT_SQL_LENGTH,NIH_SQLD_TEXT-1);
 sqlite3_limit(s->db,SQLITE_LIMIT_COLUMN,8);
 sqlite3_limit(s->db,SQLITE_LIMIT_EXPR_DEPTH,16);
 sqlite3_limit(s->db,SQLITE_LIMIT_ATTACHED,0);
 sqlite3_limit(s->db,SQLITE_LIMIT_VARIABLE_NUMBER,16);
 rc=sqlite3_db_config(s->db,SQLITE_DBCONFIG_DEFENSIVE,1,NULL);
 if (rc==SQLITE_OK) rc=sqlite3_db_config(s->db,SQLITE_DBCONFIG_TRUSTED_SCHEMA,0,NULL);
 if (rc!=SQLITE_OK) return rc;
 rc=sqlite3_exec(s->db,"PRAGMA page_size=4096;PRAGMA journal_mode=PERSIST;PRAGMA synchronous=FULL;PRAGMA temp_store=MEMORY;PRAGMA mmap_size=0;PRAGMA cache_size=-64",NULL,NULL,NULL);
 if (rc==SQLITE_OK) {
  sqlite3_stmt *check=NULL;
  rc=sqlite3_prepare_v2(s->db,"PRAGMA journal_mode",-1,&check,NULL);
  if (rc==SQLITE_OK) {
   if (sqlite3_step(check)!=SQLITE_ROW) rc=SQLITE_ERROR;
   else { const unsigned char *mode=sqlite3_column_text(check,0);if (!mode || strcmp((const char *)mode,"persist")) rc=SQLITE_ERROR; }
  }
  sqlite3_finalize(check);
 }
 if (rc==SQLITE_OK) rc=sqlite3_set_authorizer(s->db,authorize,s);
 if (rc==SQLITE_OK) sqlite3_progress_handler(s->db,100,progress,s);
 return rc;
}
int nih_sqld_start(void *raw,size_t bytes,void *store,const struct nih_sqld_platform *p,uint32_t principal,uint32_t epoch) {
 if (!raw || (uintptr_t)raw%_Alignof(struct nih_sqld) || bytes<sizeof(struct nih_sqld) || !store || !p || !p->identity || !p->random || !p->time_ms || !p->sleep_us || !p->monotonic_ms || !principal || !epoch || p->transaction_timeout_ms>60000 || (p->transaction_timeout_ms && p->transaction_timeout_ms<1000)) return NIH_STORE_INVALID;
 uint32_t owner=p->identity(p->context);if (!owner) return NIH_SQLD_DENIED;
 struct nih_sqld *expected=NULL;
 if (!atomic_compare_exchange_strong(&registered,&expected,(struct nih_sqld *)raw)) return NIH_STORE_BUSY;
 struct nih_sqld *s=raw;memset(s,0,sizeof(*s));
 s->store=store;s->platform=*p;s->owner=owner;s->principal=principal;s->epoch=epoch;
 atomic_init(&s->request_head,0);atomic_init(&s->request_tail,0);
 atomic_init(&s->response_head,0);atomic_init(&s->response_tail,0);atomic_init(&s->cancelled,0);
 atomic_init(&s->serial,0);atomic_init(&s->completed_serial,0);atomic_init(&s->dead,0);
 s->previous_heap_limit=sqlite3_hard_heap_limit64(2*1024*1024);
 int rc=nih_sqld_vfs_init(s);
 if (rc==SQLITE_OK) rc=open_db(s);
 if (rc!=SQLITE_OK) { if (s->db) sqlite3_close(s->db);s->db=NULL;nih_sqld_vfs_done(s);sqlite3_hard_heap_limit64(s->previous_heap_limit);atomic_store(&registered,NULL);s->dead=1;return -5; }
 return 0;
}
int nih_sqld_submit(void *raw,uint32_t principal,const struct nih_sqld_request *q) {
 struct nih_sqld *s=raw;
 if (!q || principal!=s->principal) return NIH_SQLD_DENIED;
 if (s->dead) return NIH_SQLD_UNKNOWN;
 if (q->epoch!=s->epoch || q->sequence==0 || q->sequence>INT32_MAX || q->sequence<=s->serial) return NIH_SQLD_STALE;
 if (q->length>=NIH_SQLD_TEXT || q->text[q->length]!=0 ||
     (q->operation!=NIH_FILE_WRITE && memchr(q->text,0,q->length)) || !memchr(q->argument,0,sizeof(q->argument))) return NIH_SQLD_LIMIT;
 uint32_t head=atomic_load_explicit(&s->request_head,memory_order_relaxed);
 uint32_t tail=atomic_load_explicit(&s->request_tail,memory_order_acquire);
 if (head-tail==NIH_SQLD_QUEUE) return NIH_STORE_BUSY;
 s->requests[head%NIH_SQLD_QUEUE]=*q;s->serial=q->sequence;
 atomic_store_explicit(&s->request_head,head+1,memory_order_release);return 0;
}
int nih_sqld_take(void *raw,uint32_t principal,struct nih_sqld_response *out) {
 struct nih_sqld *s=raw;if (principal!=s->principal || !out) return NIH_SQLD_DENIED;
 uint32_t tail=atomic_load_explicit(&s->response_tail,memory_order_relaxed);
 uint32_t head=atomic_load_explicit(&s->response_head,memory_order_acquire);
 if (head==tail) return 0;
 *out=s->responses[tail%NIH_SQLD_QUEUE];
 atomic_store_explicit(&s->response_tail,tail+1,memory_order_release);return 1;
}
int nih_sqld_cancel(void *raw,uint32_t principal,uint32_t epoch,uint32_t sequence) {
 struct nih_sqld *s=raw;
 if (s->dead || principal!=s->principal) return NIH_SQLD_DENIED;
 if (epoch!=s->epoch || !sequence || sequence>s->serial || sequence<=s->completed_serial) return NIH_SQLD_STALE;
 atomic_store_explicit(&s->cancelled,sequence,memory_order_release);return 0;
}
static int append(struct nih_sqld_response *r,const char *text,size_t n) {
 if (n>=sizeof(r->text)-r->length) return NIH_SQLD_LIMIT;
 memcpy(r->text+r->length,text,n);r->length+=(uint32_t)n;r->text[r->length]=0;return 0;
}
static int number(struct nih_sqld_response *r,int64_t n) {
 char text[32];size_t start=sizeof(text);
 uint64_t rest=n<0 ? (uint64_t)(-(n+1))+1 : (uint64_t)n;
 do { text[--start]=(char)('0'+rest%10);rest/=10; } while (rest);
 if (n<0) text[--start]='-';
 return append(r,text+start,sizeof(text)-start);
}
static int quoted(struct nih_sqld_response *r,const char *text,int n) {
 if (n>64 || n<0 || (n && (!text || memchr(text,0,(size_t)n)))) return NIH_SQLD_LIMIT;
 int rc=append(r,"\"",1);
 for (int i=0;!rc && i<n;i++) {
  if (text[i]=='\n') rc=append(r,"\\n",2);
  else if (text[i]=='\t') rc=append(r,"\\t",2);
  else if (text[i]=='\\' || text[i]=='\"') { rc=append(r,"\\",1);if (!rc) rc=append(r,text+i,1); }
  else rc=append(r,text+i,1);
 }
 return rc ? rc : append(r,"\"",1);
}
static int query(struct nih_sqld *s,const struct nih_sqld_request *q,struct nih_sqld_response *r) {
 sqlite3_stmt *stmt=NULL;const char *tail=NULL;
 int rc=sqlite3_prepare_v2(s->db,q->text,(int)q->length,&stmt,&tail);
 if (rc!=SQLITE_OK) { r->sqlite_code=rc;return NIH_SQLD_ERROR; }
 if (!stmt) return NIH_SQLD_LIMIT;
 while (tail && (*tail==' '||*tail=='\n'||*tail=='\r'||*tail=='\t')) tail++;
 int status=0;
 if (!tail || *tail || sqlite3_bind_parameter_count(stmt) ||
    (q->operation==NIH_SQL_QUERY && !sqlite3_stmt_readonly(stmt)) ||
    (q->operation==NIH_SQL_EXEC && sqlite3_column_count(stmt))) status=NIH_SQLD_DENIED;
 if (!status && q->operation==NIH_SQL_QUERY) status=append(r,"(",1);
 unsigned rows=0;
 while (!status && (rc=sqlite3_step(stmt))==SQLITE_ROW) {
  if (++rows>8 || sqlite3_column_count(stmt)>4) { status=NIH_SQLD_LIMIT;break; }
  if (rows>1) status=append(r," ",1);
  if (!status) status=append(r,"(",1);
  for (int c=0;!status && c<sqlite3_column_count(stmt);c++) {
   if (c) status=append(r," ",1);
   if (status) break;
   int type=sqlite3_column_type(stmt,c);
   if (type==SQLITE_NULL) status=append(r,"#f",2);
   else if (type==SQLITE_INTEGER) {
    sqlite3_int64 n=sqlite3_column_int64(stmt,c);
    status=(n<INT32_MIN || n>INT32_MAX) ? NIH_SQLD_LIMIT : number(r,n);
   } else if (type==SQLITE_TEXT) status=quoted(r,(const char *)sqlite3_column_text(stmt,c),sqlite3_column_bytes(stmt,c));
   else status=NIH_SQLD_LIMIT;
  }
  if (!status) status=append(r,")",1);
 }
 int final=sqlite3_finalize(stmt);
 if (!status && rc!=SQLITE_DONE) { status=NIH_SQLD_ERROR;r->sqlite_code=rc; }
 if (!status && final!=SQLITE_OK) { status=NIH_SQLD_ERROR;r->sqlite_code=final; }
 if (!status) status=q->operation==NIH_SQL_QUERY ? append(r,")",1) : number(r,sqlite3_changes(s->db));
 if (!status && q->operation==NIH_SQL_EXEC && sqlite3_get_autocommit(s->db)) r->outcome=1;
 return status;
}
/* Names live in one transactional namespace object; keys 1/2 belong to SQLite.
 * No client can address raw DB/journal keys. Paths are single relative names. */
#define FILES 16
struct entry { char name[48]; };
static int namespace_read(struct nih_sqld *s,struct entry entries[FILES]) {
 memset(entries,0,sizeof(struct entry)*FILES);uint64_t size=0;
 int rc=nih_store_stat(s->store,3,&size);
 if (rc==NIH_STORE_NOT_FOUND) return 0;
 if (rc || size!=sizeof(struct entry)*FILES) return -5;
 rc=nih_store_read(s->store,3,0,(uint8_t *)entries,sizeof(struct entry)*FILES);
 if (rc!=(int)(sizeof(struct entry)*FILES)) return -5;
 for (int i=0;i<FILES;i++) if (!memchr(entries[i].name,0,sizeof(entries[i].name))) return -84;
 return 0;
}
static int namespace_write(struct nih_sqld *s,const struct entry entries[FILES]) {
 uint64_t size=0;int rc=nih_store_stat(s->store,3,&size);
 if (rc==NIH_STORE_NOT_FOUND) rc=nih_store_create(s->store,3);
 if (rc) return rc;
 return nih_store_write(s->store,3,0,(const uint8_t *)entries,sizeof(struct entry)*FILES);
}
static int file_key(struct nih_sqld *s,uint32_t handle,uint32_t *key_out) {
 for (unsigned i=0;i<16;i++) if (s->handles[i]==handle && handle) { *key_out=s->keys[i];return 0; }
 return NIH_SQLD_STALE;
}
static int file_request(struct nih_sqld *s,const struct nih_sqld_request *q,struct nih_sqld_response *r) {
 uint32_t key_out=0;
 if (q->operation==NIH_FILE_OPEN || q->operation==NIH_FILE_LIST) {
  unsigned free_handle=16;
  if (q->operation==NIH_FILE_OPEN) {
   if (s->handle_serial==INT32_MAX) return NIH_STORE_FULL;
   for (unsigned i=0;i<16;i++) if (!s->handles[i]) { free_handle=i;break; }
   if (free_handle==16) return NIH_STORE_FULL;
  }
  struct entry entries[FILES];int rc=namespace_read(s,entries);if (rc) return rc;
  if (q->operation==NIH_FILE_LIST) {
   rc=append(r,"(",1);int count=0;
   for (int i=0;!rc && i<FILES;i++) if (entries[i].name[0]) {
    if (count++) rc=append(r," ",1);
    if (!rc) rc=quoted(r,entries[i].name,(int)strlen(entries[i].name));
   }
   return rc ? rc : append(r,")",1);
  }
  if (!q->length || q->length>=sizeof(entries[0].name) || strchr(q->text,'/') || strchr(q->text,'\\') || !strcmp(q->text,".") || !strcmp(q->text,"..")) return NIH_STORE_INVALID;
  int index=-1,empty=-1;
  for (int i=0;i<FILES;i++) { if (!strcmp(entries[i].name,q->text)) index=i;if (!entries[i].name[0] && empty<0) empty=i; }
  if (index<0) {
   if (!q->offset) return NIH_STORE_NOT_FOUND;
   if (empty<0) return NIH_STORE_FULL;
   index=empty;strcpy(entries[index].name,q->text);
   s->mutation_attempted=1;
   rc=nih_store_create(s->store,(uint32_t)index+32);
   if (!rc) rc=namespace_write(s,entries);
   if (rc) { nih_store_rollback(s->store);return rc; }
   s->fs_dirty=1;
  }
  /* Separate handle sequence: request serial is never used as a capability. */
  s->handles[free_handle]=++s->handle_serial;s->keys[free_handle]=(uint32_t)index+32;
  return number(r,s->handles[free_handle]);
 }
 if ((q->operation>=NIH_FILE_READ && q->operation<=NIH_FILE_REMOVE) || q->operation==NIH_FILE_CLOSE || q->operation==NIH_FILE_STAT || q->operation==NIH_FILE_VERIFY) {
  int rc=file_key(s,q->handle,&key_out);if (rc) return rc;
 }
 switch (q->operation) {
 case NIH_FILE_READ: {
  if (q->count>64) return NIH_SQLD_LIMIT;
  uint8_t data[64];int n=nih_store_read(s->store,key_out,q->offset,data,q->count);if (n<0) return n;
  int rc=append(r,"(",1);
  for (int i=0;!rc && i<n;i++) { if (i) rc=append(r," ",1);if (!rc) rc=number(r,data[i]); }
  return rc ? rc : append(r,")",1);
 }
 case NIH_FILE_WRITE: { s->mutation_attempted=1;int rc=nih_store_write(s->store,key_out,q->offset,(const uint8_t *)q->text,q->length);if (!rc) s->fs_dirty=1;return rc ? rc : number(r,q->length); }
 case NIH_FILE_RESIZE: { s->mutation_attempted=1;int rc=nih_store_resize(s->store,key_out,q->offset);if (!rc) s->fs_dirty=1;return rc; }
 case NIH_FILE_REMOVE: {
  struct entry entries[FILES];int rc=namespace_read(s,entries);if (rc) return rc;
  memset(&entries[key_out-32],0,sizeof(entries[0]));
  s->mutation_attempted=1;
  rc=nih_store_remove(s->store,key_out);if (!rc) rc=namespace_write(s,entries);
  if (!rc) { s->fs_dirty=1;for (unsigned i=0;i<16;i++) if (s->keys[i]==key_out) s->handles[i]=0; }
  return rc;
 }
 case NIH_FILE_SYNC: { int rc=nih_store_sync(s->store);if (!rc) { s->fs_dirty=0;r->outcome=1; }return rc; }
 case NIH_FILE_CLOSE: { for (unsigned i=0;i<16;i++) if (s->handles[i]==q->handle) s->handles[i]=0;return 0; }
 case NIH_FILE_STAT: { uint64_t n=0;int rc=nih_store_stat(s->store,key_out,&n);return rc ? rc : number(r,(int64_t)n); }
 case NIH_FILE_VERIFY: return s->fs_dirty ? NIH_STORE_BUSY : nih_store_verify(s->store,key_out);
 case NIH_FS_SPACE: {
  struct nih_store_space space;int rc=nih_store_space(s->store,&space);if (rc) return rc;
  rc=append(r,"(",1);
  const uint64_t values[]={space.capacity,space.free_bytes,space.largest_run,space.index_free_bytes};
  for (unsigned i=0;!rc && i<4;i++) { if (i) rc=append(r," ",1);if (!rc) rc=number(r,(int64_t)values[i]); }
  return rc ? rc : append(r,")",1);
 }
 case NIH_FILE_BEGIN: { if (s->fs_dirty) return NIH_STORE_BUSY;s->fs_dirty=1;return 0; }
 case NIH_FILE_ROLLBACK: { int rc=nih_store_rollback(s->store);if (!rc) { s->fs_dirty=0;memset(s->handles,0,sizeof(s->handles)); }return rc; }
 case NIH_FS_SNAPSHOT: { uint32_t token=0;int rc=nih_store_snapshot(s->store,&token);return rc ? rc : number(r,token); }
 case NIH_FS_RELEASE: return nih_store_release(s->store,q->handle);
 case NIH_FS_COLLECT: { int rc=nih_store_collect(s->store);if (!rc) r->outcome=1;return rc; }
 case NIH_FS_GENERATION: { uint64_t n=nih_store_generation(s->store);return n>INT32_MAX ? NIH_SQLD_LIMIT : number(r,(int64_t)n); }
 default: return NIH_STORE_INVALID;
 }
}
static int execute(struct nih_sqld *s,const struct nih_sqld_request *q,struct nih_sqld_response *r) {
 s->next_sequence=q->sequence;s->ticks=0;
 if (s->transaction_expired) { s->transaction_expired=0;return -110; }
 if (atomic_load_explicit(&s->cancelled,memory_order_acquire)==q->sequence) { r->sqlite_code=SQLITE_INTERRUPT;return -125; }
 if (q->operation==NIH_SQL_CHECK) {
  if (s->fs_dirty) return NIH_STORE_BUSY;
  struct nih_sqld_request check={.operation=NIH_SQL_QUERY,.text="PRAGMA integrity_check"};
  check.length=(uint32_t)strlen(check.text);
  sqlite3_set_authorizer(s->db,NULL,NULL);
  int result=query(s,&check,r);
  sqlite3_set_authorizer(s->db,authorize,s);
  return result;
 }
 if (q->operation>=NIH_SQL_QUERY && q->operation<=NIH_SQL_ROLLBACK) {
  if (s->fs_dirty) return NIH_STORE_BUSY;
  if (q->operation==NIH_SQL_QUERY || q->operation==NIH_SQL_EXEC) return query(s,q,r);
  if ((q->operation==NIH_SQL_BEGIN)==!sqlite3_get_autocommit(s->db)) return NIH_STORE_BUSY;
  int64_t deadline=0;
  if (q->operation==NIH_SQL_BEGIN) {
   int64_t now=s->platform.monotonic_ms(s->platform.context);
   uint32_t lease=s->platform.transaction_timeout_ms ? s->platform.transaction_timeout_ms : 2000;
   if (now<0 || now>INT64_MAX-lease) return -110;
   deadline=now+lease;
  }
  sqlite3_set_authorizer(s->db,NULL,NULL);
  int rc=sqlite3_exec(s->db,q->operation==NIH_SQL_BEGIN ? "BEGIN IMMEDIATE" : q->operation==NIH_SQL_COMMIT ? "COMMIT" : "ROLLBACK",NULL,NULL,NULL);
  sqlite3_set_authorizer(s->db,authorize,s);
  if (rc!=SQLITE_OK) { r->sqlite_code=rc;return NIH_SQLD_ERROR; }
  if (q->operation==NIH_SQL_COMMIT) r->outcome=1;
  s->transaction_deadline=deadline;
  return 0;
 }
 if (q->operation==NIH_SQL_LOOKUP) {
  if (s->fs_dirty) return NIH_STORE_BUSY;
  if (strcmp(q->text,"notes") || q->count<1 || q->count>8) return NIH_SQLD_DENIED;
  /* Bind search text, never interpolate it into SQL. This initial typed query
   * intentionally exposes only the user's notes table. */
  sqlite3_stmt *stmt=NULL;
  int rc=sqlite3_prepare_v2(s->db,"SELECT id,body FROM notes WHERE instr(body,?1)>0 ORDER BY id LIMIT ?2",-1,&stmt,NULL);
  if (rc==SQLITE_OK) rc=sqlite3_bind_text(stmt,1,q->argument,-1,SQLITE_TRANSIENT);
  if (rc==SQLITE_OK) rc=sqlite3_bind_int(stmt,2,(int)q->count);
  /* Reuse the bounded row encoder on expanded SQL generated by SQLite itself.
   * The expansion is owned by SQLite, includes escaped values, and is capped. */
  char *expanded=rc==SQLITE_OK ? sqlite3_expanded_sql(stmt) : NULL;
  sqlite3_finalize(stmt);
  if (!expanded) { r->sqlite_code=rc==SQLITE_OK ? SQLITE_NOMEM : rc;return NIH_SQLD_ERROR; }
  struct nih_sqld_request normalized={.operation=NIH_SQL_QUERY};
  size_t n=strlen(expanded);
  int result=NIH_SQLD_LIMIT;
  if (n<sizeof(normalized.text)) { memcpy(normalized.text,expanded,n+1);normalized.length=(uint32_t)n;result=query(s,&normalized,r); }
  sqlite3_free(expanded);return result;
 }
 if (!sqlite3_get_autocommit(s->db)) return NIH_STORE_BUSY;
 if (q->operation==NIH_FS_RESTORE) {
  if (s->fs_dirty) return NIH_STORE_BUSY;
  int valid=nih_store_snapshot_valid(s->store,q->handle);if (valid) return valid;
  int rc=sqlite3_close(s->db);if (rc!=SQLITE_OK) return NIH_STORE_BUSY;s->db=NULL;
  int result=nih_store_restore(s->store,q->handle);
  memset(s->handles,0,sizeof(s->handles));
  if (open_db(s)!=SQLITE_OK) { s->dead=1;return NIH_SQLD_UNKNOWN; }
  if (!result) r->outcome=1;
  return result;
 }
 return file_request(s,q,r);
}
int nih_sqld_failed(void *raw) { return atomic_load(&((struct nih_sqld *)raw)->dead); }
int nih_sqld_step(void *raw) {
 struct nih_sqld *s=raw;if (!nih_sqld_is_owner(s)) return NIH_SQLD_DENIED;
 if (!s->dead && s->transaction_deadline && s->platform.monotonic_ms(s->platform.context)>=s->transaction_deadline) {
  sqlite3_progress_handler(s->db,0,NULL,NULL);sqlite3_set_authorizer(s->db,NULL,NULL);
  int rc=sqlite3_exec(s->db,"ROLLBACK",NULL,NULL,NULL);
  sqlite3_set_authorizer(s->db,authorize,s);sqlite3_progress_handler(s->db,100,progress,s);
  s->transaction_deadline=0;
  s->transaction_expired=1;
  if (rc!=SQLITE_OK) s->dead=1;
 }
 uint32_t head=atomic_load_explicit(&s->response_head,memory_order_relaxed);
 if (head-atomic_load_explicit(&s->response_tail,memory_order_acquire)==NIH_SQLD_QUEUE) return 0;
 uint32_t tail=atomic_load_explicit(&s->request_tail,memory_order_relaxed);
 if (tail==atomic_load_explicit(&s->request_head,memory_order_acquire)) return 0;
 const struct nih_sqld_request *q=&s->requests[tail%NIH_SQLD_QUEUE];
 struct nih_sqld_response *r=&s->responses[head%NIH_SQLD_QUEUE];memset(r,0,sizeof(*r));r->epoch=s->epoch;r->sequence=q->sequence;
 s->mutation_attempted=0;
 r->status=s->dead ? NIH_SQLD_UNKNOWN : execute(s,q,r);
 if (r->status && s->mutation_attempted) {
  int rc=nih_store_rollback(s->store);
  s->fs_dirty=0;memset(s->handles,0,sizeof(s->handles));
  if (rc) { r->status=NIH_SQLD_UNKNOWN;r->outcome=2; }
 }
 if (r->status) { r->length=0;r->text[0]=0;
  if ((r->sqlite_code&255)==SQLITE_IOERR || r->status==NIH_STORE_IO || r->status==NIH_SQLD_UNKNOWN) { r->outcome=2;s->dead=1; }
 } else if (!r->length) append(r,"#t",2);
 /* No request field may be read after publishing the reusable queue slot. */
 atomic_store_explicit(&s->completed_serial,q->sequence,memory_order_release);
 atomic_store_explicit(&s->request_tail,tail+1,memory_order_release);
 atomic_store_explicit(&s->response_head,head+1,memory_order_release);return 1;
}
int nih_sqld_call(void *raw,uint32_t principal,struct nih_sqld_request *q,struct nih_sqld_response *r) {
 struct nih_sqld *s=raw;
 if (!nih_sqld_is_owner(s)) return NIH_SQLD_DENIED;
 if (atomic_load(&s->request_head)!=atomic_load(&s->request_tail) || atomic_load(&s->response_head)!=atomic_load(&s->response_tail)) return NIH_STORE_BUSY;
 q->epoch=s->epoch;q->sequence=s->serial+1;
 int rc=nih_sqld_submit(s,principal,q);if (rc) return rc;
 rc=nih_sqld_step(s);if (rc<0) return rc;
 return nih_sqld_take(s,principal,r)==1 ? r->status : -5;
}
int nih_sqld_stop(void *raw) {
 struct nih_sqld *s=raw;if (!nih_sqld_is_owner(s)) return NIH_SQLD_DENIED;
 if (atomic_load(&s->request_head)!=atomic_load(&s->request_tail) || atomic_load(&s->response_head)!=atomic_load(&s->response_tail)) return NIH_STORE_BUSY;
 int rc=SQLITE_OK;
 if (s->db) {
  sqlite3_progress_handler(s->db,0,NULL,NULL);sqlite3_set_authorizer(s->db,NULL,NULL);
  if (!sqlite3_get_autocommit(s->db)) rc=sqlite3_exec(s->db,"ROLLBACK",NULL,NULL,NULL);
  int closed=sqlite3_close(s->db);if (closed!=SQLITE_OK) return -5;s->db=NULL;
 }
 if (s->fs_dirty) nih_store_rollback(s->store);
 nih_sqld_vfs_done(s);sqlite3_hard_heap_limit64(s->previous_heap_limit);atomic_store(&registered,NULL);s->dead=1;
 return rc==SQLITE_OK ? 0 : -5;
}
