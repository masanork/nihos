/* Read-only, bounded OpenJPEG adapter; raw pixels never leave the device. */
#include "photo.h"
#include "openjpeg.h"
#include <string.h>
#include <limits.h>
#include <stdarg.h>
static struct { uint8_t *base; size_t bytes, used; int failed; } arena;
static void *allocate(size_t bytes) {
    if (!bytes || bytes > SIZE_MAX - 63) return NULL;
    const size_t span = (bytes + 63) & ~(size_t)31;
    if (arena.used > arena.bytes || span > arena.bytes - arena.used) return NULL;
    uint8_t *block = arena.base + arena.used;
    memcpy(block, &bytes, sizeof(bytes));
    arena.used += span;
    return block + 32;
}
void *opj_malloc(size_t bytes) { return allocate(bytes); }
void *opj_calloc(size_t count, size_t bytes) {
    if (!count || bytes > SIZE_MAX / count) return NULL;
    void *p=allocate(count*bytes); if (p) memset(p,0,count*bytes); return p;
}
void opj_free(void *p) { (void)p; }
void *opj_realloc(void *p, size_t bytes) {
    if (!p) return allocate(bytes);
    if (!bytes) return NULL;
    uintptr_t address=(uintptr_t)p, start=(uintptr_t)arena.base;
    if (address < start+32 || address > start+arena.used || (address & 31)) return NULL;
    size_t old;memcpy(&old,(uint8_t*)p-32,sizeof(old));
    if (old > start+arena.used-address) return NULL;
    void *next=allocate(bytes);if (next) memcpy(next,p,old<bytes?old:bytes);return next;
}
void *opj_aligned_malloc(size_t n){return opj_malloc(n);}
void *opj_aligned_32_malloc(size_t n){return opj_malloc(n);}
void *opj_aligned_realloc(void *p,size_t n){return opj_realloc(p,n);}
void *opj_aligned_32_realloc(void *p,size_t n){return opj_realloc(p,n);}
void opj_aligned_free(void *p){opj_free(p);}
int nih_photo_vsnprintf(char *s,size_t n,const char *f,va_list a){(void)f;(void)a;if(n)s[0]=0;return 0;}
static void event(const char *s,void *p){(void)s;(void)p;}
typedef struct {const uint8_t *data;size_t bytes,offset;} source;
static OPJ_SIZE_T read_bytes(void *p,OPJ_SIZE_T n,void *context){source *s=context;if(s->offset==s->bytes)return (OPJ_SIZE_T)-1;if(n>s->bytes-s->offset)n=s->bytes-s->offset;memcpy(p,s->data+s->offset,n);s->offset+=n;return n;}
static OPJ_OFF_T skip_bytes(OPJ_OFF_T n,void *context){source *s=context;if(n<0 || (uint64_t)n>s->bytes-s->offset)return -1;s->offset+=(size_t)n;return n;}
static OPJ_BOOL seek_bytes(OPJ_OFF_T n,void *context){source *s=context;if(n<0 || (uint64_t)n>s->bytes)return OPJ_FALSE;s->offset=(size_t)n;return OPJ_TRUE;}
static unsigned sample(const opj_image_comp_t *c,unsigned x,unsigned y){
    const unsigned xx=x<c->w?x:c->w-1, yy=y<c->h?y:c->h-1;
    int v=c->data[(size_t)yy*c->w+xx];if(c->sgnd)v+=1<<(c->prec-1);
    if(v<0)v=0;unsigned max=(1u<<c->prec)-1;if((unsigned)v>max)v=(int)max;return ((unsigned)v*255+max/2)/max;
}
int nih_photo_decode(const uint8_t *data,size_t length,uint8_t *pixels,size_t pixel_bytes,uint8_t *scratch,size_t scratch_bytes){
    if(pixels && pixel_bytes==96*128*2)memset(pixels,0,pixel_bytes);
    if(!data || length<16 || length>32768 || !pixels || pixel_bytes!=96*128*2 || !scratch || ((uintptr_t)scratch&31) || scratch_bytes<65536 || scratch_bytes>4*1024*1024)return 1;
    arena.base=scratch;arena.bytes=scratch_bytes;arena.used=0;arena.failed=0;
    OPJ_CODEC_FORMAT format=(data[0]==0xff && data[1]==0x4f)?OPJ_CODEC_J2K:OPJ_CODEC_JP2;
    opj_codec_t *codec=opj_create_decompress(format);opj_stream_t *stream=NULL;opj_image_t *image=NULL;int result=2;
    if(!codec)goto end;
    opj_set_info_handler(codec,event,NULL);opj_set_warning_handler(codec,event,NULL);opj_set_error_handler(codec,event,NULL);
    opj_dparameters_t *parameters=opj_malloc(sizeof(*parameters));if(!parameters)goto end;
    opj_set_default_decoder_parameters(parameters);parameters->cp_reduce=1;
    if(!opj_setup_decoder(codec,parameters))goto end;
    stream=opj_stream_create(1024,OPJ_TRUE);if(!stream)goto end;
    source input={data,length,0};opj_stream_set_user_data(stream,&input,NULL);opj_stream_set_user_data_length(stream,length);
    opj_stream_set_read_function(stream,read_bytes);opj_stream_set_skip_function(stream,skip_bytes);opj_stream_set_seek_function(stream,seek_bytes);
    if(!opj_read_header(stream,codec,&image) || !image)goto end;
    if(image->x1<=image->x0 || image->y1<=image->y0 || image->x1-image->x0>512 || image->y1-image->y0>640 || (image->numcomps!=1 && image->numcomps!=3))goto end;
    for(unsigned i=0;i<image->numcomps;++i)if(!image->comps[i].w || !image->comps[i].h || image->comps[i].prec<1 || image->comps[i].prec>8)goto end;
    if(!opj_decode(codec,stream,image) || !opj_end_decompress(codec,stream))goto end;
    for(unsigned i=0;i<image->numcomps;++i)if(!image->comps[i].data || !image->comps[i].w || !image->comps[i].h || image->comps[i].w>512 || image->comps[i].h>640)goto end;
    if(image->color_space!=OPJ_CLRSPC_SRGB && image->color_space!=OPJ_CLRSPC_GRAY && image->color_space!=OPJ_CLRSPC_UNSPECIFIED && image->color_space!=OPJ_CLRSPC_SYCC)goto end;
    unsigned width=96,height=image->comps[0].h*96/image->comps[0].w;
    if(height>128){height=128;width=image->comps[0].w*128/image->comps[0].h;}
    if(!width || !height)goto end;
    for(unsigned n=0;n<96*128;++n){pixels[n*2]=0xbd;pixels[n*2+1]=0xf7;}
    for(unsigned y=0;y<height;++y)for(unsigned x=0;x<width;++x){
        unsigned color[3];for(unsigned i=0;i<3;++i){const opj_image_comp_t *c=&image->comps[image->numcomps==1?0:i];color[i]=sample(c,x*c->w/width,y*c->h/height);}
        if(image->color_space==OPJ_CLRSPC_SYCC){
            /* Same conversion coefficients/truncation as upstream color.c. */
            int yy=(int)color[0],cb=(int)color[1]-128,cr=(int)color[2]-128;
            int rgb[3]={yy+(int)(1.402*(float)cr),yy-(int)(0.344*(float)cb+0.714*(float)cr),yy+(int)(1.772*(float)cb)};
            for(unsigned i=0;i<3;++i)color[i]=(unsigned)(rgb[i]<0?0:rgb[i]>255?255:rgb[i]);
        }
        uint16_t rgb=(uint16_t)(((color[0]>>3)<<11)|((color[1]>>2)<<5)|(color[2]>>3));size_t offset=((y+(128-height)/2)*96+x+(96-width)/2)*2;pixels[offset]=(uint8_t)rgb;pixels[offset+1]=(uint8_t)(rgb>>8);
    }
    if(arena.failed)goto end;
    result=0;
end:
    if(image)opj_image_destroy(image);if(stream)opj_stream_destroy(stream);if(codec)opj_destroy_codec(codec);
    if(result)memset(pixels,0,pixel_bytes);
    /* Caller erases the entire private arena before releasing its lease. */
    arena.base=NULL;arena.bytes=arena.used=0;return result;
}
/* Deterministic helpers for the decoder's two libm uses. */
double nih_photo_pow2(double base,double exponent){
    /* opj_tcd_init_tile only asks 2 raised to an integral precision/step. */
    if(base!=2.0 || exponent < -1022.0 || exponent > 1023.0){arena.failed=1;return 0.0;}
    int power=(int)exponent;if((double)power!=exponent){arena.failed=1;return 0.0;}
    uint64_t bits=(uint64_t)(power+1023)<<52;double result;memcpy(&result,&bits,8);return result;
}
long nih_photo_lrintf(float value){
    if(!(value < (float)LONG_MAX && value > (float)LONG_MIN)){arena.failed=1;return 0;}
    long truncated=(long)value;float fraction=value-(float)truncated;
    if(fraction>0.5f || (fraction==0.5f && (truncated&1)))++truncated;
    else if(fraction< -0.5f || (fraction== -0.5f && (truncated&1)))--truncated;
    return truncated;
}
static void exchange_bytes(uint8_t *a,uint8_t *b,size_t bytes){while(bytes--){uint8_t tmp=*a;*a++=*b;*b++=tmp;}}
static void sift(uint8_t *base,size_t root,size_t count,size_t bytes,int (*compare)(const void*,const void*)){
    while(root<count/2){size_t child=root*2+1;if(child+1<count && compare(base+child*bytes,base+(child+1)*bytes)<0)++child;if(compare(base+root*bytes,base+child*bytes)>=0)return;exchange_bytes(base+root*bytes,base+child*bytes,bytes);root=child;}
}
void nih_photo_qsort(void *data,size_t count,size_t bytes,int (*compare)(const void*,const void*)){
    if(count<2 || !bytes || count>SIZE_MAX/bytes)return;
    uint8_t *base=data;for(size_t i=count/2;i;i--)sift(base,i-1,count,bytes,compare);
    for(size_t end=count-1;end;--end){exchange_bytes(base,base+end*bytes,bytes);sift(base,0,end,bytes,compare);}
}
