#define _POSIX_C_SOURCE 200809L
#define _FILE_OFFSET_BITS 64
#include "nihos_fatfs_backend.h"
#include "nihos_fatfs_volume.h"
#include "nihos_fatfs_card.h"
#include "safety.h"
#include <fcntl.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static unsigned checks;
#define CHECK(x) do { ++checks; if (!(x)) { fprintf(stderr,"%s:%d: %s\n",__FILE__,__LINE__,#x); exit(1); } } while (0)
static nih_fatfs_disk local_disk;
static nih_fatfs_disk *disk = &local_disk;
static nih_fatfs_backend *session;
static void *workspace;
static nih_fatfs_card *card_context;
static uint64_t epoch = 1, patch_offset, device_total, volume_first, volume_count;
static uint8_t patch[512];
static size_t patch_size;
static uint32_t calls, fail_at;
static uint32_t rpc_kind, rpc_event;
static int image;
extern int nih_rpc_prepare(uint32_t,uint32_t,uintptr_t *,uintptr_t *);
extern int nih_check_rpc(void);
extern int nih_rpc_finish(void);
extern void nih_rpc_event(uint32_t);
extern uint32_t nih_rpc_metric(uint32_t);
extern int32_t nih_rpc_linked_read(uint32_t);
void host_rpc_arm(uint32_t kind) { rpc_event = kind; }
uint32_t host_rpc_kind(void) { return rpc_kind; }
int32_t nih_storage_read(uint32_t lba, uint8_t sector[512]) {
    ++calls;
    if (pread(image, sector, 512, (off_t)((uint64_t)lba * 512)) != 512) return -1;
    uint64_t offset = (uint64_t)lba * 512;
    uint64_t begin = offset > patch_offset ? offset : patch_offset;
    uint64_t end = offset + 512 < patch_offset + patch_size ? offset + 512 : patch_offset + patch_size;
    if (patch_size && begin < end) memcpy(sector + (begin - offset), patch + (begin - patch_offset), (size_t)(end - begin));
    if (rpc_event) {
        uint32_t event = rpc_event; rpc_event = 0;
        if (event==7 || event==8) return nih_rpc_linked_read(event);
        nih_rpc_event(event);
        if (event==4) return NIH_STORAGE_READ_CANCELLED;
        if (event==5) return NIH_STORAGE_READ_REMOVED;
    }
    return calls == fail_at ? -1 : 0;
}
void host_test_failure(const char *name) { fprintf(stderr,"Zig VFS integration: %s\n",name); }
void *host_backend_session(void) { return session; }
uint64_t host_backend_epoch(void) { return epoch; }
uint32_t host_backend_reads(void) { return calls; }
int host_backend_destroy(void) {
    if (!card_context) return nih_fatfs_backend_destroy(session,epoch);
    if (nih_fatfs_card_destroy(card_context,(uint32_t)epoch)!=1) return -1;
    card_context=NULL;
    return 0;
}
void host_backend_fail_after(uint32_t count) { fail_at = calls + count; }
int host_backend_remove(void) { return nih_fatfs_backend_remove(session, epoch); }
int host_card_remove(void) { return nih_fatfs_card_remove(card_context,(uint32_t)epoch); }
int host_backend_disk_remove(void) { return nih_fatfs_disk_invalidate(disk, epoch); }
int host_backend_rebind(void) {
    if (nih_fatfs_backend_destroy(session,epoch)) return -1;
    ++epoch;
    fail_at = 0;
    if (nih_fatfs_disk_bind(disk,nih_fatfs_native_read,NULL,device_total,volume_first,volume_count,epoch)) return -1;
    session = nih_fatfs_backend_init(workspace,nih_fatfs_backend_bytes(),disk,epoch);
    return session ? nih_fatfs_backend_mount(session,epoch) : -1;
}
extern int nih_check_vfs(void);

