#include "wasm_export.h"
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef NDEBUG
#error "Tests must run with assertions enabled"
#endif

/* Single-threaded test fixture; not a production host service. */
static uint8_t pool[4 * 1024 * 1024];
static uint32_t calls, color;
static char label[129];
static bool fail_rect;
#ifdef NIHOS_JOURNAL_ADMISSION
enum { SERVICE_GRAPHICS = 1, SERVICE_NETWORK = 32 };
struct import_owner {
    wasm_module_inst_t instance;
    uint32_t services;
    bool active;
};
static bool graphics_allowed(wasm_exec_env_t env) {
    wasm_module_inst_t instance = wasm_runtime_get_module_inst(env);
    struct import_owner *owner = wasm_runtime_get_custom_data(instance);
    return owner && owner->active && owner->instance == instance &&
           (owner->services & SERVICE_GRAPHICS) != 0;
}
#endif
static int32_t rect(wasm_exec_env_t env, int32_t x, int32_t y, uint32_t w, uint32_t h, uint32_t rgb) {
#ifdef NIHOS_JOURNAL_ADMISSION
    if (!graphics_allowed(env)) return -5;
#endif
    (void)env;
    if (x != 0 || y != 0 || w != 160 || h != 80 || rgb > 0xffffff) return -1;
    calls++; color = rgb;
    return fail_rect ? -4 : 0;
}
static int32_t text(wasm_exec_env_t env, int32_t x, int32_t y, uint32_t off, uint32_t len, uint32_t rgb) {
#ifdef NIHOS_JOURNAL_ADMISSION
    if (!graphics_allowed(env)) return -5;
#endif
    wasm_module_inst_t inst = wasm_runtime_get_module_inst(env);
    if (x != 8 || y != 8 || rgb != 0xffffff || len > 128) return -1;
    if (!wasm_runtime_validate_app_addr(inst, off, len)) return -1;
    const uint8_t *src = wasm_runtime_addr_app_to_native(inst, off);
    if (!src && len) return -1;
    for (uint32_t i=0; i<len; i++) if (src[i]<32 || src[i]>126) return -2;
    if (len) memcpy(label, src, len); label[len]=0; calls++;
    return 0;
}
static NativeSymbol natives[] = {
    {"nih_app_fill_rect", (void *)rect, "(iiiii)i", NULL},
    {"nih_app_text", (void *)text, "(iiiii)i", NULL},
};
static uint8_t *read_module(const char *name, uint32_t *length) {
    FILE *f=fopen(name,"rb"); if (!f) return NULL;
    if (fseek(f,0,SEEK_END) || ftell(f)<0) { fclose(f); return NULL; }
    long n=ftell(f); if (n>1024*1024 || fseek(f,0,SEEK_SET)) { fclose(f); return NULL; }
    uint8_t *p=malloc((size_t)n); if (!p || fread(p,1,(size_t)n,f)!=(size_t)n) { free(p); fclose(f); return NULL; }
    fclose(f); *length=(uint32_t)n; return p;
}
#ifdef NIHOS_JOURNAL_ADMISSION
extern int nih_boot_buffer_admit(const uint8_t *, size_t, const uint8_t *, size_t,
                                const uint8_t *, size_t, const uint8_t *, size_t,
                                uint32_t, uint8_t *, size_t, uint32_t *, uint32_t *);
