#define _POSIX_C_SOURCE 200809L
#define _FILE_OFFSET_BITS 64
#include "nihos_fatfs_card.h"
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/stat.h>
static int image;
static unsigned calls,fail_at;
#define CHECK(x) do { if (!(x)) { fprintf(stderr,"card check: %s\n",#x); exit(1); } } while(0)
int32_t nih_storage_read(uint32_t lba,uint8_t bytes[512]) {
    ++calls;
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
    free(workspace); CHECK(!close(image));
    printf("{\"passed\":true,\"successful_reads\":3,\"failed_sector_positions\":3,\"workspace_bytes\":%u}\n",size);
}
