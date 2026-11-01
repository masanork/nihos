#include "wasm_export.h"
#include <assert.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef NDEBUG
#error "Assertions required"
#endif
#ifdef NIHOS_WAMR_BUDDY
enum { RUNTIME_ARENA_BYTES=128*1024, LINEAR_ARENA_BYTES=256*1024 };
extern int nih_wamr_arena_init(void *runtime, size_t runtime_length, void *linear, size_t linear_length);
static _Alignas(64) uint8_t runtime_arena_backing[RUNTIME_ARENA_BYTES];
static _Alignas(64) uint8_t linear_arena_backing[LINEAR_ARENA_BYTES];
extern void *nih_wamr_arena_alloc(uint32_t kind, size_t size);
extern int nih_wamr_arena_free(uint32_t kind, void *pointer);
extern int nih_wamr_arena_recovered(uint32_t kind);
extern size_t nih_wamr_arena_free_bytes(uint32_t kind);
#endif
/* Host-only accounting adapter: malloc is not a fixed nihos arena. All calls
 * are serialized by this single-threaded test owner. */
typedef union Header {
    max_align_t align;
    struct { size_t size; mem_alloc_usage_t usage; } v;
} Header;
static size_t live[2], peak[2], blocks[2], limit[2]={131072,65536};
#ifdef NIHOS_WAMR_BUDDY
static size_t arena_initial_free[2], arena_peak_reserved[2];
#endif
static unsigned sequence, fail_at;
static bool injected;
static void *alloc_usage(mem_alloc_usage_t usage, unsigned size) {
    if ((unsigned)usage > 1) abort();
    sequence++;
    if (fail_at && sequence==fail_at) { injected=true; return NULL; }
    if (size > limit[usage] - live[usage]) return NULL;
#ifdef NIHOS_WAMR_BUDDY
    Header *h=nih_wamr_arena_alloc((uint32_t)usage,sizeof(*h)+(size_t)size);
#else
    Header *h=malloc(sizeof(*h)+(size_t)size);
#endif
    if (!h) return NULL;
    h->v.size=size; h->v.usage=usage; live[usage]+=size; blocks[usage]++;
    if (peak[usage]<live[usage]) peak[usage]=live[usage];
#ifdef NIHOS_WAMR_BUDDY
    size_t reserved=arena_initial_free[usage]-nih_wamr_arena_free_bytes((uint32_t)usage);
    if (reserved>arena_peak_reserved[usage]) arena_peak_reserved[usage]=reserved;
#endif
    return h+1;
}
static void free_usage(mem_alloc_usage_t usage, void *ptr) {
    if (!ptr) return;
    Header *h=(Header *)ptr-1;
    assert((unsigned)usage<2 && h->v.usage==usage && live[usage]>=h->v.size && blocks[usage]>0);
    live[usage]-=h->v.size; blocks[usage]--;
#ifdef NIHOS_WAMR_BUDDY
    assert(nih_wamr_arena_free((uint32_t)usage,h)==0);
#else
    free(h);
#endif
}
static void *resize_usage(mem_alloc_usage_t usage, bool full_mapped, void *ptr, unsigned size) {
    (void)full_mapped;
    if (!ptr) return alloc_usage(usage,size);
    if (!size) { free_usage(usage,ptr); return NULL; }
    Header *old=(Header *)ptr-1; assert(old->v.usage==usage);
    /* Preserve old pointer and contents if allocation fails. */
    void *next=alloc_usage(usage,size); if (!next) return NULL;
    memcpy(next,ptr,old->v.size<size?old->v.size:size);
    free_usage(usage,ptr); return next;
}
static void allocator_selftest(void) {
    unsigned char *p=alloc_usage(Alloc_For_Runtime,32); assert(p);
    for(unsigned i=0;i<32;i++) p[i]=(unsigned char)i;
    fail_at=sequence+1;
    assert(resize_usage(Alloc_For_Runtime,false,p,64)==NULL);
    for(unsigned i=0;i<32;i++) assert(p[i]==(unsigned char)i);
    fail_at=0;
    free_usage(Alloc_For_Runtime,p);
    assert(live[0]==0 && live[1]==0 && blocks[0]==0 && blocks[1]==0);
    sequence=0; injected=false; peak[0]=0; peak[1]=0;
#ifdef NIHOS_WAMR_BUDDY
    arena_peak_reserved[0]=0; arena_peak_reserved[1]=0;
#endif
}
static int32_t rect(wasm_exec_env_t e,int32_t x,int32_t y,uint32_t w,uint32_t h,uint32_t rgb) {
    (void)e; return x==0 && y==0 && w==160 && h==80 && rgb==0x101010 ? 0 : -1;
}
static int32_t text(wasm_exec_env_t e,int32_t x,int32_t y,uint32_t off,uint32_t len,uint32_t rgb) {
    wasm_module_inst_t i=wasm_runtime_get_module_inst(e);
    /* Validate guest memory before interpreting any other arguments.  Besides
     * keeping the import boundary uniform, WAMR records an exception for an
     * invalid range and the caller observes a trapped invocation. */
    if (!wasm_runtime_validate_app_addr(i,off,len)) return -1;
    if (x!=8 || y!=8 || rgb!=0xffffff || len!=5) return -1;
    const void *p=wasm_runtime_addr_app_to_native(i,off);
    return p && !memcmp(p,"Ready",5) ? 0 : -1;
}
static NativeSymbol imports[]={ {"nih_app_fill_rect",(void *)rect,"(iiiii)i",NULL}, {"nih_app_text",(void *)text,"(iiiii)i",NULL} };
static unsigned char *read_file(const char *path, uint32_t *len) {
    FILE *f=fopen(path,"rb"); if(!f) return NULL;
    if(fseek(f,0,SEEK_END)) { fclose(f); return NULL; }
    long n=ftell(f); if(n<=0 || n>1024*1024 || fseek(f,0,SEEK_SET)) { fclose(f); return NULL; }
    unsigned char *p=malloc((size_t)n); if(!p || fread(p,1,(size_t)n,f)!=(size_t)n) { free(p); fclose(f); return NULL; }
    fclose(f); *len=(uint32_t)n; return p;
}
int main(int argc,char **argv) {
    if(argc!=4 && argc!=5) return 2;
    bool combined = argc==5 && strcmp(argv[4],"combined-init")==0;
    bool trap = argc==5 && strcmp(argv[4],"trap")==0;
    if (argc==5 && !combined && !trap) return 2;
#ifdef NIHOS_WAMR_BUDDY
    if (nih_wamr_arena_init(runtime_arena_backing,sizeof(runtime_arena_backing),linear_arena_backing,sizeof(linear_arena_backing))!=0) return 7;
    arena_initial_free[0]=nih_wamr_arena_free_bytes(0); arena_initial_free[1]=nih_wamr_arena_free_bytes(1);
#endif
    allocator_selftest();
    fail_at=(unsigned)strtoul(argv[2],NULL,10); limit[1]=(size_t)strtoul(argv[3],NULL,10);
    uint32_t len=0; uint8_t *bytes=read_file(argv[1],&len); if(!bytes) return 3;
    RuntimeInitArgs init={0}; init.mem_alloc_type=Alloc_With_Allocator;
    init.mem_alloc_option.allocator.malloc_func=(void *)alloc_usage;
    init.mem_alloc_option.allocator.realloc_func=(void *)resize_usage;
    init.mem_alloc_option.allocator.free_func=(void *)free_usage;
    if (combined) { init.native_module_name="nihos"; init.native_symbols=imports; init.n_native_symbols=2; }
    bool initialized=false, success=false; char error[256]={0};
    wasm_module_t module=NULL; wasm_module_inst_t inst=NULL; wasm_exec_env_t env=NULL;
    if (!(initialized=wasm_runtime_full_init(&init))) goto cleanup;
    if (!combined && !wasm_runtime_register_natives("nihos",imports,2)) goto cleanup;
    if (!(module=wasm_runtime_load(bytes,len,error,sizeof(error)))) goto cleanup;
    if (!(inst=wasm_runtime_instantiate(module,16384,0,error,sizeof(error)))) goto cleanup;
    if (!(env=wasm_runtime_create_exec_env(inst,16384))) goto cleanup;
    wasm_function_inst_t fn=wasm_runtime_lookup_function(inst,"nih_rust_app_frame"); if(!fn) goto cleanup;
    uint32_t arg[1]={0};
    success=wasm_runtime_call_wasm(env,fn,1,arg) && arg[0]==0;
    if (success && trap) {
        wasm_function_inst_t bad=wasm_runtime_lookup_function(inst,"nih_probe_raw_text");
        uint32_t invalid[2]={UINT32_MAX,4};
        success=bad && !wasm_runtime_call_wasm(env,bad,2,invalid) && wasm_runtime_get_exception(inst);
    }
cleanup:
    if(env) wasm_runtime_destroy_exec_env(env);
    if(inst) wasm_runtime_deinstantiate(inst);
    if(module) wasm_runtime_unload(module);
    if(initialized) wasm_runtime_destroy();
    free(bytes);
    printf("success=%u injected=%u attempts=%u runtime_peak=%zu linear_peak=%zu runtime_live=%zu linear_live=%zu runtime_blocks=%zu linear_blocks=%zu\n",success,injected,sequence,peak[0],peak[1],live[0],live[1],blocks[0],blocks[1]);
    if(live[0] || live[1] || blocks[0] || blocks[1]) return 4;
#ifdef NIHOS_WAMR_BUDDY
    if (!nih_wamr_arena_recovered(0) || !nih_wamr_arena_recovered(1) ||
        nih_wamr_arena_free_bytes(0)!=arena_initial_free[0] || nih_wamr_arena_free_bytes(1)!=arena_initial_free[1]) return 8;
    printf("buddy_recovered=1 arena_reservation=%u initial_free_runtime=%zu initial_free_linear=%zu peak_reserved_runtime=%zu peak_reserved_linear=%zu\n",RUNTIME_ARENA_BYTES+LINEAR_ARENA_BYTES,arena_initial_free[0],arena_initial_free[1],arena_peak_reserved[0],arena_peak_reserved[1]);
#endif
    if(fail_at) return injected ? 0 : 5;
    if(limit[1]<65536) return success ? 5 : 0;
    return success ? 0 : 6;
}
