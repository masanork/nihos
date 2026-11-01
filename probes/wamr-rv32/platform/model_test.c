#include "platform_api_vmcore.h"
#include "platform_api_extension.h"
#include <assert.h>
#include <stdint.h>

static uint8_t stack_low;
uint64_t nih_wamr_monotonic_us(void) { return 1234567; }
uint8_t *nih_wamr_stack_boundary(void) { return &stack_low; }

int main(void) {
    korp_mutex mutex;
    korp_cond cond;
    assert(bh_platform_init() == BHT_OK);
    assert(os_malloc(1) == NULL && os_realloc(NULL, 1) == NULL);
    os_free(NULL);
    assert(os_mutex_init(&mutex) == BHT_OK);
    assert(os_mutex_lock(&mutex) == BHT_OK);
    assert(os_mutex_lock(&mutex) == BHT_ERROR);
    assert(os_mutex_destroy(&mutex) == BHT_ERROR);
    assert(os_mutex_unlock(&mutex) == BHT_OK);
    assert(os_mutex_unlock(&mutex) == BHT_ERROR);
    assert(os_mutex_destroy(&mutex) == BHT_OK);
    assert(os_cond_init(&cond) == BHT_OK && os_cond_destroy(&cond) == BHT_OK);
    assert(os_time_get_boot_us() == 1234567);
    assert(os_time_thread_cputime_us() == 1234567);
    assert(os_self_thread() == (korp_tid)1);
    assert(os_thread_get_stack_boundary() == &stack_low);
    bh_platform_destroy();
    return 0;
}
