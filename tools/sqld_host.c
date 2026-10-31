/* Host media/scheduling adapter. Opens an exclusive regular image only. */
#define _POSIX_C_SOURCE 200809L
#define _DARWIN_C_SOURCE
#define _DEFAULT_SOURCE
#include "nihos_sqld.h"
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#include <pthread.h>

struct host { int fd;void *store,*service;pthread_t thread; };
static int read_media(void *raw,uint64_t offset,uint8_t *out,size_t length) {
 struct host *h=raw;
 while (length) { ssize_t n=pread(h->fd,out,length,(off_t)offset);if (n<0 && errno==EINTR) continue;if (n<=0) return -1;out+=n;offset+=(uint64_t)n;length-=(size_t)n; }
 return 0;
}
static int write_media(void *raw,uint64_t offset,const uint8_t *data,size_t length) {
 struct host *h=raw;
 while (length) { ssize_t n=pwrite(h->fd,data,length,(off_t)offset);if (n<0 && errno==EINTR) continue;if (n<=0) return -1;data+=n;offset+=(uint64_t)n;length-=(size_t)n; }
 return 0;
}
static int sync_media(void *raw) { return fsync(((struct host *)raw)->fd); }
static uint32_t identity(void *raw) { return pthread_equal(((struct host *)raw)->thread,pthread_self()) ? 1 : 2; }
static int random_bytes(void *raw,uint8_t *out,int n) { (void)raw;arc4random_buf(out,(size_t)n);return n; }
static int64_t time_ms(void *raw) { (void)raw;struct timespec t;if (clock_gettime(CLOCK_REALTIME,&t)) return 0;return INT64_C(210866760000000)+(int64_t)t.tv_sec*1000+t.tv_nsec/1000000; }
static int sleep_us(void *raw,int us) { (void)raw;struct timespec t={us/1000000,(us%1000000)*1000};while (nanosleep(&t,&t) && errno==EINTR) {}return us; }
static int64_t monotonic_ms(void *raw) { (void)raw;struct timespec t;if (clock_gettime(CLOCK_MONOTONIC,&t)) return INT64_MAX;return (int64_t)t.tv_sec*1000+t.tv_nsec/1000000; }
void *nih_sqld_host_open(const char *path,int create) {
 struct host *h=calloc(1,sizeof(*h));if (!h) return NULL;h->fd=-1;h->thread=pthread_self();
 int flags=O_RDWR|O_NOFOLLOW|O_CLOEXEC;
 if (create) flags|=O_CREAT|O_EXCL;
 h->fd=open(path,flags,0600);
 struct stat st;
 if (h->fd<0 || flock(h->fd,LOCK_EX|LOCK_NB) || fstat(h->fd,&st) || !S_ISREG(st.st_mode)) goto failed;
 if (create) {
  uint8_t erased[4096];memset(erased,255,sizeof(erased));
  for (uint64_t offset=0;offset<NIH_STORE_BYTES;offset+=sizeof(erased)) if (write_media(h,offset,erased,sizeof(erased))) goto failed;
  if (sync_media(h)) goto failed;
 } else if (st.st_size!=NIH_STORE_BYTES) goto failed;
 size_t align=nih_store_alignment();if (align<sizeof(void *)) align=sizeof(void *);
 if (posix_memalign(&h->store,align,nih_store_size())) goto failed;
 align=nih_sqld_alignment();if (align<sizeof(void *)) align=sizeof(void *);
 if (posix_memalign(&h->service,align,nih_sqld_size())) goto failed;
 struct nih_store_device media={h,read_media,write_media,sync_media};
 if (nih_store_mount(h->store,nih_store_size(),&media,create)) goto failed;
 struct nih_sqld_platform platform={h,identity,random_bytes,time_ms,sleep_us,monotonic_ms};
 if (nih_sqld_start(h->service,nih_sqld_size(),h->store,&platform,7,1)) goto failed;
 return h;
failed:
 if (h->fd>=0) close(h->fd);
 free(h->store);free(h->service);free(h);return NULL;
}
int nih_sqld_host_call(void *raw,struct nih_sqld_request *q,struct nih_sqld_response *r) {
 struct host *h=raw;return nih_sqld_call(h->service,7,q,r);
}
int32_t nih_sqld_host_xy(void *raw,uint32_t op,uint32_t handle,uint32_t offset,uint32_t count,
 const uint8_t *text,uint32_t length,const uint8_t *argument,uint32_t argument_length,uint8_t *out,uint32_t capacity) {
 if (length>=NIH_SQLD_TEXT || argument_length>=64 || capacity<NIH_SQLD_RESULT) return NIH_SQLD_LIMIT;
 struct nih_sqld_request q={.operation=op,.handle=handle,.offset=offset,.count=count,.length=length};
 struct nih_sqld_response r={0};
 memcpy(q.text,text,length);memcpy(q.argument,argument,argument_length);
 int rc=nih_sqld_host_call(raw,&q,&r);
 if (rc) return r.outcome==2 ? NIH_SQLD_UNKNOWN : rc;
 memcpy(out,r.text,r.length);return (int32_t)r.length;
}
void *nih_sqld_host_service(void *raw) { return ((struct host *)raw)->service; }
int nih_sqld_host_close(void *raw) {
 struct host *h=raw;int rc=nih_sqld_stop(h->service);
 if (rc) return rc;
 close(h->fd);free(h->store);free(h->service);free(h);return 0;
}
#ifdef NIH_SQLD_HOST_MAIN
int main(int argc,char **argv) {
 if (argc!=3 || (strcmp(argv[1],"--create") && strcmp(argv[1],"--serve"))) {
  fprintf(stderr,"usage: sqld-host --create NEW_IMAGE | --serve IMAGE\n");return 2;
 }
 void *h=nih_sqld_host_open(argv[2],!strcmp(argv[1],"--create"));
 if (!h) { fprintf(stderr,"Cannot acquire/mount store; existing data is never reformatted\n");return 1; }
 char line[2048];
 while (fgets(line,sizeof(line),stdin)) {
  struct nih_sqld_request q={0};struct nih_sqld_response r={0};int start=0;
  if (!strchr(line,'\n') && !feof(stdin)) { fprintf(stderr,"request too long\n");return 2; }
  if (sscanf(line,"%u %u %u %u %n",&q.operation,&q.handle,&q.offset,&q.count,&start)!=4 || !start) { puts("error -22");fflush(stdout);continue; }
  size_t n=strcspn(line+start,"\r\n");
  if (n>=sizeof(q.text)) { puts("error -7");fflush(stdout);continue; }
  memcpy(q.text,line+start,n);q.length=(uint32_t)n;
  int rc=nih_sqld_host_call(h,&q,&r);
  printf("%d %d %u %s\n",rc,r.sqlite_code,r.outcome,r.text);fflush(stdout);
 }
 return nih_sqld_host_close(h) ? 1 : 0;
}
#endif