static uint64_t lookup(const char *name) {
    uint64_t id = UINT64_MAX;
    CHECK(nih_fatfs_backend_lookup(session,epoch,1,name,(uint32_t)strlen(name),&id) == NIH_FB_OK);
    return id;
}
static uint64_t opened(const char *name) {
    uint64_t id = lookup(name), token = 0;
    uint32_t before = calls;
    CHECK(nih_fatfs_backend_open(session,epoch,id,&token) == NIH_FB_OK && token);
    CHECK(calls == before); /* Consume the guarded FIL; never reopen by name. */
    return token;
}
static int cancel_after_three(void *context) { return ((nih_ro_control *)context)->steps >= 3; }
static void text(const char *name, const char *expected) {
    uint64_t token = opened(name);
    char data[128] = {0};
    uint32_t got = 0, eof = 0;
    CHECK(nih_fatfs_backend_read(session,epoch,token,0,data,sizeof data,&got,&eof) == NIH_FB_OK);
    CHECK(got == strlen(expected) && eof == 1 && !memcmp(data,expected,got));
    CHECK(nih_fatfs_backend_close(session,epoch,token) == NIH_FB_OK);
}
static void normal(const char *alias) {
    uint64_t a = lookup("empty-a.txt"), b = lookup("empty-b.txt"), again = lookup("EMPTY-A.TXT");
    CHECK(a != b && a == again);
    a = lookup("Long filename for alias.txt");
    b = lookup(alias);
    CHECK(a == b);
    a = lookup("Long empty filename.txt");
    CHECK(a == lookup("LONG EMPTY FILENAME.TXT"));
    CHECK(lookup("Memo.txt") != lookup("教材/Memo.txt"));
    CHECK(lookup("教材/が.txt") != lookup("教材/か\xe3\x82\x99.txt"));
    text("Memo.txt","nihos read-only fixture\n");
    text("教材/漢字𠮷.txt","日本語・か\xe3\x82\x99・𠮷\n");
    text("empty-a.txt","");
    uint32_t before = calls;
    uint64_t id = 0, token = 0;
    CHECK(nih_fatfs_backend_open(session,epoch,UINT64_MAX,&token) == NIH_FB_STALE && calls == before);
    CHECK(nih_fatfs_backend_lookup(session,epoch,1,"../Memo.txt",11,&id) == NIH_FB_INVALID_NAME && calls == before);
    CHECK(nih_fatfs_backend_lookup(session,epoch,1,"0:Memo.txt",10,&id) == NIH_FB_INVALID_NAME && calls == before);
    CHECK(nih_fatfs_backend_lookup(session,epoch - 1,1,"Memo.txt",8,&id) == NIH_FB_STALE && calls == before);
    CHECK(nih_fatfs_disk_detach(disk,epoch) == NIH_FATFS_BUSY);
    uint64_t tokens[16];
    for (unsigned i = 0; i < 16; ++i) tokens[i] = opened("Memo.txt");
    id = lookup("Memo.txt");
    CHECK(nih_fatfs_backend_open(session,epoch,id,&token) == NIH_FB_NO_HANDLES);
    for (unsigned i = 0; i < 16; ++i) CHECK(nih_fatfs_backend_close(session,epoch,tokens[i]) == NIH_FB_OK);
    token = opened("Memo.txt");
    CHECK(token != tokens[0]);
    CHECK(nih_fatfs_backend_close(session,epoch,tokens[0]) == NIH_FB_STALE);
    CHECK(nih_fatfs_backend_close(session,epoch,token) == NIH_FB_OK);
    /* Shared chain/cancel budget still works through the new disk callback. */
    FIL file = {0};
    nih_ro_identity found;
    nih_ro_control control = {.remaining = 3};
    CHECK(nih_fatfs_disk_arm(disk,epoch,8192) == NIH_FATFS_OK);
    CHECK(nih_ro_open(&file,"fragment.bin",&found,&control) == NIH_RO_LIMIT && control.steps == 3);
    control = (nih_ro_control){.remaining=8192,.cancelled=cancel_after_three};
    control.context = &control;
    CHECK(nih_fatfs_disk_arm(disk,epoch,8192) == NIH_FATFS_OK);
    CHECK(nih_ro_open(&file,"fragment.bin",&found,&control) == NIH_RO_CANCELLED && control.steps == 3);
}
int main(int argc, char **argv) {
    if (argc != 5 && argc != 7) return 2;
    if (argc == 7) {
        patch_offset = strtoull(argv[5],NULL,10);
        size_t size = strlen(argv[6]);
        CHECK(size % 2 == 0 && size <= sizeof patch * 2);
        patch_size = size / 2;
        for (size_t i = 0; i < patch_size; ++i) {
            unsigned value;
            CHECK(sscanf(argv[6] + i * 2,"%2x",&value) == 1);
            patch[i] = (uint8_t)value;
        }
    }
    image = open(argv[1],O_RDONLY);
    struct stat info;
    CHECK(image >= 0 && !fstat(image,&info) && S_ISREG(info.st_mode) && info.st_size > 0 && info.st_size % 512 == 0);
    uint64_t total = (uint64_t)info.st_size / 512, first = strtoull(argv[2],NULL,10);
    device_total = total; volume_first = first; volume_count = total-first;
    const char *mode = argv[3];
    uint32_t probe_reads = 0;
    if (!strcmp(mode,"selected-vfs")) {
        uint8_t scratch[512];
        nih_fatfs_volume volume;
        CHECK(nih_fatfs_volume_probe(nih_fatfs_native_read,NULL,total,NIH_VOLUME_AUTO,scratch,&volume)==NIH_VOLUME_OK);
        CHECK(volume.first==first && volume.count<=total-first);
        volume_count = volume.count;
        probe_reads = volume.reads;
    }
    int card_rpc=!strncmp(mode,"card-rpc-",9);
    rpc_kind = (!strcmp(mode,"rpc-cancel") || !strcmp(mode,"card-rpc-cancel")) ? 1 :
               (!strcmp(mode,"rpc-exit") || !strcmp(mode,"card-rpc-exit")) ? 2 : !strcmp(mode,"rpc-large") ? 3 :
               !strcmp(mode,"card-rpc-transport-cancel") ? 4 : !strcmp(mode,"card-rpc-transport-remove") ? 5 :
               !strcmp(mode,"card-rpc-idle-remove") ? 6 : !strcmp(mode,"card-rpc-linked-cancel") ? 7 :
               !strcmp(mode,"card-rpc-linked-exit") ? 8 : 0;
    uint32_t bytes = nih_fatfs_backend_bytes();
    if (rpc_kind) {
        uintptr_t disk_address, fs_address;
        CHECK(nih_rpc_prepare(card_rpc ? nih_fatfs_card_bytes() : sizeof *disk,card_rpc ? 8 : bytes,&disk_address,&fs_address) == 0);
        if (card_rpc) workspace=(void *)disk_address;
        else {
            disk = (nih_fatfs_disk *)disk_address;
            workspace = (void *)fs_address;
        }
    } else workspace = malloc(bytes);
    int mounted;
    if (card_rpc) {
        nih_fatfs_card_report report;
        CHECK(total<=UINT32_MAX && nih_fatfs_card_mount(workspace,nih_fatfs_card_bytes(),(uint32_t)total,
            (uint32_t)epoch,&card_context,&report)==1);
        CHECK(nih_fatfs_card_path(card_context,(uint32_t)epoch));
        session=nih_fatfs_card_backend(card_context,(uint32_t)epoch);
        CHECK(session);
        mounted=NIH_FB_OK;
    } else {
    CHECK(first < total && nih_fatfs_disk_bind(disk,nih_fatfs_native_read,NULL,total,first,volume_count,epoch) == NIH_FATFS_OK);
    CHECK(workspace);
    CHECK(!nih_fatfs_backend_init(disk,bytes,disk,epoch));
    CHECK(!nih_fatfs_backend_init((uint8_t *)workspace + 1,bytes,disk,epoch));
    CHECK(!nih_fatfs_backend_init(workspace,bytes - 1,disk,epoch));
    CHECK(!nih_fatfs_backend_init(workspace,bytes,disk,epoch - 1));
    CHECK(!disk->retained && calls==probe_reads);
    CHECK(nih_fatfs_disk_arm(disk,epoch,7) == NIH_FATFS_OK);
    CHECK(nih_fatfs_disk_retain(disk,epoch) == NIH_FATFS_OK);
    CHECK(!nih_fatfs_backend_init(workspace,bytes,disk,epoch) && disk->remaining == 7);
    CHECK(nih_fatfs_disk_release(disk,epoch) == NIH_FATFS_OK);
    session = nih_fatfs_backend_init(workspace,bytes,disk,epoch);
    CHECK(session);
    CHECK(!nih_fatfs_backend_init(workspace,bytes,disk,epoch));
    mounted = nih_fatfs_backend_mount(session,epoch);
    }
    int observed = mounted;
    if (!strcmp(mode,"bad-volume")) CHECK(mounted == NIH_FB_CORRUPT);
    else {
        CHECK(mounted == NIH_FB_OK);
        if (!strcmp(mode,"normal")) normal(argv[4]);
        else if (!strcmp(mode,"vfs") || !strcmp(mode,"selected-vfs")) CHECK(nih_check_vfs() == 0);
        else if (rpc_kind) CHECK(nih_check_rpc() == 0);
        else if (!strcmp(mode,"large")) {
            uint64_t token = opened("large.bin");
            const uint64_t offsets[] = {UINT64_C(0x7ffffff8),UINT64_C(0xfffffff8),UINT64_C(0x100001ff0)};
            uint8_t data[16];
            uint32_t got,eof;
            for (unsigned i=0;i<3;++i) {
                CHECK(nih_fatfs_backend_read(session,epoch,token,offsets[i],data,sizeof data,&got,&eof) == NIH_FB_OK && got == 16);
                for (unsigned j=0;j<16;++j) CHECK(data[j] == 0xa0 + i*16 + j);
            }
            uint32_t before = calls;
            CHECK(nih_fatfs_backend_read(session,epoch,token,UINT64_MAX,data,sizeof data,&got,&eof) == NIH_FB_OK && got == 0 && eof == 1 && calls == before);
            CHECK(nih_fatfs_backend_close(session,epoch,token) == NIH_FB_OK);
        }
        else if (!strcmp(mode,"corrupt")) {
            uint64_t id;
            observed = nih_fatfs_backend_lookup(session,epoch,1,argv[4],(uint32_t)strlen(argv[4]),&id);
            CHECK(observed == NIH_FB_CORRUPT);
            uint32_t before = calls;
            CHECK(nih_fatfs_backend_lookup(session,epoch,1,"Memo.txt",8,&id) == NIH_FB_CORRUPT && calls == before);
        } else if (!strcmp(mode,"io") || !strcmp(mode,"removed")) {
            uint64_t token = opened("fragment.bin");
            uint8_t data[4096]; memset(data,0xa5,sizeof data);
            uint32_t got=0,eof=0;
            if (!strcmp(mode,"removed")) {
                CHECK(nih_fatfs_backend_read(session,epoch,token,0,data,1,&got,&eof) == NIH_FB_OK && got == 1);
                memset(data,0xa5,sizeof data);
                CHECK(host_backend_disk_remove() == NIH_FATFS_OK);
            }
            else host_backend_fail_after(2);
            uint32_t before = calls;
            observed = nih_fatfs_backend_read(session,epoch,token,0,data,sizeof data,&got,&eof);
            CHECK(observed == (!strcmp(mode,"removed") ? NIH_FB_REMOVED : NIH_FB_IO) && got == 0);
            for (size_t i=0;i<sizeof data;++i) CHECK(data[i] == 0xa5);
            uint32_t after = calls;
            CHECK(after == before + (!strcmp(mode,"removed") ? 0 : 2));
            CHECK(nih_fatfs_backend_read(session,epoch,token,0,data,1,&got,&eof) == observed && calls == after);
        } else return 2;
    }
    if (rpc_kind) CHECK(nih_rpc_finish() == 0);
    else {
        CHECK(nih_fatfs_backend_destroy(session,epoch) == NIH_FB_OK);
        uint64_t id;
        CHECK(nih_fatfs_backend_lookup(session,epoch,1,"Memo.txt",8,&id) == NIH_FB_STALE);
        uint8_t zero[4096] = {0};
        CHECK(!memcmp(disk->scratch,zero,sizeof zero));
        for (uint32_t i=0;i<bytes;++i) CHECK(((uint8_t *)workspace)[i] == 0);
        free(workspace);
    }
    CHECK(close(image) == 0);
    printf("{\"mode\":\"%s\",\"checks\":%u,\"observed\":%d,\"sector_reads\":%u,\"backend_bytes\":%u,\"rpc_used\":%u,\"rpc_charged\":%u,\"volume_probe_reads\":%u,\"linked_commands\":%u,\"linked_fences\":%u,\"linked_unpublished\":%u}\n",
        mode,checks,observed,calls,bytes,rpc_kind ? nih_rpc_metric(0) : 0,rpc_kind ? nih_rpc_metric(1) : 0,probe_reads,
        rpc_kind ? nih_rpc_metric(5) : 0,rpc_kind ? nih_rpc_metric(6) : 0,rpc_kind ? nih_rpc_metric(7) : 0);
}
