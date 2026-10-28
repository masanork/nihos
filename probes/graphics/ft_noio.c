/* Explicit stream/memory callbacks are required by the link/ISA oracle. */
#include <ft2build.h>
#include FT_FREETYPE_H
#include FT_SYSTEM_H
#include <freetype/internal/ftstream.h>
extern void graphics_unavailable(unsigned kind);
FT_BASE_DEF(FT_Error) FT_Stream_Open(FT_Stream stream, const char *path) {
    (void)stream; (void)path; graphics_unavailable(1);
    return FT_Err_Cannot_Open_Resource;
}
FT_BASE_DEF(FT_Memory) FT_New_Memory(void) {
    graphics_unavailable(2); return 0;
}
FT_BASE_DEF(void) FT_Done_Memory(FT_Memory memory) { (void)memory; graphics_unavailable(3); }
