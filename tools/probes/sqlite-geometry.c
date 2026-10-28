#include "sqlite3.h"
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
static void ok(sqlite3 *db,int rc){if(rc!=SQLITE_OK&&rc!=SQLITE_DONE){fprintf(stderr,"sqlite %d: %s\n",rc,sqlite3_errmsg(db));exit(1);}}
static void sql(sqlite3 *db,const char *s){ok(db,sqlite3_exec(db,s,0,0,0));}
int main(int argc,char **argv){
 if(argc!=5)return 2;
 int page=atoi(argv[2]),batch=atoi(argv[3]),random=atoi(argv[4]);
 if((page!=4096&&page!=8192&&page!=16384)||(batch!=1&&batch!=32)||(random!=0&&random!=1))return 2;
 struct stat existing;
 if(stat(argv[1],&existing)==0){fprintf(stderr,"probe requires a new database path\n");return 2;}
 sqlite3 *db=0;ok(db,sqlite3_open(argv[1],&db));char config[512];
 snprintf(config,sizeof(config),"PRAGMA page_size=%d;PRAGMA locking_mode=EXCLUSIVE;PRAGMA journal_mode=WAL;PRAGMA synchronous=FULL;PRAGMA wal_autocheckpoint=0;PRAGMA cache_size=-512;PRAGMA mmap_size=0;CREATE TABLE t(id INTEGER PRIMARY KEY,v INTEGER,p BLOB);",page);
 sql(db,config);
 sql(db,"BEGIN;WITH RECURSIVE x(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM x WHERE i<8192) INSERT INTO t SELECT i,0,zeroblob(256) FROM x;COMMIT;");
 int log,ckpt;ok(db,sqlite3_wal_checkpoint_v2(db,0,SQLITE_CHECKPOINT_TRUNCATE,&log,&ckpt));
 sqlite3_int64 now,peak;sqlite3_status64(SQLITE_STATUS_MEMORY_USED,&now,&peak,1);
 sqlite3_stmt *st=0;ok(db,sqlite3_prepare_v2(db,"UPDATE t SET v=v+1 WHERE id=?",-1,&st,0));
 unsigned state=12345;
 for(int i=0;i<512;i++){
  if(i%batch==0)sql(db,"BEGIN IMMEDIATE");
  state=state*1664525u+1013904223u;
  int id=random?(int)((state>>8)%8192)+1:i+1;
  ok(db,sqlite3_bind_int(st,1,id));ok(db,sqlite3_step(st));ok(db,sqlite3_reset(st));
  if((i+1)%batch==0)sql(db,"COMMIT");
 }
 sqlite3_status64(SQLITE_STATUS_MEMORY_USED,&now,&peak,0);
 int cache,unused;ok(db,sqlite3_db_status(db,SQLITE_DBSTATUS_CACHE_USED,&cache,&unused,0));
 char wal[4096];snprintf(wal,sizeof(wal),"%s-wal",argv[1]);struct stat s;if(stat(wal,&s))return 3;
 long long walbytes=s.st_size;
 ok(db,sqlite3_wal_checkpoint_v2(db,0,SQLITE_CHECKPOINT_PASSIVE,&log,&ckpt));
 printf("{\"sqlite\":\"%s\",\"page\":%d,\"batch\":%d,\"pattern\":\"%s\",\"operations\":512,\"commits\":%d,\"wal_bytes\":%lld,\"wal_frames\":%d,\"checkpointed\":%d,\"cache_bytes\":%d,\"sqlite_peak_bytes\":%lld}\n",sqlite3_libversion(),page,batch,random?"random":"adjacent",512/batch,walbytes,log,ckpt,cache,(long long)peak);
 ok(db,sqlite3_finalize(st));ok(db,sqlite3_close(db));return 0;
}
