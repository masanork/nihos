/* Experimental single-owner WAMR platform model.  This is compiled for the
 * RV32 boundary inventory but is not a nihos kernel integration. */
#include "platform_api_vmcore.h"
#include "platform_api_extension.h"

/* The future runtime owner must provide a monotonic clock and the low address
 * of the current native stack.  Returning a fabricated boundary is unsafe. */
extern uint64_t nih_wamr_monotonic_us(void);
extern uint8_t *nih_wamr_stack_boundary(void);

int bh_platform_init(void) { return BHT_OK; }
void bh_platform_destroy(void) {}

/* WAMR is required to use Alloc_With_Allocator in this configuration. */
void *os_malloc(unsigned size) { (void)size; return NULL; }
void *os_realloc(void *ptr, unsigned size) { (void)ptr; (void)size; return NULL; }
void os_free(void *ptr) { (void)ptr; }

int os_vprintf(const char *format, va_list ap) { (void)format; (void)ap; return 0; }
int os_printf(const char *format, ...) { (void)format; return 0; }
int os_dumps_proc_mem_info(char *out, unsigned int size) { (void)out; (void)size; return BHT_ERROR; }

uint64 os_time_get_boot_us(void) { return nih_wamr_monotonic_us(); }
uint64 os_time_thread_cputime_us(void) { return nih_wamr_monotonic_us(); }
korp_tid os_self_thread(void) { return (korp_tid)1; }
uint8 *os_thread_get_stack_boundary(void) { return nih_wamr_stack_boundary(); }
void os_thread_jit_write_protect_np(bool enabled) { (void)enabled; }

/* This model is intentionally non-recursive and non-concurrent.  A repeated
 * lock is an error rather than a silent no-op, preserving the combined-init
 * deadlock counterexample as a visible contract violation. */
int os_mutex_init(korp_mutex *mutex) {
    if (!mutex) return BHT_ERROR;
    *mutex = 0;
    return BHT_OK;
}
int os_mutex_destroy(korp_mutex *mutex) {
    return mutex && *mutex == 0 ? BHT_OK : BHT_ERROR;
}
int os_mutex_lock(korp_mutex *mutex) {
    if (!mutex || *mutex != 0) return BHT_ERROR;
    *mutex = 1;
    return BHT_OK;
}
int os_mutex_unlock(korp_mutex *mutex) {
    if (!mutex || *mutex != 1) return BHT_ERROR;
    *mutex = 0;
    return BHT_OK;
}

/* Threads are disabled.  Only construction/destruction of otherwise-unused
 * condition fields is reachable in the selected classic configuration. */
int os_cond_init(korp_cond *cond) {
    if (!cond) return BHT_ERROR;
    *cond = 0;
    return BHT_OK;
}
int os_cond_destroy(korp_cond *cond) {
    return cond && *cond == 0 ? BHT_OK : BHT_ERROR;
}
