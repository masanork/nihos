#define _GNU_SOURCE
#define _FILE_OFFSET_BITS 64
#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <setjmp.h>
#include "sram_pool.h"
#define CHECK(x) do { if(!(x)) { fprintf(stderr,"normal FS check line %d: %s\n",__LINE__,#x);exit(1); } } while(0)
typedef struct { uint32_t serial,generation,slot; } host_lease;
typedef struct {
    uint32_t status,generation,kind,sectors,requests,completed,bytes,crc,eof;
    int32_t error_code;
    uint32_t io_reads,yields,parent_start,parent_bytes;
    uint32_t io_error,command,interrupts,dma_status;
} report;
extern void nih_normal_fs_begin(uint32_t);
extern unsigned nih_normal_fs_submit(uint32_t,const void *,uint32_t);
extern unsigned nih_normal_fs_poll(uint32_t);
extern void nih_normal_fs_snapshot(report *);
extern unsigned nih_normal_fs_result(uint32_t,void *,uint32_t);
extern unsigned nih_fs_test_step(void);
extern unsigned nih_shared_sdmmc_acquire(unsigned,host_lease *);
extern unsigned nih_shared_sdmmc_release(const host_lease *);
extern unsigned nih_shared_sdmmc_generation(void);
extern uint32_t nih_shared_sdmmc_read(const host_lease *,uint32_t);
extern void nih_shared_sdmmc_write(const host_lease *,uint32_t,uint32_t);
static uint32_t regs[129],cccr[512];
static uint64_t micros,ticks,sectors;
static uint32_t actor=0x10000,reset_count,ui_progress,c6_transactions,reads,cache_failure,present=1,fail_read,freeze_time;
static uint32_t empty_root,corrupt_boot;
static int image;
static nih_sram_pool pool;
static uint8_t *banks[2];
uintptr_t nih_fs_test_pointer(uint32_t address) {
 if(address>=0x4ff40000 && address<0x4ff60000) return (uintptr_t)(banks[0]+address-0x4ff40000);
 CHECK(address>=0x4ff6e000 && address<0x4ff9f000); return (uintptr_t)(banks[1]+address-0x4ff6e000);
}
uint32_t nih_fs_test_address(uintptr_t address) {
 if(address>=(uintptr_t)banks[0] && address<(uintptr_t)banks[0]+128*1024) return 0x4ff40000+(uint32_t)(address-(uintptr_t)banks[0]);
 CHECK(address>=(uintptr_t)banks[1] && address<(uintptr_t)banks[1]+196*1024);return 0x4ff6e000+(uint32_t)(address-(uintptr_t)banks[1]);
}
static nih_sram_lease display;
static jmp_buf suspended;
static unsigned expect_suspend,suspended_seen;
uint64_t nih_fs_test_now(void) { return freeze_time?micros:++micros; }
unsigned nih_fs_test_mask(void) { return 8; }
void nih_fs_test_restore(unsigned previous) { CHECK(previous==8); }
_Noreturn void nih_fs_test_quarantine(void) { CHECK(expect_suspend);suspended_seen=1;longjmp(suspended,1); }
uint32_t nih_fs_test_read(uint32_t offset) {
    CHECK(offset<=0x200 && !(offset&3));
    return regs[offset/4];
}
void nih_fs_test_write(uint32_t offset,uint32_t value) {
    CHECK(offset<=0x200 && !(offset&3));
    if(offset==0x44 || offset==0x8c) { regs[offset/4]&=~value;return; }
    regs[offset/4]=value;
    if(offset==0 || offset==0x80) { regs[offset/4]=0;return; }
    if(offset!=0x2c) return;
    regs[offset/4]=0;
    if(value&(1u<<21)) return;
    uint32_t command=value&63,arg=regs[0x28/4];
    regs[0x44/4]=1u<<2;
    regs[0x30/4]=0;
    if(!present && !(value&(1u<<16)) && command!=0) { regs[0x44/4]=1u<<8;return; }
    switch(command) {
        case 3:regs[0x30/4]=1u<<16;break;
        case 5:regs[0x30/4]=0x90ff8000;break;
        case 8:regs[0x30/4]=0x1aa;break;
        case 9: {
            uint32_t n=(uint32_t)(sectors/1024-1);
            regs[0x34/4]=n<<16;regs[0x38/4]=n>>16;regs[0x3c/4]=1u<<30;break;
        }
        case 13:regs[0x30/4]=0x900;break;
        case 41:regs[0x30/4]=0xc0ff8000;break;
        case 55:regs[0x30/4]=1u<<5;break;
        case 52: {
            unsigned address=(arg>>9)&0x1ffff;CHECK(address<512);
            if(arg>>31) cccr[address]=arg&255;
            regs[0x30/4]=address==3?2:cccr[address];break;
        }
        case 17: {
            ++reads;
            if(fail_read) { regs[0x44/4]=1u<<7;return; }
            uint32_t *desc=(void *)nih_fs_test_pointer(regs[0x88/4]);
            CHECK(desc && desc[1]==512 && desc[2]);
            CHECK(pread(image,(void *)nih_fs_test_pointer(desc[2]),512,(off_t)((uint64_t)arg*512))==512);
            uint8_t *output=(void *)nih_fs_test_pointer(desc[2]);
            if(corrupt_boot && arg==0) memset(output,0,512);
            if(empty_root && arg==empty_root) {
                if(output[0]==0x81 || output[0]==0x83) {
                    for(unsigned at=0;at<512;at+=32) if(output[at]==0x85) { output[at]=0;break; }
                } else output[0]=0;
            }
            desc[0]&=~(1u<<31);
            regs[0x44/4]|=1u<<3;break;
        }
        default:break;
    }
}
void nih_sdmmc_clock_init(void) { ++reset_count;memset(regs,0,sizeof regs); }
void nih_sdmmc_power_off(void) {}
void nih_sdmmc_power_on(void) {}
int nih_rom_cache_writeback(unsigned banks,unsigned start,unsigned bytes) { (void)banks;(void)start;(void)bytes;return cache_failure?-1:0; }
int nih_rom_cache_invalidate(unsigned banks,unsigned start,unsigned bytes) { (void)banks;(void)start;(void)bytes;return cache_failure?-1:0; }
unsigned nih_normal_c6_dma_release(void) { return !cache_failure; }
bool nih_base_sram_take(unsigned owner,unsigned min,unsigned max,nih_sram_lease *out) { return nih_sram_pool_take(&pool,owner,min,max,out); }
bool nih_base_sram_release(const nih_sram_lease *lease) { return nih_sram_pool_release(&pool,lease); }
void nih_normal_fs_wake(void) {}
static void network_turn(void) {
    host_lease lease={0};
    if(nih_shared_sdmmc_acquire(1,&lease)) return;
    nih_shared_sdmmc_write(&lease,0x08,50u<<8);
    nih_shared_sdmmc_write(&lease,0x10,2);
    nih_shared_sdmmc_write(&lease,0x18,2);
    nih_shared_sdmmc_write(&lease,0x28,0);
    nih_shared_sdmmc_write(&lease,0x2c,(1u<<31)|(1u<<16)|(1u<<29)|(1u<<6)|(1u<<8)|(1u<<13)|52);
    CHECK(nih_shared_sdmmc_read(&lease,0x44)&4);
    CHECK(!nih_shared_sdmmc_release(&lease));
    ++c6_transactions;
}
uint64_t nih_riscv_task_call(uint32_t number,uint32_t argument,uint32_t payload) {
    (void)argument;(void)payload;
    if(number==0x4e490004) return actor;
    if(number==0x4e490005) return ++ticks;
    if(number==0x4e490000) { ++ui_progress;network_turn(); }
    return 0;
}
_Noreturn void nih_riscv_task_exit(int status) { (void)status;abort(); }
static void step(void) { actor=0x10001;CHECK(nih_fs_test_step());actor=0x10000; }
static report snapshot(void) { report r={0};nih_normal_fs_snapshot(&r);return r; }
static void check_display(void) {
    const uint8_t *p=(void *)nih_fs_test_pointer(display.start);
    for(unsigned i=0;i<display.bytes;++i) CHECK(p[i]==0x5a);
}
int main(int argc,char **argv) {
    CHECK(argc>=3);image=open(argv[1],O_RDONLY);CHECK(image>=0);
    struct stat info;CHECK(!fstat(image,&info));sectors=(uint64_t)info.st_size/512;
    CHECK(sectors>=1024 && sectors<=UINT32_MAX);
    CHECK(!posix_memalign((void **)&banks[0],64,128*1024));
    CHECK(!posix_memalign((void **)&banks[1],64,196*1024));
    nih_sram_region regions[2]={{0x4ff40000,128*1024},{0x4ff6e000,196*1024}};
    CHECK(nih_sram_pool_init(&pool,regions));
    CHECK(nih_sram_pool_take(&pool,1,128*1024,128*1024,&display));
    memset((void *)nih_fs_test_pointer(display.start),0x5a,display.bytes);
    if(!strcmp(argv[2],"no-card")) present=0;
    if(argc==4) empty_root=(uint32_t)strtoul(argv[3],NULL,0);
    if(!strcmp(argv[2],"corrupt")) corrupt_boot=1;
    if(!strcmp(argv[2],"no-memory")) {
        nih_sram_lease busy={0};CHECK(nih_sram_pool_take(&pool,3,196*1024,196*1024,&busy));
        nih_normal_fs_begin(0x10000);report r=snapshot();CHECK(r.status==5);
        CHECK(!nih_normal_fs_submit(0x10000,"Memo.txt",8));network_turn();
        CHECK(c6_transactions && reset_count==1);check_display();CHECK(!close(image));
        puts("{\"passed\":true,\"mode\":\"no-memory\",\"c6_transactions\":1}");return 0;
    }
    nih_normal_fs_begin(0x10000);step();report r=snapshot();check_display();
    if(corrupt_boot) {
        CHECK(r.status==4 && !r.bytes);network_turn();CHECK(c6_transactions);
        CHECK(!nih_normal_fs_submit(0x10000,"Memo.txt",8));
        corrupt_boot=0;CHECK(nih_normal_fs_submit(0x10000,"",0));step();
        CHECK(nih_normal_fs_poll(0x10000));r=snapshot();CHECK(r.status==2);
    }
    CHECK(r.parent_bytes==65536);
    if(!present) {
        CHECK(r.status==3);network_turn();CHECK(c6_transactions && ui_progress);
        CHECK(nih_normal_fs_submit(0x10000,"Memo.txt",8)==0);
    } else {
        CHECK(r.status==2);
        actor=0x10002;CHECK(!nih_normal_fs_submit(0x10000,"Memo.txt",8));actor=0x10000;
        if(!strcmp(argv[2],"generation")) {
            host_lease lease={0};CHECK(!nih_shared_sdmmc_acquire(1,&lease));
            uint32_t previous=nih_shared_sdmmc_generation();
            nih_shared_sdmmc_write(&lease,0,7);CHECK(nih_shared_sdmmc_release(&lease)==1);
            CHECK(previous!=nih_shared_sdmmc_generation());
            CHECK(!nih_normal_fs_submit(0x10000,"Memo.txt",8));step();CHECK(snapshot().status==2);
        }
        CHECK(nih_normal_fs_submit(0x10000,"Memo.txt",8));
        CHECK(!nih_normal_fs_submit(0x10000,"Memo.txt",8)); // Queue consumed != client completed.
        if(!strcmp(argv[2],"io-error")) fail_read=1;
        if(!strcmp(argv[2],"removed")) present=0;
        if(!strcmp(argv[2],"quarantine")) {
            cache_failure=1;expect_suspend=1;
            if(!setjmp(suspended)) step();
            CHECK(suspended_seen);actor=0x10000;
            CHECK(snapshot().status==6);host_lease lease={0};CHECK(nih_shared_sdmmc_acquire(1,&lease)==2);CHECK(nih_shared_sdmmc_acquire(0,&lease)==2);
            nih_sram_lease denied={0};CHECK(!nih_sram_pool_take(&pool,3,196*1024,196*1024,&denied));
        } else {
            step();CHECK(nih_normal_fs_poll(0x10000));CHECK(!nih_normal_fs_poll(0x10000));r=snapshot();
            uint8_t data[128]={0};unsigned length=nih_normal_fs_result(0,data,sizeof data);
            if(fail_read || empty_root || !present) CHECK(r.error_code!=0 && r.bytes==0 && length==0);
            else CHECK(r.error_code==0 && r.bytes==24 && r.crc==0x539c1754 && length==24 && !memcmp(data,"nihos read-only fixture\n",24));
            if(fail_read) CHECK(r.status==4);
            if(!present) CHECK(r.status==3);
            if(fail_read || !present) {
                fail_read=0;present=1;CHECK(nih_normal_fs_submit(0x10000,"",0));step();
                CHECK(nih_normal_fs_poll(0x10000) && snapshot().status==2);
                CHECK(nih_normal_fs_submit(0x10000,"Memo.txt",8));step();
                CHECK(nih_normal_fs_poll(0x10000));CHECK(snapshot().bytes==24);
            }
            CHECK(ui_progress && c6_transactions);
            CHECK(reset_count==(!strcmp(argv[2],"generation")?2u:1u));
        }
    }
    check_display();printf("{\"passed\":true,\"mode\":\"%s\",\"reads\":%u,\"ui_progress\":%u,\"c6_transactions\":%u,\"resets\":%u,\"quarantined\":%u}\n",argv[2],reads,ui_progress,c6_transactions,reset_count,suspended_seen);
    CHECK(!close(image));return 0;
}
