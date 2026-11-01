/* Test-only deliberate unaligned load proves the instrumented trap is live. */
#include <stdint.h>
static _Alignas(4) volatile uint8_t bytes[8];
__attribute__((noinline)) uint32_t nih_wamr_alignment_negative(void) {
    return *(volatile uint32_t *)(void *)(bytes + 1);
}
