#include "nihos_storage_probe.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static unsigned char disk[64][512];
static uint32_t calls, fail_at;
int nih_storage_read(uint32_t lba, void *sector) {
    if (++calls == fail_at || lba >= 64) return -1;
    memcpy(sector, disk[lba], 512); return 0;
}
#define CHECK(x) do { if (!(x)) { fprintf(stderr,"storage host failure line %d\n",__LINE__); return 1; } } while (0)
int main(int argc, char **argv) {
    CHECK(argc == 4);
    uint32_t logical_size=(uint32_t)strtoul(argv[3],NULL,10);
    CHECK(logical_size==512 || logical_size==4096);
    FILE *in=fopen(argv[1], "rb");
    CHECK(in && fread(disk,1,sizeof(disk),in)==sizeof(disk));
    CHECK(fclose(in)==0);
    nih_storage_report r;
    nih_storage_probe(64, &r);
    CHECK(r.status==2 && r.error_code==0 && r.passes==2 && r.block_count==64*512/logical_size && r.block_size==logical_size);
    CHECK(r.entries==3 && r.files==2 && r.directories==1 && r.file_bytes==1300);
    CHECK(r.file_crc==(uint32_t)strtoul(argv[2], NULL, 16) && r.denied_writes==0 && r.reads==calls);
    uint32_t original_calls=calls;
    fail_at=1; calls=0;
    nih_storage_probe(64, &r);
    CHECK(r.status==3 && r.error_code==5 && r.denied_writes==0);
    fail_at=original_calls-1; calls=0;
    nih_storage_probe(64, &r);
    CHECK(r.status==3 && r.passes==1 && r.error_code==5 && r.denied_writes==0);
    fail_at=0; calls=0;
    nih_storage_probe(63, &r);
    CHECK(r.status==3 && r.denied_writes==0);
    memset(disk,255,logical_size*2); calls=0;
    nih_storage_probe(64, &r);
    CHECK(r.status==3 && r.error_code==84 && r.denied_writes==0);
    puts("littlefs read-only host PASS: two mounts, multi-sector file, EOF, IO failures, capacity mismatch, corrupt metadata; no write callbacks");
    return 0;
}
