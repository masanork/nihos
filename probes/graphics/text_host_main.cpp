#include "link_oracle.h"
#include "text_cases.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
alignas(64) static unsigned char heap[15596992];
static uint32_t hashes[5], runs[5];
static GraphicsOutput outputs[5];
extern "C" uint32_t nih_graphics_next_request(uint32_t completed, uint32_t retained, GraphicsJob *job) {
    if(retained!=65792 || completed>9)abort();
    if(completed>=5) {
        runs[completed-5]=graphics_result.runs;
        hashes[completed-5]=graphics_result.hashes[0];
        outputs[completed-5]=graphics_output;
        memset(&graphics_output,0xa5,sizeof(graphics_output));
        if(graphics_result.runs>1 || (!graphics_result.runs && graphics_result.hashes[0]))abort();
    }
    if(completed==9)return 0;
    *job={};job->operation=completed<4?0u:1u;
    if(completed>=4)job->render=text_cases[completed-4];
    return completed+1;
}
int main(int argc,char **argv) {
    if(argc!=3)return 2;
    GraphicsInputs input={};input.heap=heap;input.heap_bytes=sizeof(heap);input.load_mode=1;
    for(unsigned i=0;i<2;i++) {
        FILE *f=fopen(argv[i+1],"rb");if(!f)return 3;
        fseek(f,0,SEEK_END);long n=ftell(f);if(n<=0 || (unsigned long)n>UINT32_MAX)return 4;rewind(f);
        unsigned char *p=(unsigned char*)malloc((size_t)n);if(!p)return 5;
        if(fread(p,1,(size_t)n,f)!=(size_t)n)return 6;fclose(f);
        input.fonts[i]=p;input.lengths[i]=(uint32_t)n;
    }
    int rc=graphics_font_link_probe(&input);
    printf("{\"rc\":%d,\"matrix_hashes\":[",rc);
    for(unsigned i=0;i<16;i++)printf("%s%u",i?",":"",graphics_result.hashes[i]);
    printf("],\"texts\":[");
    for(unsigned i=0;i<5;i++) {
        const GraphicsOutput &o=outputs[i];
        printf("%s{\"id\":%u,\"runs\":%u,\"hash\":%u,\"outcome\":%u,\"glyph_count\":%u,\"glyphs\":[",i?",":"",i+5,runs[i],hashes[i],o.outcome,o.count);
        if(o.count>16 || (o.outcome && (o.count || memcmp(o.glyphs,GraphicsOutput{}.glyphs,sizeof(o.glyphs)))))abort();
        for(unsigned n=0;n<o.count;n++) {
            const GraphicsGlyph &g=o.glyphs[n];
            printf("%s{\"glyph_id\":%u,\"cluster\":%u,\"run\":%u,\"pixels\":%u,\"x_advance\":%d,\"y_advance\":%d,\"x_offset\":%d,\"y_offset\":%d,\"left\":%d,\"top\":%d,\"width\":%u,\"height\":%u}",n?",":"",g.id,g.cluster,g.run,g.pixels,g.x_advance,g.y_advance,g.x_offset,g.y_offset,g.left,g.top,g.width,g.height);
        }
        printf("]}");
    }
    printf("],\"raw_peak\":%u,\"retained\":%u}\n",graphics_result.raw_peak,graphics_result.retained);
    free((void*)input.fonts[0]);free((void*)input.fonts[1]);return rc;
}
