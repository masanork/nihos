/* System headers are parsed before disabling optional diagnostics/environment.
 * These overrides are part of the pinned decode-only build profile. */
#include <stdlib.h>
#include <stdio.h>
#include <math.h>
#include <limits.h>
static inline int nih_photo_blank(char *s,size_t n){if(n)s[0]=0;return 0;}
static inline int nih_photo_abs(int v){return v==INT_MIN?INT_MAX:(v<0?-v:v);}
double nih_photo_pow2(double,double);
long nih_photo_lrintf(float);
void nih_photo_qsort(void *,size_t,size_t,int(*)(const void*,const void*));
#define getenv(n) ((char*)0)
#define fprintf(...) 0
#undef snprintf
#define snprintf(s,n,...) nih_photo_blank(s,n)
#undef vsnprintf
#define vsnprintf(s,n,...) nih_photo_blank(s,n)
#define abs(v) nih_photo_abs(v)
#define pow(x,y) nih_photo_pow2(x,y)
#define lrintf(v) nih_photo_lrintf(v)
#define qsort(p,n,s,c) nih_photo_qsort(p,n,s,c)
