/* Single-owner, allocation-free read-only littlefs backend. */
#include "storage_internal.h"
#include <string.h>
#include <stdint.h>
#define IO_LIMIT 8192u

static int sector_read(const struct lfs_config *cfg, lfs_block_t block,
                       lfs_off_t off, void *buffer, lfs_size_t size) {
    nih_ro *s=cfg->context;
    uint32_t ratio=s->logical_size/512u;
    if (s->poisoned || block >= s->capacity/ratio || off > s->logical_size ||
            size > s->logical_size-off || off%512u || size%512u) return LFS_ERR_IO;
    for (uint32_t i=0; i<size; i+=512u) {
        if (!s->remaining || s->reads>=s->max_reads) { s->poisoned=1; return LFS_ERR_IO; }
        --s->remaining; ++s->reads;
        if (s->read(s->context,block*ratio+(off+i)/512u,(uint8_t *)buffer+i)) {
            s->poisoned=1; return LFS_ERR_IO;
        }
    }
    return 0;
}
static int deny_prog(const struct lfs_config *c,lfs_block_t b,lfs_off_t o,const void *p,lfs_size_t n) {
    (void)b;(void)o;(void)p;(void)n; ++((nih_ro *)c->context)->denied; return LFS_ERR_IO;
}
static int deny_erase(const struct lfs_config *c,lfs_block_t b) {
    (void)b; ++((nih_ro *)c->context)->denied; return LFS_ERR_IO;
}
static int deny_sync(const struct lfs_config *c) { ++((nih_ro *)c->context)->denied; return LFS_ERR_IO; }
static int begin(nih_ro *s) {
    if (!s || !s->mounted) return NIH_RO_NODEV;
    if (s->poisoned) return NIH_RO_IO;
    s->remaining=IO_LIMIT; return 0;
}
static int result(nih_ro *s,int err) {
    if (err==LFS_ERR_IO || err==LFS_ERR_CORRUPT) s->poisoned=1;
    return err;
}
static int path_copy(nih_ro *s,const char *path,uint32_t n) {
    if (!path || !n || n>NIH_RO_PATH_MAX || path[0]!='/') return NIH_RO_INVAL;
    if (n>1 && path[n-1]=='/') return NIH_RO_INVAL;
    uint32_t start=1;
    for (uint32_t i=0;i<n;++i) {
        if (!path[i] || (uint8_t)path[i]<32u) return NIH_RO_INVAL;
        if (i>0 && path[i]=='/') {
            uint32_t size=i-start;
            if (!size || (size==1 && path[start]=='.') || (size==2 && path[start]=='.' && path[start+1]=='.')) return NIH_RO_INVAL;
            start=i+1;
        }
    }
    uint32_t size=n-start;
    if (n>1 && ((size==1 && path[start]=='.') || (size==2 && path[start]=='.' && path[start+1]=='.'))) return NIH_RO_INVAL;
    memcpy(s->path,path,n); s->path[n]=0; return 0;
}
nih_ro *nih_ro_init(void *workspace,uint32_t bytes,nih_ro_sector_read read,void *context) {
    if (!workspace || (uintptr_t)workspace%8u || bytes<sizeof(nih_ro) || bytes>NIH_RO_WORKSPACE_BYTES || !read) return NULL;
    memset(workspace,0,bytes);
    nih_ro *s=workspace;
    s->read=read; s->context=context; s->bytes=bytes; s->next_handle=1; s->max_reads=UINT32_MAX;
    s->file_cfg.buffer=s->file_cache;
    return s;
}
int nih_ro_mount(nih_ro *s,uint32_t sectors) {
    if (!s || !sectors) return NIH_RO_INVAL;
    if (s->mounted) return NIH_RO_BUSY;
    s->capacity=sectors; s->remaining=IO_LIMIT; s->poisoned=0;
    s->cfg=(struct lfs_config){.context=s,.read=sector_read,.prog=deny_prog,.erase=deny_erase,.sync=deny_sync,
        .read_size=512,.prog_size=512,.block_cycles=-1,.cache_size=512,.lookahead_size=8,
        .read_buffer=s->read_cache,.prog_buffer=s->prog_cache,.lookahead_buffer=s->lookahead};
    const uint32_t geometries[]={512,4096};
    int err=NIH_RO_INVAL;
    for (unsigned i=0;i<2;++i) {
        s->logical_size=geometries[i];
        uint32_t ratio=s->logical_size/512u;
        if (sectors<ratio || sectors%ratio) continue;
        s->cfg.block_size=s->logical_size; s->cfg.block_count=sectors/ratio;
        err=lfs_mount(&s->fs,&s->cfg);
        if (!err) { s->mounted=1; return 0; }
        if (s->poisoned || (err!=LFS_ERR_INVAL && err!=LFS_ERR_CORRUPT)) break;
    }
    return err;
}
int nih_ro_stat(nih_ro *s,const char *path,uint32_t n,nih_ro_info *info) {
    if (!info) return NIH_RO_INVAL;
    int err=begin(s); if (err) return err;
    if ((err=path_copy(s,path,n))) return err;
    err=lfs_stat(&s->fs,s->path,&s->info);
    if (!err) *info=(nih_ro_info){s->info.type,s->info.size};
    return result(s,err);
}
int nih_ro_open(nih_ro *s,uint32_t owner,const char *path,uint32_t n,uint32_t *handle) {
    if (!owner || !handle) return NIH_RO_INVAL;
    int err=begin(s); if (err) return err;
    if (s->opened) return NIH_RO_BUSY;
    if (!s->next_handle) return NIH_RO_LIMIT;
    if ((err=path_copy(s,path,n))) return err;
    err=lfs_file_opencfg(&s->fs,&s->file,s->path,LFS_O_RDONLY,&s->file_cfg);
    if (err) return result(s,err);
    lfs_soff_t size=lfs_file_size(&s->fs,&s->file);
    if (size<0) { (void)lfs_file_close(&s->fs,&s->file); return result(s,(int)size); }
    s->opened=1; s->owner=owner; s->handle=s->next_handle++;
    s->file_size=(uint32_t)size; *handle=s->handle;
    return 0;
}
int nih_ro_list_root(nih_ro *s,uint32_t index,nih_ro_entry *entry) {
    if (!entry || index>=128u) return NIH_RO_INVAL;
    int err=begin(s); if (err) return err;
    err=lfs_dir_open(&s->fs,&s->directory,"/"); if (err) return result(s,err);
    uint32_t found=0;
    for (;;) {
        err=lfs_dir_read(&s->fs,&s->directory,&s->info);
        if (err<=0) break;
        if (!strcmp(s->info.name,".") || !strcmp(s->info.name,"..")) continue;
        if (found++==index) {
            memset(entry,0,sizeof(*entry)); entry->type=s->info.type; entry->size=s->info.size;
            memcpy(entry->name,s->info.name,strlen(s->info.name)+1); break;
        }
    }
    int close_err=lfs_dir_close(&s->fs,&s->directory);
    if (err>=0 && close_err) err=close_err;
    return result(s,err);
}
static int owned(nih_ro *s,uint32_t owner,uint32_t handle) {
    if (!s || !s->mounted) return NIH_RO_NODEV;
    if (!s->opened || !handle || handle!=s->handle) return NIH_RO_BADF;
    if (!owner || owner!=s->owner) return NIH_RO_OWNER;
    return 0;
}
int nih_ro_read_at(nih_ro *s,uint32_t owner,uint32_t handle,uint32_t offset,void *buffer,uint32_t n) {
    int err=owned(s,owner,handle); if (err) return err;
    if (n>NIH_RO_READ_MAX || (!buffer && n) || offset>s->file_size) return NIH_RO_INVAL;
    if ((err=begin(s))) return err;
    if (!n) return 0;
    lfs_soff_t position=lfs_file_seek(&s->fs,&s->file,(lfs_soff_t)offset,LFS_SEEK_SET);
    if (position<0) return result(s,(int)position);
    if ((uint32_t)position!=offset) return result(s,LFS_ERR_CORRUPT);
    return result(s,(int)lfs_file_read(&s->fs,&s->file,buffer,n));
}
int nih_ro_close(nih_ro *s,uint32_t owner,uint32_t handle) {
    int err=owned(s,owner,handle); if (err) return err;
    err=lfs_file_close(&s->fs,&s->file);
    s->opened=0; s->owner=0; s->handle=0;
    return result(s,err);
}
int nih_ro_release_owner(nih_ro *s,uint32_t owner) {
    if (!s || !s->mounted) return NIH_RO_NODEV;
    if (!owner) return NIH_RO_INVAL;
    return s->opened && s->owner==owner ? nih_ro_close(s,owner,s->handle) : 0;
}
int nih_ro_unmount(nih_ro *s) {
    if (!s || !s->mounted) return NIH_RO_NODEV;
    if (s->opened) return NIH_RO_BUSY;
    int err=lfs_unmount(&s->fs); s->mounted=0; return err;
}
int nih_ro_destroy(nih_ro *s) {
    if (!s) return NIH_RO_INVAL;
    if (s->opened) { int err=nih_ro_close(s,s->owner,s->handle); if (err) return err; }
    if (s->mounted) { int err=nih_ro_unmount(s); if (err) return err; }
    uint32_t bytes=s->bytes; memset(s,0,bytes); return 0;
}
