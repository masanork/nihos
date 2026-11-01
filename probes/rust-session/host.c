/* Real native/WAMR rendering through the same serialized OS session. */
#include "nihos_app_session.h"
#include "nihos_app_probe.h"
#include "wasm_export.h"
#include <assert.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef NDEBUG
#error "Assertions required"
#endif
enum { LEASE=32768, PIXELS=25600, SCANOUT=720*1280*2 };
extern int32_t nih_rust_app_frame(uint32_t);
extern int nih_boot_buffer_admit(const uint8_t *, size_t, const uint8_t *, size_t,
    const uint8_t *, size_t, const uint8_t *, size_t, uint32_t,
    uint8_t *, size_t, uint32_t *, uint32_t *);
void rust_eh_personality(void) {}
struct context {
    struct nih_app_session *session;
    bool wasm, active, scope, engine;
    int fault;
    unsigned leases, releases, opened, closed, presented, heartbeats;
    uint8_t *lease, *pool;
    uint8_t admitted[4096], module_bytes[4096];
    uint32_t length, services;
    wasm_module_t module;
    wasm_module_inst_t instance;
    wasm_exec_env_t env;
};
static uint8_t scanout[SCANOUT];
static uint32_t native_hashes[4], wasm_hashes[4];
static bool allowed(wasm_exec_env_t env) {
    wasm_module_inst_t instance=wasm_runtime_get_module_inst(env);
    struct context *c=wasm_runtime_get_custom_data(instance);
    return c && c->instance==instance && c->active && c->scope && (c->services&1);
}
static int32_t rect(wasm_exec_env_t env,int32_t x,int32_t y,uint32_t w,uint32_t h,uint32_t rgb) {
    if (!allowed(env)) return -5;
    return nih_app_fill_rect(x,y,w,h,rgb);
}
static int32_t text(wasm_exec_env_t env,int32_t x,int32_t y,uint32_t offset,uint32_t len,uint32_t rgb) {
    if (!allowed(env)) return -5;
    wasm_module_inst_t instance=wasm_runtime_get_module_inst(env);
    if (!wasm_runtime_validate_app_addr(instance,offset,len)) return -1;
    const uint8_t *p=wasm_runtime_addr_app_to_native(instance,offset);
    if (!p && len) return -1;
    return nih_app_text(x,y,p,len,rgb);
}
static NativeSymbol imports[]={
    {"nih_app_fill_rect",(void *)rect,"(iiiii)i",NULL},
    {"nih_app_text",(void *)text,"(iiiii)i",NULL}
};
static int32_t acquire(void *p,uint8_t **bytes,uint32_t *len) {
    struct context *c=p;
    assert(!c->lease);
    if (c->fault==1) return -40;
    c->lease=malloc(LEASE); assert(c->lease);
    *bytes=c->lease; *len=LEASE; c->leases++;
    return 0;
}
static int32_t open_backend(void *p) {
    struct context *c=p;
    c->opened++;
    if (c->fault==2) return -41;
    if (c->wasm) {
        RuntimeInitArgs init={0}; char error[128];
        c->pool=calloc(1,262144); assert(c->pool);
        init.mem_alloc_type=Alloc_With_Pool;
        init.mem_alloc_option.pool.heap_buf=c->pool;
        init.mem_alloc_option.pool.heap_size=262144;
        c->engine=wasm_runtime_full_init(&init); if (!c->engine) return -42;
        if (!wasm_runtime_register_natives("nihos",imports,2)) return -43;
        memcpy(c->module_bytes,c->admitted,c->length);
        c->module=wasm_runtime_load(c->module_bytes,c->length,error,sizeof(error));
        if (!c->module) return -44;
        c->instance=wasm_runtime_instantiate(c->module,16384,0,error,sizeof(error));
        if (!c->instance) return -45;
        wasm_runtime_set_custom_data(c->instance,c);
        c->env=wasm_runtime_create_exec_env(c->instance,16384);
        if (!c->env) return -46;
    }
    c->active=true;
    return 0;
}
static int32_t render(void *p,uint32_t selected,uint8_t *pixels,uint32_t len) {
    struct context *c=p;
    assert(c->active && !c->scope && len==PIXELS);
    /* Reentrant input and cancellation must leave the in-flight frame alone. */
    assert(nih_app_session_input(c->session,'1')==-3);
    assert(nih_app_session_cancel(c->session)==-3);
    if (c->fault==3) return -47;
    assert(nih_app_probe_attach(pixels,len,160,80,320)==0);
    int32_t result;
    c->scope=true;
    if (c->wasm) {
        uint32_t args[1]={selected};
        const char *name=c->fault==6?"nih_probe_spin":"nih_rust_app_frame";
        wasm_function_inst_t function=wasm_runtime_lookup_function(c->instance,name);
        assert(function);
        wasm_runtime_set_instruction_count_limit(c->env,10000);
        bool ok=wasm_runtime_call_wasm(c->env,function,c->fault==6?0:1,args);
        result=ok?(int32_t)args[0]:-48;
    } else result=nih_rust_app_frame(selected);
    c->scope=false;
    nih_app_probe_detach();
    if (c->fault==5) pixels[len]=0; /* Deliberate end-guard corruption. */
    return result;
}
static uint32_t hash(const uint8_t *p,size_t n) {
    uint32_t h=2166136261u;
    for (size_t i=0;i<n;i++) h=(h^p[i])*16777619u;
    return h;
}
static void golden(const uint8_t *pixels,bool pressed) {
    static const uint8_t ready[5][8]={
        {0x3f,0x66,0x66,0x3e,0x36,0x66,0x67,0},
        {0,0,0x1e,0x33,0x3f,0x03,0x1e,0}, {0,0,0x1e,0x30,0x3e,0x33,0x6e,0},
        {0x38,0x30,0x30,0x3e,0x33,0x33,0x6e,0}, {0,0,0x33,0x33,0x33,0x3e,0x30,0x1f}};
    static const uint8_t selected[7][8]={
        {0x3f,0x66,0x66,0x3e,0x06,0x06,0x0f,0}, {0,0,0x3b,0x6e,0x66,0x06,0x0f,0},
        {0,0,0x1e,0x33,0x3f,0x03,0x1e,0}, {0,0,0x3e,0x03,0x1e,0x30,0x1f,0},
        {0,0,0x3e,0x03,0x1e,0x30,0x1f,0}, {0,0,0x1e,0x33,0x3f,0x03,0x1e,0},
        {0x38,0x30,0x30,0x3e,0x33,0x33,0x6e,0}};
    const uint8_t (*glyphs)[8]=pressed?selected:ready;
    for (unsigned y=0;y<80;y++) for (unsigned x=0;x<160;x++) {
        uint16_t expected=pressed?0x220c:0x1082;
        if (y>=8 && y<16 && x>=8 && (x-8)/8<(pressed?7u:5u) &&
            (glyphs[(x-8)/8][y-8]&(1u<<((x-8)%8)))) expected=0xffff;
        size_t i=(y*160+x)*2;
        assert(pixels[i]==(uint8_t)expected && pixels[i+1]==(uint8_t)(expected>>8));
    }
}
static int32_t present(void *p,const uint8_t *pixels,uint32_t len) {
    struct context *c=p;
    assert(c->active && !c->scope && len==PIXELS);
    if (c->fault==4) return -49;
    golden(pixels,pixels[0]==0x0c);
    assert(nih_app_present_copy(scanout,SCANOUT,pixels,len)==0);
    /* Check every physical pixel, including the region outside the app. */
    for (unsigned y=0;y<1280;y++) for (unsigned x=0;x<720;x++) {
        size_t i=(y*720+x)*2;
        if (y>=1104 && y<1264 && x>=16 && x<96) {
            size_t s=((x-16)*160+1279-y-16)*2;
            assert(scanout[i]==pixels[s] && scanout[i+1]==pixels[s+1]);
        } else assert(scanout[i]==0xa5 && scanout[i+1]==0xa5);
    }
    if (!c->fault && c->presented<4)
        (c->wasm?wasm_hashes:native_hashes)[c->presented]=hash(scanout,SCANOUT);
    c->presented++;
    return 0;
}
static int32_t close_backend(void *p) {
    struct context *c=p;
    c->active=false; c->scope=false;
    if (c->env) wasm_runtime_destroy_exec_env(c->env);
    if (c->instance) {
        wasm_runtime_set_custom_data(c->instance,NULL);
        wasm_runtime_deinstantiate(c->instance);
    }
    if (c->module) wasm_runtime_unload(c->module);
    if (c->engine) wasm_runtime_destroy();
    c->env=NULL; c->instance=NULL; c->module=NULL; c->engine=false;
    if (c->pool) { memset(c->pool,0,262144); free(c->pool); c->pool=NULL; }
    memset(c->module_bytes,0,sizeof(c->module_bytes));
    c->closed++;
    return 0;
}
static int32_t release(void *p,uint8_t *bytes,uint32_t len) {
    struct context *c=p;
    assert(!c->active && !c->scope && !c->engine && !c->pool);
    assert(c->lease==bytes && len==LEASE);
    for (unsigned i=0;i<len;i++) assert(bytes[i]==0);
    assert(nih_app_fill_rect(0,0,1,1,0)==-3);
    free(bytes); c->lease=NULL; c->releases++;
    return 0;
}
static void cycle(struct context *c) {
    struct nih_app_session s={.hooks={c,acquire,open_backend,render,present,close_backend,release}};
    c->session=&s; c->presented=0;
    memset(scanout,0xa5,sizeof(scanout));
    assert(nih_app_session_start(&s)==0 && s.frames==1);
    if (c->wasm) {
        assert(rect(c->env,0,0,160,80,0)==-5);
        assert(text(c->env,8,8,UINT32_MAX,4,0xffffff)==-5);
        assert(!wasm_runtime_get_exception(c->instance));
    }
    assert(nih_app_session_start(&s)==-3);
    assert(nih_app_session_input(&s,'0')==0);
    uint32_t prior=hash(scanout,SCANOUT);
    assert(nih_app_session_input(&s,'x')==-1 && hash(scanout,SCANOUT)==prior);
    assert(nih_app_session_input(&s,'1')==0);
    assert(nih_app_session_input(&s,'0')==0 && s.frames==4);
    assert(nih_app_session_input(&s,'q')==0 && s.state==NIH_APP_STOPPED);
    assert(!s.storage && !c->lease && c->leases==c->releases);
    assert(nih_app_session_input(&s,'1')==-5);
    assert(nih_app_session_cancel(&s)==0);
    assert(nih_app_session_start(&s)==0);
    assert(nih_app_session_cancel(&s)==0 && c->leases==c->releases);
    for (int fault=1;fault<=6;fault++) {
        if (fault==6 && !c->wasm) continue;
        c->fault=fault;
        assert(nih_app_session_start(&s)<0 && s.state==NIH_APP_FAILED);
        assert(!s.storage && !c->active && c->leases==c->releases);
        assert(nih_app_session_input(&s,'0')==-5);
        assert(c->opened==c->closed);
    }
    c->fault=0;
    assert(nih_app_session_start(&s)==0);
    prior=hash(scanout,SCANOUT);
    c->fault=c->wasm?6:3;
    assert(nih_app_session_input(&s,'1')<0 && s.state==NIH_APP_FAILED);
    assert(hash(scanout,SCANOUT)==prior && !s.storage && !c->lease);
    c->fault=0;
    assert(nih_app_session_start(&s)==0);
    c->heartbeats++; /* A foreground turn between input frames, with no app call. */
    assert(nih_app_session_cancel(&s)==0);
    assert(c->opened==c->closed && c->leases==c->releases);
}
static uint8_t *read_file(const char *name,size_t *len) {
    FILE *f=fopen(name,"rb"); assert(f);
    assert(fseek(f,0,SEEK_END)==0); long n=ftell(f);
    assert(n>0 && n<=65536 && fseek(f,0,SEEK_SET)==0);
    uint8_t *p=malloc((size_t)n); assert(p && fread(p,1,(size_t)n,f)==(size_t)n);
    fclose(f); *len=(size_t)n; return p;
}
int main(int argc,char **argv) {
    assert(argc==5);
    struct context native={0},wasm={.wasm=true};
    uint8_t *media[4]; size_t sizes[4];
    for (int i=0;i<4;i++) media[i]=read_file(argv[i+1],&sizes[i]);
    assert(nih_boot_buffer_admit(media[0],sizes[0],media[1],sizes[1],media[2],sizes[2],
        media[3],sizes[3],1,wasm.admitted,sizeof(wasm.admitted),&wasm.length,&wasm.services)==0);
    for (int i=0;i<4;i++) free(media[i]);
    assert(wasm.services==1);
    cycle(&native); cycle(&wasm);
    /* Only the first four presentations are compared; later cases test cleanup. */
    assert(memcmp(native_hashes,wasm_hashes,sizeof(native_hashes))==0);
    printf("NIHOS_APP_SESSION parity=1 pixels=12800 scanout=921600 quit=1 cancel=1 restart=1 start_faults=11 active_faults=2 reentry=1 wiped=1 detached=1 leases_native=%u leases_wasm=%u\n",native.leases,wasm.leases);
    return 0;
}