static uint8_t *read_admitted(char **paths, uint32_t grants, uint32_t *length,
                             uint32_t *services) {
    uint8_t *media[4] = {0};
    uint32_t sizes[4] = {0};
    uint8_t *output = malloc(4096);
    int status = 1;
    for (unsigned i=0; i<4; i++) {
        media[i] = read_module(paths[i], &sizes[i]);
        if (!media[i]) goto cleanup;
    }
    if (!output) goto cleanup;
    status = nih_boot_buffer_admit(media[0], sizes[0], media[1], sizes[1],
                                  media[2], sizes[2], media[3], sizes[3],
                                  grants, output, 4096, length, services);
cleanup:
    for (unsigned i=0; i<4; i++) free(media[i]);
    fprintf(stderr, "NIHOS_BOOT_BUFFER status=%d wasm_bytes=%u services=%u\n", status, *length, *services);
    if (status != 0) { free(output); return NULL; }
    return output;
}
#endif
int main(int argc, char **argv) {
    uint32_t n=0;
#ifdef NIHOS_JOURNAL_ADMISSION
    if (argc != 5 && !(argc == 6 && strcmp(argv[5], "deny-graphics") == 0)) return 2;
    unsigned long pool_bytes = 262144;
    bool fixed_memory = true;
    uint32_t services = 0;
    uint32_t grants = argc == 6 ? 0 : SERVICE_GRAPHICS | SERVICE_NETWORK;
    uint8_t *buf = read_admitted(argv+1, grants, &n, &services); if (!buf) return 20;
    assert(services == SERVICE_GRAPHICS);
    uint8_t *pristine = malloc(n); if (!pristine) { free(buf); return 4; }
    memcpy(pristine, buf, n);
#else
    if (argc < 2 || argc > 4) return 2;
    unsigned long pool_bytes = argc >= 3 ? strtoul(argv[2], NULL, 10) : sizeof(pool);
    bool fixed_memory = argc == 4 && strcmp(argv[3], "fixed-memory") == 0;
    uint8_t *buf=read_module(argv[1], &n); if (!buf) return 4;
#endif
    if (pool_bytes < 4096 || pool_bytes > sizeof(pool)) return 2;
    RuntimeInitArgs init={0}; init.mem_alloc_type=Alloc_With_Pool;
    init.mem_alloc_option.pool.heap_buf=pool; init.mem_alloc_option.pool.heap_size=(uint32_t)pool_bytes;
    init.native_module_name="nihos"; init.native_symbols=natives; init.n_native_symbols=2;
    if (!wasm_runtime_full_init(&init)) return 3;
    mem_alloc_info_t baseline={0}; assert(wasm_runtime_get_mem_alloc_info(&baseline));
    char error[256]={0};
    wasm_module_t module=wasm_runtime_load(buf,n,error,sizeof(error));
    if (!module) { fprintf(stderr,"load: %s\n",error); return 5; }
    wasm_module_inst_t inst=wasm_runtime_instantiate(module, 16384, 0, error, sizeof(error));
    if (!inst) { fprintf(stderr,"instantiate: %s\n",error); return 6; }
#ifdef NIHOS_JOURNAL_ADMISSION
    struct import_owner owner = {inst, services, true};
    wasm_runtime_set_custom_data(inst, &owner);
#endif
    wasm_exec_env_t env=wasm_runtime_create_exec_env(inst,16384); if (!env) { fprintf(stderr,"exec env allocation failed\n"); return 7; }
    wasm_function_inst_t fn=wasm_runtime_lookup_function(inst,"nih_rust_app_frame"); if (!fn) return 8;
    uint32_t args[1]={0};
#ifdef NIHOS_JOURNAL_ADMISSION
    /* Effective rights are instance-bound. Every denial must happen before
       a host drawing operation or guest-text mapping. */
    owner.services = 0;
    assert(wasm_runtime_call_wasm(env,fn,1,args) && (int32_t)args[0]==-5 && calls==0);
    assert(text(env,8,8,UINT32_MAX,4,0xffffff)==-5 && calls==0);
    owner.services = services;
    owner.active = false; args[0]=0;
    assert(wasm_runtime_call_wasm(env,fn,1,args) && (int32_t)args[0]==-5 && calls==0);
    owner.active = true; owner.instance = NULL; args[0]=0;
    assert(wasm_runtime_call_wasm(env,fn,1,args) && (int32_t)args[0]==-5 && calls==0);
    owner.instance = inst; wasm_runtime_set_custom_data(inst, NULL); args[0]=0;
    assert(wasm_runtime_call_wasm(env,fn,1,args) && (int32_t)args[0]==-5 && calls==0);
    wasm_runtime_set_custom_data(inst, &owner); args[0]=0;
    puts("NIHOS_IMPORT_OWNER denied_service=1 inactive=1 mismatched=1 detached=1 calls=0 effective_services=1");
#endif
    assert(wasm_runtime_call_wasm(env,fn,1,args) && args[0]==0 && calls==2 && color==0x101010 && strcmp(label,"Ready")==0);
    calls=0; args[0]=1;
    assert(wasm_runtime_call_wasm(env,fn,1,args) && args[0]==0 && calls==2 && color==0x204060 && strcmp(label,"Pressed")==0);
    calls=0; fail_rect=true; args[0]=1;
    assert(wasm_runtime_call_wasm(env,fn,1,args) && (int32_t)args[0]==-4 && calls==1);
    calls=0; args[0]=2;
    assert(wasm_runtime_call_wasm(env,fn,1,args) && (int32_t)args[0]==-1 && calls==0);
    wasm_function_inst_t nested=wasm_runtime_lookup_function(inst,"nih_probe_nested"); assert(nested);
    uint32_t depth[1]={20};
    assert(wasm_runtime_call_wasm(env,nested,1,depth) && depth[0]==21);
    wasm_function_inst_t wide=wasm_runtime_lookup_function(inst,"nih_probe_wide"); assert(wide);
    uint32_t halves[2]={0x89abcdef,0x01234567};
    assert(wasm_runtime_call_wasm(env,wide,2,halves) && halves[0]==0 && halves[1]==0);
    wasm_function_inst_t raw=wasm_runtime_lookup_function(inst,"nih_probe_raw_text"); assert(raw);
    uint32_t bad_range[2]={UINT32_MAX,4};
    assert(!wasm_runtime_call_wasm(env,raw,2,bad_range));
    assert(wasm_runtime_get_exception(inst));
    wasm_runtime_clear_exception(inst);
    wasm_function_inst_t bad_text=wasm_runtime_lookup_function(inst,"nih_probe_bad_text"); assert(bad_text);
    uint32_t bad_result[1]={0};
    assert(wasm_runtime_call_wasm(env,bad_text,0,bad_result) && (int32_t)bad_result[0]==-2);
    wasm_function_inst_t spin=wasm_runtime_lookup_function(inst,"nih_probe_spin"); assert(spin);
    wasm_runtime_set_instruction_count_limit(env,10000);
    assert(!wasm_runtime_call_wasm(env,spin,0,NULL));
    const char *exception=wasm_runtime_get_exception(inst);
    assert(exception && strstr(exception,"instruction limit exceeded"));
    wasm_runtime_clear_exception(inst);
    wasm_runtime_set_instruction_count_limit(env,-1);
    if (fixed_memory) {
        wasm_function_inst_t grow=wasm_runtime_lookup_function(inst,"nih_probe_grow"); assert(grow);
        uint32_t page_count[1]={1};
        assert(wasm_runtime_call_wasm(env,grow,1,page_count) && page_count[0]==UINT32_MAX);
        puts("WAMR fixed-memory growth rejection: ok");
    }
    uint64_t mem_start=0, mem_end=0;
    assert(wasm_runtime_get_app_addr_range(inst,0,&mem_start,&mem_end));
    printf("Wasm linear memory range=%llu..%llu bytes\n",(unsigned long long)mem_start,(unsigned long long)mem_end);
    mem_alloc_info_t info={0}; assert(wasm_runtime_get_mem_alloc_info(&info));
    printf("WAMR pool total=%u free=%u highmark=%u bytes\n",info.total_size,info.total_free_size,info.highmark_size);
    assert(text(env,8,8,UINT32_MAX,4,0xffffff)==-1);
    wasm_runtime_clear_exception(inst);
    assert(text(env,8,8,0,129,0xffffff)==-1);
#ifdef NIHOS_JOURNAL_ADMISSION
    owner.active = false;
    wasm_runtime_set_custom_data(inst, NULL);
#endif
    wasm_runtime_destroy_exec_env(env); wasm_runtime_deinstantiate(inst); wasm_runtime_unload(module);
    free(buf);
    /* Recreate fresh module/instance after a real invalid-memory trap and
       require that the global pool returns to its pre-load free count. */
    for (unsigned cycle=0; cycle<16; cycle++) {
#ifdef NIHOS_JOURNAL_ADMISSION
        uint32_t len=n; uint8_t *fresh=malloc(len); assert(fresh);
        memcpy(fresh, pristine, len);
#else
        uint32_t len=0; uint8_t *fresh=read_module(argv[1],&len); assert(fresh);
#endif
        wasm_module_t m=wasm_runtime_load(fresh,len,error,sizeof(error)); assert(m);
        wasm_module_inst_t i=wasm_runtime_instantiate(m,16384,0,error,sizeof(error)); assert(i);
#ifdef NIHOS_JOURNAL_ADMISSION
        struct import_owner cycle_owner = {i, services, true};
        wasm_runtime_set_custom_data(i, &cycle_owner);
#endif
        wasm_exec_env_t e=wasm_runtime_create_exec_env(i,16384); assert(e);
        wasm_function_inst_t f=wasm_runtime_lookup_function(i,"nih_probe_raw_text"); assert(f);
        uint32_t invalid[2]={UINT32_MAX,4};
        assert(!wasm_runtime_call_wasm(e,f,2,invalid));
        assert(wasm_runtime_get_exception(i));
#ifdef NIHOS_JOURNAL_ADMISSION
        cycle_owner.active = false;
        wasm_runtime_set_custom_data(i, NULL);
#endif
        wasm_runtime_destroy_exec_env(e); wasm_runtime_deinstantiate(i); wasm_runtime_unload(m);
        free(fresh);
        mem_alloc_info_t recovered={0}; assert(wasm_runtime_get_mem_alloc_info(&recovered));
        assert(recovered.total_free_size == baseline.total_free_size);
    }
    puts("WAMR 16 trap/destroy cycles returned runtime pool to baseline: ok");
#ifdef NIHOS_JOURNAL_ADMISSION
    free(pristine);
#endif
    wasm_runtime_destroy();
    puts("WAMR classic interpreter Rust app and bounds: ok");
    return 0;
}
