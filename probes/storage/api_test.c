#include "nihos_storage.h"
#include "storage_internal.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static unsigned char disk[64][512];
static struct { _Alignas(64) uint8_t before[64], workspace[NIH_RO_WORKSPACE_BYTES], after[64]; } memory;
static uint32_t calls,fail_at;
static int backend(void *context,uint32_t lba,void *sector) {
    if (context!=disk || ++calls==fail_at || lba>=64) return -1;
    memcpy(sector,disk[lba],512); return 0;
}
#define CHECK(x) do { if (!(x)) { fprintf(stderr,"file API failure line=%d\n",__LINE__); return 1; } } while (0)
static int cleared(void) {
    for (unsigned i=0;i<sizeof(memory.workspace);++i) if (memory.workspace[i]) return 0;
    for (unsigned i=0;i<64;++i) if (memory.before[i]!=0xa5 || memory.after[i]!=0xa5) return 0;
    return 1;
}
int main(int argc,char **argv) {
    CHECK(argc==2);
    FILE *f=fopen(argv[1],"rb"); CHECK(f && fread(disk,1,sizeof(disk),f)==sizeof(disk)); CHECK(!fclose(f));
    memset(&memory,0xa5,sizeof(memory));
    CHECK(!nih_ro_init(memory.workspace+1,NIH_RO_WORKSPACE_BYTES-1,backend,disk));
    CHECK(!nih_ro_init(memory.workspace,1,backend,disk));
    CHECK(!nih_ro_init(memory.workspace,NIH_RO_WORKSPACE_BYTES+1,backend,disk));
    CHECK(!nih_ro_init(memory.workspace,NIH_RO_WORKSPACE_BYTES,NULL,disk));
    nih_ro *s=nih_ro_init(memory.workspace,NIH_RO_WORKSPACE_BYTES,backend,disk); CHECK(s);
    uint32_t h=0,next=0;
    uint8_t data[512]; nih_ro_info info;
    CHECK(nih_ro_open(s,7,"/hello.bin",10,&h)==NIH_RO_NODEV);
    CHECK(!nih_ro_mount(s,64)); CHECK(nih_ro_mount(s,64)==NIH_RO_BUSY);
    CHECK(!nih_ro_stat(s,"/hello.bin",10,&info) && info.type==1 && info.size==1300);
    const char *invalid[]={"hello.bin","//hello.bin","/../hello.bin","/./hello.bin","/hello.bin/","/dir//file"};
    uint32_t before=calls;
    for (unsigned i=0;i<sizeof(invalid)/sizeof(invalid[0]);++i)
        CHECK(nih_ro_open(s,7,invalid[i],(uint32_t)strlen(invalid[i]),&h)==NIH_RO_INVAL);
    CHECK(nih_ro_open(s,0,"/hello.bin",10,&h)==NIH_RO_INVAL);
    CHECK(nih_ro_open(s,7,"/a\0b",4,&h)==NIH_RO_INVAL);
    CHECK(nih_ro_open(s,7,"/hello.bin",256,&h)==NIH_RO_INVAL);
    CHECK(calls==before);
    CHECK(nih_ro_stat(s,"/missing",8,&info)==LFS_ERR_NOENT);
    CHECK(!nih_ro_open(s,7,"/hello.bin",10,&h) && h);
    CHECK(nih_ro_open(s,8,"/hello.bin",10,&next)==NIH_RO_BUSY);
    CHECK(nih_ro_unmount(s)==NIH_RO_BUSY);
    before=calls;
    CHECK(nih_ro_read_at(s,8,h,0,data,1)==NIH_RO_OWNER);
    CHECK(nih_ro_close(s,8,h)==NIH_RO_OWNER);
    CHECK(nih_ro_read_at(s,7,h,0,data,513)==NIH_RO_INVAL);
    CHECK(nih_ro_read_at(s,7,h,0,NULL,1)==NIH_RO_INVAL);
    CHECK(nih_ro_read_at(s,7,h,UINT32_MAX,data,1)==NIH_RO_INVAL);
    CHECK(!nih_ro_read_at(s,7,h,0,NULL,0)); CHECK(calls==before);
    CHECK(nih_ro_read_at(s,7,h,500,data,32)==32);
    for (unsigned i=0;i<32;++i) CHECK(data[i]==(uint8_t)((500u+i)*17u+3u));
    CHECK(nih_ro_read_at(s,7,h,1200,data,512)==100);
    CHECK(!nih_ro_read_at(s,7,h,1300,data,1));
    CHECK(nih_ro_read_at(s,7,h,1301,data,1)==NIH_RO_INVAL);
    CHECK(!nih_ro_release_owner(s,8)); CHECK(nih_ro_read_at(s,7,h,0,data,1)==1);
    CHECK(!nih_ro_release_owner(s,7)); CHECK(nih_ro_read_at(s,7,h,0,data,1)==NIH_RO_BADF);
    CHECK(!nih_ro_open(s,7,"/hello.bin",10,&next) && next!=h);
    CHECK(nih_ro_close(s,7,h)==NIH_RO_BADF); CHECK(!nih_ro_close(s,7,next));
    CHECK(!nih_ro_unmount(s)); CHECK(!nih_ro_mount(s,64));
    s->next_handle=UINT32_MAX;
    CHECK(!nih_ro_open(s,7,"/hello.bin",10,&h) && h==UINT32_MAX);
    CHECK(!nih_ro_close(s,7,h)); before=calls;
    CHECK(nih_ro_open(s,7,"/hello.bin",10,&h)==NIH_RO_LIMIT && calls==before);
    CHECK(!nih_ro_destroy(s) && cleared());
    s=nih_ro_init(memory.workspace,NIH_RO_WORKSPACE_BYTES,backend,disk); CHECK(s && !nih_ro_mount(s,64));
    CHECK(!nih_ro_open(s,7,"/hello.bin",10,&h));
    fail_at=calls+1;
    CHECK(nih_ro_read_at(s,7,h,1024,data,1)==NIH_RO_IO);
    before=calls; CHECK(nih_ro_read_at(s,7,h,0,data,1)==NIH_RO_IO && calls==before);
    CHECK(!nih_ro_release_owner(s,7)); CHECK(!nih_ro_destroy(s) && cleared());
    fail_at=0;
    s=nih_ro_init(memory.workspace,NIH_RO_WORKSPACE_BYTES,backend,disk); CHECK(s && !nih_ro_mount(s,64));
    CHECK(!nih_ro_open(s,7,"/hello.bin",10,&h));
    s->max_reads=s->reads;
    CHECK(nih_ro_read_at(s,7,h,1024,data,1)==NIH_RO_IO);
    CHECK(!nih_ro_destroy(s) && cleared());
    puts("read-only file API PASS: canonical paths, ownership, bounds, random offsets, EOF, cancellation, stale/wrapping handles, IO poison/budget, workspace cleanup");
    return 0;
}
