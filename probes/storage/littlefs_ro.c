/* Boot qualification client of the read-only API, not a runtime service task. */
#include "nihos_storage_probe.h"
#include "storage_internal.h"
#include <string.h>
#define ENTRY_LIMIT 128u
#define FILE_LIMIT 65536u
static int backend_read(void *unused,uint32_t lba,void *sector) {
    (void)unused; return nih_storage_read(lba,sector);
}
static uint32_t fold(uint32_t d,uint8_t b) { return (d^b)*16777619u; }
static uint32_t fold_word(uint32_t d,uint32_t word) {
    for (unsigned i=0;i<4;++i) d=fold(d,(uint8_t)(word>>(8*i)));
    return d;
}
static uint32_t name_digest(uint32_t d,const char *name) {
    for (unsigned i=0;name[i];++i) d=fold(d,(uint8_t)name[i]);
    return fold(d,0);
}
static int one_pass(nih_ro *s,uint32_t sectors,nih_storage_report *r,nih_storage_api_report *api) {
    int err=nih_ro_mount(s,sectors);
    if (err) return err;
    err=lfs_dir_open(&s->fs,&s->directory,"/");
    if (err) goto unmount;
    r->block_size=s->cfg.block_size; r->block_count=s->cfg.block_count;
    s->selected[0]=0;
    uint32_t smallest=FILE_LIMIT+1u;
    r->directory_digest=0x811c9dc5u;
    for (;;) {
        err=lfs_dir_read(&s->fs,&s->directory,&s->info);
        if (err<=0) break;
        if (!strcmp(s->info.name,".") || !strcmp(s->info.name,"..")) continue;
        if (++r->entries>ENTRY_LIMIT) { err=LFS_ERR_FBIG; break; }
        if (s->info.type==LFS_TYPE_REG) ++r->files;
        else if (s->info.type==LFS_TYPE_DIR) ++r->directories;
        else { err=LFS_ERR_CORRUPT; break; }
        r->directory_digest=name_digest(r->directory_digest,s->info.name);
        r->directory_digest=fold_word(r->directory_digest,s->info.type);
        r->directory_digest=fold_word(r->directory_digest,s->info.size);
        size_t n=strlen(s->info.name);
        if (s->info.type==LFS_TYPE_REG && s->info.size && s->info.size<smallest && n+1<=NIH_RO_PATH_MAX) {
            smallest=s->info.size; s->selected[0]='/'; memcpy(s->selected+1,s->info.name,n+1);
        }
    }
    {
        int close_err=lfs_dir_close(&s->fs,&s->directory);
        if (!err) err=close_err;
    }
    if (err) goto unmount;
    if (s->selected[0]) {
        uint32_t n=(uint32_t)strlen(s->selected),handle=0;
        nih_ro_info info;
        if ((err=nih_ro_stat(s,s->selected,n,&info))) goto unmount;
        if (info.type!=LFS_TYPE_REG || info.size!=smallest) { err=LFS_ERR_CORRUPT; goto unmount; }
        if ((err=nih_ro_open(s,1,s->selected,n,&handle))) goto unmount;
        ++api->opens;
        r->file_name_digest=name_digest(0x811c9dc5u,s->selected+1);
        if (nih_ro_read_at(s,2,handle,0,s->data,1)!=NIH_RO_OWNER ||
            nih_ro_read_at(s,1,handle,0,s->data,513)!=NIH_RO_INVAL) { err=LFS_ERR_CORRUPT; goto cleanup; }
        api->rejected+=2;
        uint32_t crc=UINT32_MAX;
        uint8_t first=0;
        while (r->file_bytes<smallest) {
            uint32_t want=smallest-r->file_bytes;
            if (want>512) want=512;
            int got=nih_ro_read_at(s,1,handle,r->file_bytes,s->data,want); ++api->read_calls;
            if (got<=0 || (uint32_t)got>want) { err=got<0 ? got : LFS_ERR_CORRUPT; break; }
            if (!r->file_bytes) first=s->data[0];
            for (int i=0;i<got;++i) {
                crc^=s->data[i];
                for (unsigned b=0;b<8;++b) crc=(crc>>1)^((crc&1)?0xedb88320u:0);
            }
            r->file_bytes+=(uint32_t)got;
        }
        if (!err) {
            int eof=nih_ro_read_at(s,1,handle,smallest,s->data,1); ++api->read_calls;
            int rewind=nih_ro_read_at(s,1,handle,0,s->data,1); ++api->read_calls;
            if (eof!=0 || rewind!=1 || s->data[0]!=first) err=LFS_ERR_CORRUPT;
        }
        r->file_crc=~crc;
        if (!err) {
            if ((err=nih_ro_release_owner(s,1))) goto cleanup;
            ++api->cancelled; ++api->closes;
            if (nih_ro_read_at(s,1,handle,0,s->data,1)!=NIH_RO_BADF) { err=LFS_ERR_CORRUPT; goto cleanup; }
            ++api->rejected;
            uint32_t next=0;
            if ((err=nih_ro_open(s,1,s->selected,n,&next))) goto cleanup;
            ++api->opens;
            if (next==handle || nih_ro_close(s,1,handle)!=NIH_RO_BADF) { err=LFS_ERR_CORRUPT; goto cleanup; }
            ++api->rejected;
            if ((err=nih_ro_close(s,1,next))) goto cleanup;
            ++api->closes;
        }
cleanup:
        if (s->opened) { int close_err=nih_ro_release_owner(s,1); if (!err) err=close_err; }
    }
unmount:
    {
        int close_err=nih_ro_unmount(s); if (!err) err=close_err;
    }
    return err;
}
void nih_storage_probe(void *workspace,uint32_t bytes,uint32_t sectors,
                       nih_storage_report *report,nih_storage_api_report *api) {
    memset(report,0,sizeof(*report)); memset(api,0,sizeof(*api));
    report->status=3; report->error_code=(uint32_t)(-NIH_RO_INVAL);
    nih_ro *s=nih_ro_init(workspace,bytes,backend_read,NULL);
    if (!s) return;
    s->max_reads=8192;
    api->workspace_bytes=bytes; api->used_bytes=sizeof(*s);
    for (unsigned pass=0;pass<2;++pass) {
        nih_storage_report current={0};
        int err=one_pass(s,sectors,&current,api);
        if (!err && pass && (current.block_size!=report->block_size || current.block_count!=report->block_count ||
                current.entries!=report->entries || current.files!=report->files || current.directories!=report->directories ||
                current.directory_digest!=report->directory_digest || current.file_bytes!=report->file_bytes ||
                current.file_crc!=report->file_crc || current.file_name_digest!=report->file_name_digest)) err=LFS_ERR_CORRUPT;
        if (err) { report->status=3; report->error_code=(uint32_t)(-err); break; }
        current.passes=pass+1; current.status=current.file_bytes?2:1; *report=current;
    }
    report->reads=s->reads; report->denied_writes=s->denied;
    if (nih_ro_destroy(s)) return;
    const uint8_t *p=workspace;
    api->cleared=1;
    for (uint32_t i=0;i<bytes;++i) if (p[i]) api->cleared=0;
    if (report->passes==2 && report->status!=3 && api->cleared) api->status=1;
}
