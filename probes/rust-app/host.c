#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "nihos_app_probe.h"

static int calls;
static int fail;
static uint32_t color;
static char label[16];
int32_t nih_app_fill_rect(int32_t x, int32_t y, uint32_t w, uint32_t h, uint32_t rgb) {
    assert(x == 0 && y == 0 && w == 160 && h == 80);
    calls++; color = rgb;
    return fail ? -4 : 0;
}
int32_t nih_app_text(int32_t x, int32_t y, const uint8_t *p, uint32_t len, uint32_t rgb) {
    assert(x == 8 && y == 8 && rgb == 0xffffff && len < sizeof(label));
    calls++; memcpy(label, p, len); label[len] = 0;
    return 0;
}
int main(void) {
    assert(nih_rust_app_frame(0) == 0 && calls == 2 && color == 0x101010 && strcmp(label, "Ready") == 0);
    calls = 0;
    assert(nih_rust_app_frame(1) == 0 && calls == 2 && color == 0x204060 && strcmp(label, "Pressed") == 0);
    calls = 0; fail = 1;
    assert(nih_rust_app_frame(1) == -4 && calls == 1);
    calls = 0;
    assert(nih_rust_app_frame(2) == -1 && calls == 0);
    puts("Rust app C ABI host probe: ok");
}
