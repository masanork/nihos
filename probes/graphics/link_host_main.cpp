#include "link_oracle.h"
#include <stdio.h>
#include <stdlib.h>
alignas(64) static unsigned char heap[15596992];
int main(int argc,char**argv) {
    if(argc!=3)return 2;
    GraphicsInputs input={};input.heap=heap;input.heap_bytes=sizeof(heap);
    for(unsigned i=0;i<2;i++) {
        FILE*f=fopen(argv[i+1],"rb");if(!f)return 3;
        fseek(f,0,SEEK_END);long n=ftell(f);if(n<=0)return 4;rewind(f);
        unsigned char*p=(unsigned char*)malloc((size_t)n);if(!p)return 5;
        if(fread(p,1,(size_t)n,f)!=(size_t)n)return 6;fclose(f);
        input.fonts[i]=p;input.lengths[i]=(uint32_t)n;
    }
    int result=graphics_font_link_probe(&input);
    printf("{\"rc\":%d,\"stage\":%u,\"runs\":%u,\"pool_peak\":%u,\"raw_peak\":%u,\"retained\":%u,\"hashes\":[",result,graphics_result.stage,graphics_result.runs,graphics_result.pool_peak,graphics_result.raw_peak,graphics_result.retained);
    for(unsigned i=0;i<graphics_result.runs;i++)printf("%s%u",i?",":"",graphics_result.hashes[i]);
    printf("]}\n");free((void*)input.fonts[0]);free((void*)input.fonts[1]);return result;
}
