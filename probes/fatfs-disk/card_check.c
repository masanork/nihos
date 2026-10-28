#define _POSIX_C_SOURCE 200809L
#define _FILE_OFFSET_BITS 64
#include "nihos_fatfs_card.h"
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/stat.h>
#include <string.h>
static int image;
static unsigned calls,fail_at;
static nih_fatfs_card *busy_card;
static uint32_t busy_generation;
static unsigned busy_seen;
#define CHECK(x) do { if (!(x)) { fprintf(stderr,"card check: %s\n",#x); exit(1); } } while(0)
int32_t nih_storage_read(uint32_t lba,uint8_t bytes[512]) {
    ++calls;
    if (busy_card) {
        CHECK(nih_fatfs_card_destroy(busy_card,busy_generation)==-1);
        CHECK(nih_fatfs_card_backend(busy_card,busy_generation));
        CHECK(nih_fatfs_card_path(busy_card,busy_generation));
        CHECK(nih_fatfs_card_reads(busy_card,busy_generation)>0);
        ++busy_seen;
    }
    if (pread(image,bytes,512,(off_t)((uint64_t)lba*512))!=512) return -1;
    return calls==fail_at ? -1 : 0;
}
int main(int argc,char **argv) {
    CHECK(argc==2); image=open(argv[1],O_RDONLY);
    struct stat info; CHECK(image>=0 && !fstat(image,&info));
    uint64_t sectors=(uint64_t)info.st_size/512;
    CHECK(sectors<=UINT32_MAX);
    uint32_t size=nih_fatfs_card_bytes(); CHECK(size<=32768);
    void *workspace=malloc(size); CHECK(workspace);
    nih_fatfs_card_report report;
    for (uint32_t epoch=1;epoch<=2;++epoch) {
        CHECK(nih_fatfs_card_read(workspace,size,(uint32_t)sectors,epoch,&report)==1);
        CHECK(report.status==1 && report.destroyed==1 && report.bytes==24);
        CHECK(report.crc==0x539c1754 && report.repeated_crc==report.crc);
    }
    for (uint32_t fault=1;fault<=3;++fault) {
        calls=0; fail_at=fault;
        CHECK(nih_fatfs_card_read(workspace,size,(uint32_t)sectors,fault+2,&report)==0);
        CHECK(report.status==0);
    }
    fail_at=0;
    CHECK(nih_fatfs_card_read(workspace,size,(uint32_t)sectors,6,&report)==1);
    CHECK(report.destroyed==1 && report.crc==0x539c1754);
    nih_fatfs_card *card=NULL;
    CHECK(nih_fatfs_card_mount(workspace,size,(uint32_t)sectors,7,&card,&report)==1);
    nih_fatfs_backend *backend=nih_fatfs_card_backend(card,7);
    CHECK(backend && !strcmp(nih_fatfs_card_path(card,7),"Memo.txt"));
    CHECK(!nih_fatfs_card_backend(card,6) && !nih_fatfs_card_path(card,6));
    CHECK(nih_fatfs_card_reads(card,6)==0);
    CHECK(nih_fatfs_card_destroy(card,6)==0);
    nih_fatfs_card *sentinel=(nih_fatfs_card *)(uintptr_t)1;
    unsigned before=calls;
    CHECK(nih_fatfs_card_mount(workspace,size,(uint32_t)sectors,8,&sentinel,&report)==0);
    CHECK(sentinel==(nih_fatfs_card *)(uintptr_t)1 && calls==before);
    uint64_t identity=0,token=0;uint32_t got=0,eof=0;
    busy_card=card;busy_generation=7;
    CHECK(nih_fatfs_backend_lookup(backend,7,1,"Memo.txt",8,&identity)==0);
    CHECK(nih_fatfs_backend_open(backend,7,identity,&token)==0);
    uint8_t data[64];
    CHECK(nih_fatfs_backend_read(backend,7,token,0,data,sizeof data,&got,&eof)==0 && got==24);
    CHECK(busy_seen>0);
    busy_card=NULL;
    CHECK(nih_fatfs_backend_close(backend,7,token)==0);
    CHECK(nih_fatfs_card_destroy(card,7)==1);
    CHECK(!nih_fatfs_card_backend(card,7) && !nih_fatfs_card_path(card,7));
    CHECK(nih_fatfs_card_reads(card,7)==0);
    CHECK(nih_fatfs_card_mount(workspace,size,(uint32_t)sectors,8,&card,&report)==1);
    CHECK(nih_fatfs_card_destroy(card,7)==0 && !nih_fatfs_card_backend(card,7));
    CHECK(nih_fatfs_card_backend(card,8));
    CHECK(nih_fatfs_card_destroy(card,8)==1);
    for (uint32_t i=0;i<size;++i) CHECK(((uint8_t *)workspace)[i]==0);
    calls=0;fail_at=1;
    CHECK(nih_fatfs_card_mount(workspace,size,(uint32_t)sectors,9,&sentinel,&report)==0);
    CHECK(sentinel==(nih_fatfs_card *)(uintptr_t)1);
    calls=0;
    CHECK(nih_fatfs_card_mount(workspace,size,(uint32_t)sectors,9,(nih_fatfs_card **)workspace,&report)==0);
    CHECK(nih_fatfs_card_mount(workspace,size,(uint32_t)sectors,9,&sentinel,workspace)==0);
    CHECK(nih_fatfs_card_mount(workspace,size,(uint32_t)sectors,9,(nih_fatfs_card **)&report,&report)==0);
    CHECK(calls==0);
    free(workspace); CHECK(!close(image));
    printf("{\"passed\":true,\"successful_reads\":3,\"failed_sector_positions\":3,\"workspace_bytes\":%u,\"lifetime_checked\":true,\"busy_destroy_rejected\":%u}\n",size,busy_seen);
}
