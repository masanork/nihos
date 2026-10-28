#include "nihos_fatfs_card.h"
#include "nihos_fatfs_volume.h"
#include "safety.h"
#include <string.h>
struct nih_fatfs_card {
    nih_fatfs_disk disk;
    uint64_t backend_memory[2048];
    nih_fatfs_backend *backend;
    nih_fatfs_volume volume;
    DIR directory;
    FILINFO entry;
    char path[512];
    uint8_t data[4096];
    uint32_t generation;
};
static nih_fatfs_card *active_card;
#if defined(__riscv)
__attribute__((used))
#endif
const uint32_t nih_fatfs_card_workspace_bytes = sizeof(nih_fatfs_card);
uint32_t nih_fatfs_card_bytes(void) { return sizeof(nih_fatfs_card); }
static uint32_t crc(const void *data, uint32_t length) {
    const uint8_t *p=data; uint32_t value=UINT32_MAX;
    for (uint32_t i=0;i<length;++i) {
        value^=p[i];
        for (unsigned bit=0;bit<8;++bit) value=(value>>1)^((0u-(value&1))&0xedb88320u);
    }
    return ~value;
}
static int matches(nih_fatfs_card *card, uint32_t generation) {
    return card && active_card==card && generation && card->generation==generation;
}
static int overlaps(const void *a, size_t an, const void *b, size_t bn) {
    uintptr_t x=(uintptr_t)a,y=(uintptr_t)b;
    return x<=y ? y-x<an : x-y<bn;
}
nih_fatfs_backend *nih_fatfs_card_backend(nih_fatfs_card *card, uint32_t generation) {
    return matches(card,generation) ? card->backend : NULL;
}
const char *nih_fatfs_card_path(nih_fatfs_card *card, uint32_t generation) {
    return matches(card,generation) ? card->path : NULL;
}
uint32_t nih_fatfs_card_reads(nih_fatfs_card *card, uint32_t generation) {
    return matches(card,generation) ? card->disk.reads : 0;
}
int nih_fatfs_card_destroy(nih_fatfs_card *card, uint32_t generation) {
    if (!matches(card,generation)) return 0;
    if (card->backend) {
        if (nih_fatfs_backend_destroy(card->backend,generation)) return -1;
    } else if (nih_fatfs_disk_detach(&card->disk,generation)) return -1;
    memset(card,0,sizeof *card);
    active_card=NULL;
    return 1;
}
int nih_fatfs_card_mount(void *memory, uint32_t bytes, uint32_t sectors,
    uint32_t generation, nih_fatfs_card **context, nih_fatfs_card_report *out) {
    if (active_card || !memory || (uintptr_t)memory%8 || bytes<sizeof(nih_fatfs_card) ||
        !out || !context || !generation) return 0;
    if (overlaps(memory,sizeof(nih_fatfs_card),out,sizeof *out) ||
        overlaps(memory,sizeof(nih_fatfs_card),context,sizeof *context) ||
        overlaps(out,sizeof *out,context,sizeof *context)) return 0;
    nih_fatfs_card *w=memory;
    memset(w,0,sizeof *w); memset(out,0,sizeof *out);
    out->generation=generation; out->sectors=sectors;
    if (nih_fatfs_volume_probe(nih_fatfs_native_read,NULL,sectors,NIH_VOLUME_AUTO,
            w->data,&w->volume)!=NIH_VOLUME_OK) return 0;
    out->kind=w->volume.kind; out->partition=w->volume.partition;
    out->first=(uint32_t)w->volume.first; out->count=(uint32_t)w->volume.count;
    if (nih_fatfs_disk_bind(&w->disk,nih_fatfs_native_read,NULL,sectors,
            w->volume.first,w->volume.count,generation)) return 0;
    w->generation=generation;
    active_card=w;
    int found=0, directory_open=0;
    if (nih_fatfs_backend_bytes()>sizeof w->backend_memory) goto done;
    w->backend=nih_fatfs_backend_init(w->backend_memory,sizeof w->backend_memory,&w->disk,generation);
    if (!w->backend || nih_fatfs_backend_mount(w->backend,generation)) goto done;
    nih_ro_control control={.remaining=8192};
    if (nih_fatfs_disk_arm(&w->disk,generation,NIH_FATFS_READ_BUDGET) ||
        nih_ro_directory(&w->directory,"",&control)!=NIH_RO_OK) goto done;
    directory_open=1;
    for (unsigned i=0;i<64;++i) {
        if (f_readdir(&w->directory,&w->entry)!=FR_OK || !w->entry.fname[0]) break;
        if (!(w->entry.fattrib&(AM_DIR|AM_HID|AM_SYS)) && w->entry.fsize && w->entry.fsize<=1048576) {
            size_t length=strlen(w->entry.fname);
            if (length>511) continue;
            memcpy(w->path,w->entry.fname,length+1);
            out->file_name_crc=crc(w->path,(uint32_t)length);
            found=1;
            break;
        }
    }
done:
    if (directory_open && f_closedir(&w->directory)!=FR_OK) return -1;
    out->reads=w->disk.reads;
    if (!found) {
        if (nih_fatfs_card_destroy(w,generation)!=1) return -1;
        out->destroyed=1;
        return 0;
    }
    *context=w;
    return 1;
}
int nih_fatfs_card_read(void *memory, uint32_t bytes, uint32_t sectors,
                       uint32_t generation, nih_fatfs_card_report *out) {
    nih_fatfs_card *w=NULL;
    int mounted=nih_fatfs_card_mount(memory,bytes,sectors,generation,&w,out);
    if (mounted!=1) return mounted;
    int success=0;
    uint64_t identity=0,token=0;
    uint32_t length=(uint32_t)strlen(w->path),got=0,eof=0;
    if (nih_fatfs_backend_lookup(w->backend,generation,1,w->path,length,&identity) ||
        nih_fatfs_backend_open(w->backend,generation,identity,&token)) goto done;
    int error=nih_fatfs_backend_read(w->backend,generation,token,0,w->data,sizeof w->data,&got,&eof);
    if (!error && got) {
        out->bytes=got; out->crc=crc(w->data,got);
        memset(w->data,0,sizeof w->data);
        uint32_t again=0;
        error=nih_fatfs_backend_read(w->backend,generation,token,0,w->data,sizeof w->data,&again,&eof);
        if (!error && again==got) {
            out->repeated_crc=crc(w->data,again);
            success=out->crc==out->repeated_crc;
        }
    }
    if (nih_fatfs_backend_close(w->backend,generation,token)) success=0;
done:
    out->reads=w->disk.reads;
    if (nih_fatfs_card_destroy(w,generation)!=1) return -1;
    out->destroyed=1; out->status=(uint32_t)success;
    return success;
}
