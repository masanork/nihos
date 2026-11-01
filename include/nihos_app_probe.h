#ifndef NIHOS_APP_PROBE_H
#define NIHOS_APP_PROBE_H
/* Experimental probe ABI, not a stable application ABI. */
#include <stdint.h>
/* Single trusted owner; storage remains exclusive and live until detach. */
int32_t nih_app_probe_attach(uint8_t *bytes, uint32_t len, uint32_t width, uint32_t height, uint32_t stride);
void nih_app_probe_detach(void);
/* RGB is 0x00RRGGBB; all drawing is synchronous. */
int32_t nih_app_fill_rect(int32_t x, int32_t y, uint32_t width, uint32_t height, uint32_t rgb);
/* bytes is valid only for the duration of the call; the host must not retain it. */
int32_t nih_app_text(int32_t x, int32_t y, const uint8_t *bytes, uint32_t length, uint32_t rgb);
int32_t nih_rust_app_frame(uint32_t selected);
int32_t nih_rust_owner_input(uint32_t byte);
/* Trusted owner: exclusive disjoint 720x1280 RGB565 scanout and 160x80 scratch.
   The caller publishes changed pixels after a successful synchronous call. */
int32_t nih_rust_owner_render(uint8_t *scanout, uint32_t scanout_len,
                              uint8_t *scratch, uint32_t scratch_len, uint32_t selected);
#endif
