/* Compile-only placeholders. These types are not a nihos platform ABI and
 * must never be used to link or execute an application. */
#ifndef NIHOS_WAMR_COMPILE_PLATFORM_H
#define NIHOS_WAMR_COMPILE_PLATFORM_H
#include <stdint.h>
#include <inttypes.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stddef.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <ctype.h>
#include <errno.h>
#include <math.h>
#ifdef signbit
#undef signbit
#endif
#ifdef isnan
#undef isnan
#endif
int signbit(double value);
int isnan(double value);
#include <limits.h>
typedef uintptr_t korp_tid;
typedef uintptr_t korp_thread;
typedef uintptr_t korp_mutex;
typedef uintptr_t korp_cond;
typedef uintptr_t korp_rwlock;
typedef uintptr_t korp_sem;
typedef int os_file_handle;
typedef int os_raw_file_handle;
typedef void *os_dir_stream;
#define OS_THREAD_MUTEX_INITIALIZER 0
#define BH_THREAD_DEFAULT_PRIORITY 0
static inline int os_getpagesize(void) { return 4096; }
static inline os_file_handle os_get_invalid_handle(void) { return -1; }
#endif
