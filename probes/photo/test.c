#include "photo.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
static uint8_t *load(const char *path,size_t *length){FILE *f=fopen(path,"rb");if(!f)return NULL;if(fseek(f,0,SEEK_END)){fclose(f);return NULL;}long size=ftell(f);rewind(f);if(size<=0){fclose(f);return NULL;}uint8_t *p=malloc((size_t)size);if(!p){fclose(f);return NULL;}*length=(size_t)size;if(fread(p,1,*length,f)!=*length){free(p);fclose(f);return NULL;}fclose(f);return p;}
int main(int argc,char **argv){
    if(argc!=3)return 1;size_t size,expected_size;uint8_t *data=load(argv[1],&size),*expected=load(argv[2],&expected_size);
    if(!data || !expected || expected_size!=96*128*2)return 2;
    uint8_t *raw=malloc(4*1024*1024+96);uint8_t *work=(uint8_t*)(((uintptr_t)raw+31)&~(uintptr_t)31);
    uint8_t output[96*128*2+128];memset(output,0xa5,sizeof(output));memset(work,0xa5,4*1024*1024+32);
    int result=nih_photo_decode(data,size,output+64,96*128*2,work,4*1024*1024);
    if(result || memcmp(output+64,expected,expected_size))return 3;
    for(size_t i=0;i<64;++i)if(output[i]!=0xa5 || output[64+expected_size+i]!=0xa5)return 4;
    for(size_t i=0;i<32;++i)if(work[4*1024*1024+i]!=0xa5)return 5;
    size_t ends[]={0,1,8,16,size/2};
    for(size_t i=0;i<sizeof(ends)/sizeof(ends[0]);++i){
        memset(output+64,0xa5,expected_size);
        if(nih_photo_decode(data,ends[i],output+64,expected_size,work,4*1024*1024)==0)return 6;
        for(size_t j=0;j<expected_size;++j)if(output[64+j])return 7;
    }
    if(nih_photo_decode(data,size,output+64,expected_size,work,65536)==0)return 8;
    free(data);free(expected);free(raw);puts("Synthetic JP2/J2K exact RGB565 reference, truncation, quota and guards passed");return 0;
}
