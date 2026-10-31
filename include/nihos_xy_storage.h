#ifndef NIHOS_XY_STORAGE_H
#define NIHOS_XY_STORAGE_H
#include <stdint.h>
/* Return encoded-data length or a negative service error. No truncated result. */
typedef int32_t (*XyStorageCallback)(void *,uint32_t,uint32_t,uint32_t,uint32_t,
 const uint8_t *,uint32_t,const uint8_t *,uint32_t,uint8_t *,uint32_t);
void xy_host_set_storage_callback(void *,XyStorageCallback);
void *nih_sqld_host_open(const char *,int create);
int nih_sqld_host_close(void *);
int32_t nih_sqld_host_xy(void *,uint32_t,uint32_t,uint32_t,uint32_t,
 const uint8_t *,uint32_t,const uint8_t *,uint32_t,uint8_t *,uint32_t);
#endif
