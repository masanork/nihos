// Host-only design renderer, linked to the existing pinned FT/HB probe builds.
// Uses the system allocator; this is not the native worker/lifetime fixture.
#include <ft2build.h>
#include FT_FREETYPE_H
#include <hb.h>
#include <hb-ft.h>
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

extern "C" void *study_malloc(size_t n) { return std::malloc(n); }
extern "C" void *study_calloc(size_t n, size_t size) { return std::calloc(n, size); }
extern "C" void *study_realloc(void *p, size_t n) { return std::realloc(p, n); }
extern "C" void study_free(void *p) { std::free(p); }

struct Glyph { int x, y, w, h; std::vector<uint8_t> alpha; };
int main(int argc, char **argv) {
    if (argc == 2 && !std::strcmp(argv[1], "--versions")) {
        FT_Library lib; if (FT_Init_FreeType(&lib)) return 2;
        FT_Int a,b,c; FT_Library_Version(lib,&a,&b,&c);
        std::printf("{\"freetype\":\"%d.%d.%d\",\"harfbuzz\":\"%s\"}\n",a,b,c,hb_version_string());
        FT_Done_FreeType(lib); return 0;
    }
    if (argc != 5 || std::strlen(argv[4]) > 1024) return 2;
    const int size = std::atoi(argv[2]);
    if (size < 8 || size > 160) return 2;
    FT_Library lib; if (FT_Init_FreeType(&lib)) return 3;
    FT_Face face; if (FT_New_Face(lib,argv[1],0,&face)) return 4;
    if (FT_Set_Pixel_Sizes(face,0,(FT_UInt)size)) return 5;
    hb_font_t *font=hb_ft_font_create_referenced(face);
    hb_buffer_t *buffer=hb_buffer_create();
    hb_buffer_add_utf8(buffer,argv[4],-1,0,-1);
    const bool vertical=!std::strcmp(argv[3],"ttb");
    hb_buffer_set_direction(buffer,vertical ? HB_DIRECTION_TTB : HB_DIRECTION_LTR);
    hb_buffer_set_script(buffer,HB_SCRIPT_HAN);
    hb_buffer_set_language(buffer,hb_language_from_string("ja",-1));
    hb_shape(font,buffer,nullptr,0);
    unsigned count=0;
    const auto *info=hb_buffer_get_glyph_infos(buffer,&count);
    const auto *positions=hb_buffer_get_glyph_positions(buffer,&count);
    if (!count || count>256) return 6;
    std::vector<Glyph> glyphs;
    int pen_x=0,pen_y=0,left=0,top=0,right=0,bottom=0;
    for (unsigned i=0;i<count;++i) {
        if (!info[i].codepoint || FT_Load_Glyph(face,info[i].codepoint,FT_LOAD_DEFAULT) ||
            FT_Render_Glyph(face->glyph,FT_RENDER_MODE_NORMAL)) return 7;
        const auto &bmp=face->glyph->bitmap;
        if (bmp.pixel_mode!=FT_PIXEL_MODE_GRAY && bmp.width) return 8;
        Glyph g{(pen_x+positions[i].x_offset)/64+face->glyph->bitmap_left,
                -(pen_y+positions[i].y_offset)/64-face->glyph->bitmap_top,
                (int)bmp.width,(int)bmp.rows,{}};
        g.alpha.resize((size_t)g.w*(size_t)g.h);
        for (int y=0;y<g.h;++y) for (int x=0;x<g.w;++x)
            g.alpha[(size_t)y*g.w+x]=bmp.buffer[(ptrdiff_t)y*bmp.pitch+x];
        if (g.w && g.h) {
            if (glyphs.empty()) {left=g.x;top=g.y;right=g.x+g.w;bottom=g.y+g.h;}
            else {left=std::min(left,g.x);top=std::min(top,g.y);right=std::max(right,g.x+g.w);bottom=std::max(bottom,g.y+g.h);}
        }
        glyphs.push_back(std::move(g));
        pen_x+=positions[i].x_advance;pen_y+=positions[i].y_advance;
    }
    const int w=std::max(1,right-left),h=std::max(1,bottom-top);
    if (w>8192 || h>8192) return 9;
    std::vector<uint8_t> image((size_t)w*h,0);
    for (const auto &g:glyphs) for (int y=0;y<g.h;++y) for (int x=0;x<g.w;++x) {
        auto &pixel=image[(size_t)(g.y-top+y)*w+(g.x-left+x)];
        pixel=std::max(pixel,g.alpha[(size_t)y*g.w+x]);
    }
    std::printf("P5\n%d %d\n255\n",w,h);
    if (std::fwrite(image.data(),1,image.size(),stdout)!=image.size()) return 10;
    hb_buffer_destroy(buffer);hb_font_destroy(font);FT_Done_Face(face);FT_Done_FreeType(lib);
    return 0;
}
