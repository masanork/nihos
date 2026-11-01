#include "nihos_app_probe.h"
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

enum { W = 160, H = 80, STRIDE = W * 2 + 4 };
static uint8_t frame[STRIDE * H];
static uint16_t pixel(unsigned x, unsigned y) {
    unsigned i = y * STRIDE + x * 2;
    return (uint16_t)(frame[i] | (uint16_t)frame[i + 1] << 8);
}
int main(void) {
    memset(frame, 0xa5, sizeof(frame));
    assert(nih_rust_app_frame(0) == -3);
    assert(nih_app_probe_attach(frame, sizeof(frame), W, H, STRIDE) == 0);
    assert(nih_app_probe_attach(frame, sizeof(frame), W, H, STRIDE) == -3);
    assert(nih_rust_app_frame(0) == 0);
    assert(pixel(0, 0) == 0x1082);
    unsigned white = 0;
    for (unsigned y = 8; y < 16; y++) for (unsigned x = 8; x < 48; x++) white += pixel(x,y) == 0xffff;
    assert(white > 0);
    for (unsigned y = 0; y < H; y++) for (unsigned x = W * 2; x < STRIDE; x++) assert(frame[y * STRIDE + x] == 0xa5);
    assert(nih_rust_app_frame(1) == 0 && pixel(0, 0) == 0x220c);
    assert(nih_app_fill_rect(-2, -2, 3, 3, 0xff0000) == 0 && pixel(0, 0) == 0xf800);
    assert(nih_app_fill_rect(INT32_MAX, INT32_MAX, UINT32_MAX, UINT32_MAX, 0) == 0);
    uint8_t invalid[] = { 'A', 0xff };
    uint8_t saved[sizeof(frame)]; memcpy(saved, frame, sizeof(frame));
    assert(nih_app_text(0, 0, invalid, sizeof(invalid), 0xffffff) == -2);
    assert(memcmp(saved, frame, sizeof(frame)) == 0);
    nih_app_probe_detach();
    assert(nih_rust_app_frame(1) == -3);
    puts("Rust app + Zig RGB565 surface: ok");
}
/* Rust's prebuilt core references this on the host; the probe uses panic=abort. */
void rust_eh_personality(void) {}
