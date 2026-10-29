/* A no-op observer used only for standalone link-size measurement. */
#include <stdint.h>
void nih_pqc_observe(uint32_t out[3]) { out[0] = 0; out[1] = 0; out[2] = 0; }
