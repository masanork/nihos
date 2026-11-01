/* Test-only GCC alignment sanitizer trap for the RV32 emulator profile. */
#include <stdint.h>

typedef struct {
    const char *file;
    uint32_t line;
    uint32_t column;
} SourceLocation;
typedef struct {
    SourceLocation location;
    const void *type;
    uint8_t log_alignment;
    uint8_t check_kind;
} TypeMismatch;
extern int32_t nih_rom_putc(uint8_t byte);
static void putstr(const char *s) {
    if (!s) s = "?";
    while (*s) (void)nih_rom_putc((uint8_t)*s++);
}
static void hex32(uint32_t n) {
    const char *digits = "0123456789abcdef";
    for (int shift = 28; shift >= 0; shift -= 4)
        (void)nih_rom_putc((uint8_t)digits[(n >> shift) & 15]);
}
__attribute__((noreturn))
void __ubsan_handle_type_mismatch_v1_abort(const TypeMismatch *data, uintptr_t address) {
    putstr("NIHOS_WAMR_ALIGN_TRAP file=");
    putstr(data->location.file);
    putstr(" line="); hex32(data->location.line);
    putstr(" address="); hex32((uint32_t)address);
    putstr(" align_log2="); hex32(data->log_alignment);
    putstr("\n");
    for (;;) __asm__ volatile ("wfi");
}
