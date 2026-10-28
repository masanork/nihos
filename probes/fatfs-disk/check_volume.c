#include "nihos_fatfs_volume.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static unsigned checks, cases, calls, fail_at;
static uint32_t lbas[5];
static uint8_t blocks[5][512];
static uint8_t scratch[512];
static nih_fatfs_volume output;
#define CHECK(x) do { ++checks; if (!(x)) { fprintf(stderr,"%s:%d: %s\n",__FILE__,__LINE__,#x); exit(1); } } while (0)
static void put16(uint8_t *p, uint32_t n) { p[0] = (uint8_t)n; p[1] = (uint8_t)(n >> 8); }
static void put32(uint8_t *p, uint32_t n) { put16(p,n); put16(p+2,n >> 16); }
static void put64(uint8_t *p, uint64_t n) { put32(p,(uint32_t)n); put32(p+4,(uint32_t)(n >> 32)); }
static void sig(uint8_t *p) { p[510] = 0x55; p[511] = 0xaa; }
static void fat12(uint8_t *p) {
    memset(p,0,512); sig(p); p[0] = 0xeb; p[2] = 0x90;
    put16(p+11,512); p[13] = 1; put16(p+14,1); p[16] = 1;
    put16(p+17,16); put16(p+19,2048); put16(p+22,8);
    memcpy(p+54,"FAT12   ",8);
}
static void exfat(uint8_t *p) {
    memset(p,0,512); sig(p); memcpy(p,"\xeb\x76\x90" "EXFAT   ",11);
    put64(p+72,2048); put32(p+80,24); put32(p+84,9); put32(p+88,33);
    put32(p+92,1024); put32(p+96,2); put16(p+104,0x100);
    p[108] = 9; p[109] = 0; p[110] = 1;
}
static void reset(void) {
    memset(blocks,0,sizeof blocks); memset(lbas,0,sizeof lbas);
    calls = fail_at = 0;
}
static void part(unsigned slot, uint8_t type, uint32_t first, uint32_t count) {
    uint8_t *p = blocks[0]+446+slot*16;
    sig(blocks[0]); memset(p,0,16); p[4] = type; put32(p+8,first); put32(p+12,count);
    lbas[slot+1] = first;
}
static int read_sector(void *context, uint32_t lba, uint8_t bytes[512]) {
    CHECK(context == &calls);
    ++calls;
    if (calls == fail_at) { memset(bytes,0xde,512); return -1; }
    for (unsigned i=0;i<5;++i) if (lbas[i]==lba) { memcpy(bytes,blocks[i],512); return 0; }
    CHECK(0); return -1; /* A malformed interval must never issue an unchecked read. */
}
static void expect(nih_volume_status status, uint64_t device, uint32_t selection, unsigned reads) {
    memset(scratch,0xa5,sizeof scratch); memset(&output,0x5a,sizeof output);
    nih_fatfs_volume before = output;
    CHECK(nih_fatfs_volume_probe(read_sector,&calls,device,selection,scratch,&output)==status);
    CHECK(calls==reads && calls<=5);
    if (status==NIH_VOLUME_OK) CHECK(output.reads==reads);
    else CHECK(!memcmp(&output,&before,sizeof output));
    if (status!=NIH_VOLUME_INVALID) for (unsigned i=0;i<512;++i) CHECK(scratch[i]==0);
    ++cases;
}
int main(void) {
    reset(); fat12(blocks[0]); expect(NIH_VOLUME_OK,4096,NIH_VOLUME_AUTO,1);
    CHECK(output.first==0 && output.count==2048 && output.container_count==4096 && output.kind==NIH_VOLUME_FAT12);
    reset(); fat12(blocks[0]); expect(NIH_VOLUME_OK,4096,NIH_VOLUME_WHOLE,1);
    reset(); fat12(blocks[0]); memset(blocks[0]+54,0,8); expect(NIH_VOLUME_OK,4096,0,1);
    reset(); fat12(blocks[0]); put16(blocks[0]+19,0); put32(blocks[0]+32,65536);
    blocks[0][13]=4; put16(blocks[0]+22,64);
    expect(NIH_VOLUME_OK,65536,0,1); CHECK(output.kind==NIH_VOLUME_FAT16);
    reset(); fat12(blocks[0]); put16(blocks[0]+19,0); put32(blocks[0]+32,100000);
    put16(blocks[0]+17,0); put16(blocks[0]+14,32); put16(blocks[0]+22,0);
    put32(blocks[0]+36,800); put32(blocks[0]+44,2); memcpy(blocks[0]+82,"FAT32   ",8);
    expect(NIH_VOLUME_OK,100000,0,1); CHECK(output.kind==NIH_VOLUME_FAT32);
    blocks[0][82]=0; calls=0; expect(NIH_VOLUME_CORRUPT,100000,0,1);
    blocks[0][82]='F'; put32(blocks[0]+44,100001); calls=0;
    expect(NIH_VOLUME_CORRUPT,100000,0,1);
    reset(); exfat(blocks[0]); expect(NIH_VOLUME_OK,2048,0,1); CHECK(output.kind==NIH_VOLUME_EXFAT);
    reset(); exfat(blocks[0]); put64(blocks[0]+64,UINT64_MAX);
    expect(NIH_VOLUME_OK,2048,0,1); CHECK(output.first==0); /* Metadata cannot redirect physical I/O. */
    reset(); part(2,0x07,100,3000); exfat(blocks[3]); expect(NIH_VOLUME_OK,4096,0,2);
    CHECK(output.first==100 && output.count==2048 && output.container_count==3000 && output.partition==3);
    reset(); part(0,0x01,100,3000); fat12(blocks[1]); expect(NIH_VOLUME_OK,4096,1,2);
    calls=0; expect(NIH_VOLUME_NOT_FOUND,4096,2,1);
    calls=0; expect(NIH_VOLUME_NOT_FOUND,4096,NIH_VOLUME_WHOLE,1);
    reset(); part(0,0x01,100,3000); fat12(blocks[1]); part(1,0x01,4000,3000); fat12(blocks[2]);
    expect(NIH_VOLUME_AMBIGUOUS,8192,0,3);
    calls=0; expect(NIH_VOLUME_OK,8192,2,2); CHECK(output.first==4000);
    reset(); part(0,0x01,100,3000); fat12(blocks[1]); part(1,0x83,2000,3000);
    expect(NIH_VOLUME_CORRUPT,8192,1,1); /* Even an unselected Linux overlap is invalid. */
    reset(); part(0,0x01,100,3000); fat12(blocks[1]); part(3,0x83,8000,1000);
    expect(NIH_VOLUME_CORRUPT,8192,1,1); /* Validate the final entry before reading slot 1. */
    reset(); part(0,0x01,0,2048); expect(NIH_VOLUME_CORRUPT,8192,0,1);
    reset(); part(0,0x01,100,0); expect(NIH_VOLUME_CORRUPT,8192,0,1);
    reset(); part(0,0x01,100,2048); blocks[0][446]=1; expect(NIH_VOLUME_CORRUPT,8192,0,1);
    reset(); sig(blocks[0]); blocks[0][446+8]=1; expect(NIH_VOLUME_CORRUPT,8192,0,1);
    for (unsigned i=0;i<4;++i) {
        reset(); part(i,0xee,1,4095); expect(NIH_VOLUME_UNSUPPORTED,4096,0,1);
    }
    const uint8_t extended[]={0x05,0x0f,0x85};
    for (unsigned i=0;i<3;++i) {
        reset(); part(0,extended[i],1,4095); expect(NIH_VOLUME_UNSUPPORTED,4096,1,1);
    }
    reset(); part(0,0x83,1,4095); expect(NIH_VOLUME_UNSUPPORTED,4096,1,1);
    calls=0; expect(NIH_VOLUME_NOT_FOUND,4096,0,1);
    reset(); part(0,0x07,100,2048); part(1,0x01,3000,2048); fat12(blocks[2]);
    blocks[1][0]=0xeb; memcpy(blocks[1]+3,"NTFS    ",8); put16(blocks[1]+11,512);
    blocks[1][13]=8; sig(blocks[1]); expect(NIH_VOLUME_OK,8192,0,3);
    CHECK(output.first==3000 && output.partition==2);
    reset(); expect(NIH_VOLUME_NOT_FOUND,4096,0,1);
    reset(); fat12(blocks[0]); blocks[0][510]=0; expect(NIH_VOLUME_CORRUPT,4096,0,1);
    reset(); fat12(blocks[0]); expect(NIH_VOLUME_CORRUPT,1024,0,1);
    reset(); fat12(blocks[0]); blocks[0][13]=3; expect(NIH_VOLUME_CORRUPT,4096,0,1);
    reset(); fat12(blocks[0]); put16(blocks[0]+22,1); expect(NIH_VOLUME_CORRUPT,4096,0,1);
    reset(); exfat(blocks[0]); blocks[0][109]=255; expect(NIH_VOLUME_UNSUPPORTED,4096,0,1);
    reset(); exfat(blocks[0]); blocks[0][108]=255; expect(NIH_VOLUME_UNSUPPORTED,4096,0,1);
    reset(); exfat(blocks[0]); blocks[0][110]=2; expect(NIH_VOLUME_UNSUPPORTED,4096,0,1);
    reset(); exfat(blocks[0]); blocks[0][11]=1; expect(NIH_VOLUME_CORRUPT,4096,0,1);
    reset(); exfat(blocks[0]); put64(blocks[0]+72,UINT64_MAX); expect(NIH_VOLUME_CORRUPT,4096,0,1);
    reset(); exfat(blocks[0]); put32(blocks[0]+84,1); expect(NIH_VOLUME_CORRUPT,4096,0,1);
    reset(); exfat(blocks[0]); put32(blocks[0]+88,24); expect(NIH_VOLUME_CORRUPT,4096,0,1);
    reset(); exfat(blocks[0]); put32(blocks[0]+92,UINT32_MAX); expect(NIH_VOLUME_CORRUPT,4096,0,1);
    reset(); exfat(blocks[0]); put32(blocks[0]+96,1026); expect(NIH_VOLUME_CORRUPT,4096,0,1);
    reset(); fat12(blocks[0]); fail_at=1; expect(NIH_VOLUME_IO,4096,0,1);
    reset(); part(0,0x01,100,2048); fat12(blocks[1]); fail_at=2; expect(NIH_VOLUME_IO,4096,0,2);
    reset(); expect(NIH_VOLUME_INVALID,0,0,0);
    reset(); expect(NIH_VOLUME_INVALID,(UINT64_C(1)<<32)+1,0,0);
    reset(); expect(NIH_VOLUME_INVALID,4096,6,0);
    reset(); part(0,0x01,UINT32_MAX-1023,2048); expect(NIH_VOLUME_CORRUPT,UINT64_C(1)<<32,0,1);
    reset(); part(0,0x01,UINT32_MAX-2047,2048); fat12(blocks[1]);
    expect(NIH_VOLUME_OK,UINT64_C(1)<<32,0,2); CHECK(output.first+output.count==(UINT64_C(1)<<32));
    reset(); part(0,0x07,100,2048); part(1,0x07,3000,2048); part(2,0x07,6000,2048);
    part(3,0x01,9000,2048); fat12(blocks[4]); expect(NIH_VOLUME_OK,12000,0,5);
    reset();
    CHECK(nih_fatfs_volume_probe(NULL,&calls,4096,0,scratch,&output)==NIH_VOLUME_INVALID);
    CHECK(nih_fatfs_volume_probe(read_sector,&calls,4096,0,NULL,&output)==NIH_VOLUME_INVALID);
    CHECK(nih_fatfs_volume_probe(read_sector,&calls,4096,0,scratch,NULL)==NIH_VOLUME_INVALID);
    union { nih_fatfs_volume volume; uint8_t bytes[512]; } aliased;
    CHECK(nih_fatfs_volume_probe(read_sector,&calls,4096,0,aliased.bytes,&aliased.volume)==NIH_VOLUME_INVALID);
    CHECK(calls==0);
    printf("{\"cases\":%u,\"checks\":%u,\"maximum_reads\":5,\"scratch_bytes\":512}\n",cases,checks);
    return 0;
}
