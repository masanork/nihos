#!/usr/bin/env python3
"""Adapt the tested Session to a memory-backed stream; keep one source of draw logic."""
from pathlib import Path
import hashlib
import sys
import subprocess

root = Path(__file__).resolve().parent
source = (root / "font_probe.cpp").read_text()
session = source[source.index("struct Session {"):source.index("\nstatic bool trial(")]
session = session.replace("FILE *file = nullptr;", "const unsigned char *input = nullptr;")
start = session.index("    bool open(const char *path) {")
end = session.index("        cache =", start)
session = session[:start] + """    bool openMemory(const unsigned char *data, uint32_t size) {
        input = data; length = size;
""" + session[end:]
old = """                if (fseek(s->file, (long)s->base[slot], SEEK_SET)) return done;
                if (fread(s->cache + slot * page, 1, n, s->file) != n) return done;"""
assert session.count(old) == 1
session = session.replace(old, "                memcpy(s->cache + slot * page, s->input + s->base[slot], n);")
session = session.replace("                s->valid[slot] = n;", """#ifdef PROBE_TASK_ORACLE
                graphics_source_read_completed();
#endif
                s->valid[slot] = n;""")
session = session.replace("        if (file) { fclose(file); file = nullptr; }", "        input = nullptr;")
assert "FILE" not in session and "fread" not in session and "fopen" not in session
session = session.replace('bool draw(bool vertical, unsigned pixels, uint32_t *hash_out)',
                          'bool draw(bool vertical, unsigned pixels, uint32_t *hash_out, const GraphicsRender *request = nullptr)')
