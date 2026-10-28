#include "nihos_fatfs_card.h"
#include "nihos_fatfs_volume.h"
#include "nihos_fatfs_backend.h"
#include "safety.h"
#include <string.h>
typedef struct {
    nih_fatfs_disk disk;
    uint64_t backend[2048];
    nih_fatfs_volume volume;
    DIR directory;
    FILINFO entry;
    uint8_t data[4096];
} workspace;
uint32_t nih_fatfs_card_bytes(void) { return sizeof(workspace); }
static uint32_t crc(const void *data, uint32_t length) {
    const uint8_t *p=data; uint32_t value=UINT32_MAX;
    for (uint32_t i=0;i<length;++i) {
        value^=p[i];
        for (unsigned bit=0;bit<8;++bit) value=(value>>1)^((0u-(value&1))&0xedb88320u);
    }
    return ~value;
}
int nih_fatfs_card_read(void *memory, uint32_t bytes, uint32_t sectors,
                       uint32_t generation, nih_fatfs_card_report *out) {
    if (!memory || (uintptr_t)memory%8 || bytes<sizeof(workspace) || !out || !generation)
        return 0;
    workspace *w=memory;
    memset(w,0,sizeof *w); memset(out,0,sizeof *out);
    out->generation=generation; out->sectors=sectors;
    if (nih_fatfs_volume_probe(nih_fatfs_native_read,NULL,sectors,NIH_VOLUME_AUTO,
            w->data,&w->volume)!=NIH_VOLUME_OK) return 0;
    out->kind=w->volume.kind; out->partition=w->volume.partition;
    out->first=(uint32_t)w->volume.first; out->count=(uint32_t)w->volume.count;
    if (nih_fatfs_disk_bind(&w->disk,nih_fatfs_native_read,NULL,sectors,
            w->volume.first,w->volume.count,generation)) return 0;
    nih_fatfs_backend *backend=NULL;
    int success=0, directory_open=0;
    if (nih_fatfs_backend_bytes()>sizeof w->backend) goto done;
    backend=nih_fatfs_backend_init(w->backend,sizeof w->backend,&w->disk,generation);
    if (!backend || nih_fatfs_backend_mount(backend,generation)) goto done;
    nih_ro_control control={.remaining=8192};
    if (nih_fatfs_disk_arm(&w->disk,generation,NIH_FATFS_READ_BUDGET) ||
        nih_ro_directory(&w->directory,"",&control)!=NIH_RO_OK) goto done;
    directory_open=1;
    for (unsigned i=0;i<64;++i) {
        if (f_readdir(&w->directory,&w->entry)!=FR_OK || !w->entry.fname[0]) break;
        if (!(w->entry.fattrib&(AM_DIR|AM_HID|AM_SYS)) && w->entry.fsize && w->entry.fsize<=1048576) {
            uint64_t identity=0,token=0;
            uint32_t length=(uint32_t)strlen(w->entry.fname),got=0,eof=0;
            if (nih_fatfs_backend_lookup(backend,generation,1,w->entry.fname,length,&identity) ||
                nih_fatfs_backend_open(backend,generation,identity,&token)) break;
            int error=nih_fatfs_backend_read(backend,generation,token,0,w->data,sizeof w->data,&got,&eof);
            if (!error && got) {
                out->bytes=got; out->crc=crc(w->data,got);
                out->file_name_crc=crc(w->entry.fname,length);
                memset(w->data,0,sizeof w->data);
                uint32_t again=0;
                error=nih_fatfs_backend_read(backend,generation,token,0,w->data,sizeof w->data,&again,&eof);
                if (!error && again==got) {
                    out->repeated_crc=crc(w->data,again);
                    success=out->crc==out->repeated_crc;
                }
            }
            if (nih_fatfs_backend_close(backend,generation,token)) success=0;
            break;
        }
    }
done:
    if (directory_open && f_closedir(&w->directory)!=FR_OK) return -1;
    out->reads=w->disk.reads;
    if (backend) {
        if (nih_fatfs_backend_destroy(backend,generation)) return -1;
    } else if (nih_fatfs_disk_detach(&w->disk,generation)) return -1;
    out->destroyed=1; out->status=(uint32_t)success;
    return success;
}
