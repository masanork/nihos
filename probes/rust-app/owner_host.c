#include "nihos_app_probe.h"
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

enum { FRAME = 720 * 1280 * 2, SCRATCH = 160 * 80 * 2 };
static uint8_t frame[FRAME], scratch[SCRATCH];
void rust_eh_personality(void) {}
static uint16_t logical(unsigned x, unsigned y) {
    unsigned i = ((1279 - x) * 720 + y) * 2;
    return (uint16_t)(frame[i] | (uint16_t)frame[i + 1] << 8);
}
int main(void) {
    assert(nih_rust_owner_input('0') == 0);
    assert(nih_rust_owner_input('1') == 1);
    assert(nih_rust_owner_input('x') == -1);
    memset(frame, 0xa5, sizeof(frame));
    assert(nih_rust_owner_render(frame, FRAME, scratch, SCRATCH, (uint32_t)nih_rust_owner_input('0')) == 0);
    assert(logical(16, 16) == 0x1082 && logical(15, 16) == 0xa5a5);
    unsigned ink = 0;
    for (unsigned y = 24; y < 32; y++) for (unsigned x = 24; x < 64; x++) ink += logical(x,y) == 0xffff;
    assert(ink > 0);
    assert(nih_rust_owner_render(frame, FRAME, scratch, SCRATCH, (uint32_t)nih_rust_owner_input('1')) == 0);
    assert(logical(16, 16) == 0x220c && logical(176, 16) == 0xa5a5);
    assert(nih_rust_owner_render(frame, FRAME, scratch, SCRATCH, 2) == -1);
    assert(nih_rust_owner_render(frame, FRAME, frame + 100, SCRATCH, 0) == -1);
    assert(nih_rust_owner_render(frame, FRAME - 1, scratch, SCRATCH, 0) == -1);
    assert(logical(16, 16) == 0x220c);
    assert(nih_rust_owner_render(frame, FRAME, scratch, SCRATCH, (uint32_t)nih_rust_owner_input('0')) == 0);
    assert(logical(16, 16) == 0x1082);
    puts("Rust app display owner rotation: ok");
}
