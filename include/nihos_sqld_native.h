#ifndef NIHOS_SQLD_NATIVE_H
#define NIHOS_SQLD_NATIVE_H
#include "nihos_sqld.h"
/* Native platform owns all backing until task exit AND I/O quiescence.
 * These are trusted kernel entry points, never Scheme-visible pointers. */
int nih_sqld_native_allocator(void *, uint32_t);
void nih_sqld_native_prepare(uint32_t principal, uint32_t owner);
int32_t nih_sqld_native_task(uint32_t);
void nih_sqld_native_poll(void);
int32_t nih_sqld_native_status(void);
#endif