session = session.replace('ruby < 2;', 'ruby < (request && !request->ruby_length ? 1u : 2u);')
needle = '            hb_buffer_add_utf8(buffer, ruby ?'
start = session.index(needle)
end = session.index('            hb_buffer_set_direction', start)
original = session[start:end]
session = session[:start] + """            if(request) {
                const char *text = ruby ? request->ruby : request->body;
                int length = (int)(ruby ? request->ruby_length : request->body_length);
                hb_buffer_add_utf8(buffer,text,length,0,length);
            } else {
""" + original + "            }\n" + session[end:]
prefix = r'''
#include "lazy_pool.h"
#include "buddy_backing.h"
#include "link_oracle.h"
#include <ft2build.h>
#include FT_FREETYPE_H
#include FT_MODULE_H
#include FT_SYSTEM_H
#include <hb.h>
#include <hb-ft.h>
#include <string.h>
#ifdef PROBE_TASK_ORACLE
extern "C" void graphics_source_read_completed();
#endif
static LazyPool pool;
static bool backing_ready;
extern "C" { GraphicsResult graphics_result = {}; }
#ifdef PROBE_NATIVE_OBJECT
extern "C" { uint32_t graphics_execution_pc = 0; }
#endif
#if defined(PROBE_NATIVE_OBJECT) || defined(PROBE_TEXT_ORACLE)
#define PROBE_REQUEST_ORACLE 1
extern "C" uint32_t nih_graphics_next_request(uint32_t completed, uint32_t retained, GraphicsJob *job);
#endif
static void check(bool good, const char *where) {
    (void)where;
    if (!good) { graphics_result.failure = 1; __builtin_trap(); }
}
extern "C" void graphics_unavailable(unsigned kind) {
    graphics_result.unavailable_calls += 1; graphics_result.failure = 100 + kind;
}
extern "C" void graphics_backing_ensure() { check(backing_ready, "backing not initialized"); }
extern "C" void* study_malloc(size_t n) { return pool.allocate(0,n); }
extern "C" void* study_calloc(size_t n,size_t bytes) {
    if(bytes && n>SIZE_MAX/bytes)return nullptr;
    void*p=study_malloc(n*bytes);if(p)memset(p,0,n*bytes);return p;
}
extern "C" void* study_realloc(void*p,size_t n) { return pool.resize(0,p,n); }
extern "C" void study_free(void*p) { check(pool.release(0,p),"HB release"); }
#ifdef PROBE_RV32
#include <reent.h>
static struct _reent oracle_reent = _REENT_INIT(oracle_reent);
extern "C" struct _reent* __getreent() { return &oracle_reent; }
extern "C" void* malloc(size_t n) { graphics_result.runtime_malloc_calls++;return study_malloc(n); }
extern "C" void* calloc(size_t n,size_t bytes) { graphics_result.runtime_malloc_calls++;return study_calloc(n,bytes); }
extern "C" void* realloc(void*p,size_t n) { graphics_result.runtime_malloc_calls++;return study_realloc(p,n); }
extern "C" void free(void*p) { study_free(p); }
extern "C" void* _malloc_r(struct _reent*,size_t n) { return malloc(n); }
extern "C" void* _calloc_r(struct _reent*,size_t n,size_t bytes) { return calloc(n,bytes); }
extern "C" void* _realloc_r(struct _reent*,void*p,size_t n) { return realloc(p,n); }
extern "C" void _free_r(struct _reent*,void*p) { free(p); }
extern "C" [[noreturn]] void abort() { graphics_result.failure=2;__builtin_trap(); }
#endif
'''
suffix = r'''
extern "C" int graphics_font_link_probe(const GraphicsInputs *inputs) {
#ifdef PROBE_NATIVE_OBJECT
    asm volatile("auipc %0, 0" : "=r"(graphics_execution_pc));
#endif
    graphics_result.magic=0x47524658;graphics_result.stage=1;
    check(!backing_ready && pool.reserved==0,"fresh invocation");
    check(nih_graphics_backing_init(inputs->heap,inputs->heap_bytes)==0,"heap init");
    backing_ready=true;
    hb_language_from_string("ja",-1);
    check(inputs->load_mode<=2,"load mode");
#ifdef PROBE_REQUEST_ORACLE
    uint32_t expected[16]={};
    unsigned matrices=0;
#endif
    bool success=true;
    for(unsigned cycle=0;;cycle++) {
        bool text=false;
        unsigned mode=inputs->load_mode;
        GraphicsJob job={};
#ifdef PROBE_REQUEST_ORACLE
        graphics_result.stage=50;
        uint32_t request=nih_graphics_next_request(cycle,(uint32_t)nih_graphics_backing_raw_used(),&job);
        if(request==0) {
            check(cycle==8 && matrices==4,"stop after requested work");
            memcpy(graphics_result.hashes,expected,sizeof(expected));graphics_result.runs=16;
            success=true;break;
        }
        check(request==cycle+1 && cycle<8 && job.operation<=1,"ordered request");
        text=job.operation==1;success=true;
        if(text)mode=job.render.hinting;
#else
        if(cycle==1)break;
#endif
        FT_Int32 flags=FT_LOAD_NO_BITMAP;
        if(mode==1)flags|=FT_LOAD_FORCE_AUTOHINT;
        if(mode==2)flags|=FT_LOAD_NO_HINTING|FT_LOAD_NO_AUTOHINT;
        pool.begin_operation();
        graphics_result.runs=0;memset(graphics_result.hashes,0,sizeof(graphics_result.hashes));
        Session first(1,flags),second(2,flags);
        if(text) {
            Session &target=job.render.font?second:first;
            graphics_result.stage=2;
            success=target.openMemory(inputs->fonts[job.render.font],inputs->lengths[job.render.font]);
            uint32_t hash=0;
            graphics_result.stage=10;
            success=success && target.draw(job.render.vertical!=0,job.render.pixels,&hash,&job.render);
            if(success) { graphics_result.runs=1;graphics_result.hashes[0]=hash; }
        } else {
            graphics_result.stage=2;check(first.openMemory(inputs->fonts[0],inputs->lengths[0]),"gothic open");
            graphics_result.stage=3;check(second.openMemory(inputs->fonts[1],inputs->lengths[1]),"mincho open");
            const unsigned sizes[]={12,16,24,32};
            for(unsigned size:sizes)for(unsigned v=0;v<2;v++)for(unsigned family=0;family<2;family++) {
                if(!success)continue;
                graphics_result.stage=10+graphics_result.runs;
                uint32_t hash=0;
                success=(family?second:first).draw(v!=0,size,&hash);
                if(success)graphics_result.hashes[graphics_result.runs++]=hash;
            }
        }
        second.close();first.close();
        check(pool.valid() && pool.owner_reserved[1]==0 && pool.owner_reserved[2]==0,"client recovery");
#ifdef PROBE_REQUEST_ORACLE
        if(!text) {
            check(success && graphics_result.runs==16,"complete matrix");
            for(unsigned i=0;i<16;i++) {
                if(matrices==0)expected[i]=graphics_result.hashes[i];
                else check(expected[i]==graphics_result.hashes[i],"reopened clients unchanged");
            }
            matrices++;
        }
#endif
        if(pool.peak>graphics_result.pool_peak)graphics_result.pool_peak=(uint32_t)pool.peak;
        if(pool.peak_records>graphics_result.record_peak)graphics_result.record_peak=(uint32_t)pool.peak_records;
    }
    graphics_result.raw_peak=(uint32_t)nih_graphics_backing_raw_peak();
    graphics_result.retained=(uint32_t)nih_graphics_backing_raw_used();
    graphics_result.largest_extent=(uint32_t)nih_graphics_backing_largest_extent();
    graphics_result.controller_bytes=sizeof(pool);
    graphics_result.record_capacity=LazyPool::record_count;
    graphics_result.record_failures=(uint32_t)pool.record_failures;
    graphics_result.allocation_failures=(uint32_t)pool.failures;
    check(!graphics_result.unavailable_calls,"no unsupported runtime path");
    graphics_result.stage=success?100:90;return success?0:20;
}
'''

out = Path(sys.argv[1]); out.mkdir(parents=True, exist_ok=True)
text = "// Generated from font_probe.cpp SHA256 " + hashlib.sha256(source.encode()).hexdigest() + "\n" + prefix + session + suffix
path = out / "link_oracle.cpp"
if not path.exists() or path.read_text() != text:
    path.write_text(text)

subprocess.run([sys.executable, str(root / "generate_text_cases.py"), "--header", str(out / "text_cases.h")], check=True)
