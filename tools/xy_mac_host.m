// macOS Native Host & GPUI/C-ABI Verifier for `libxy` (`tools/xy_mac_host.m`)
//
// Connects `build/xy-mac/libxy_host.dylib` to:
// 1. Real Bunsen 3x2 OpenType fonts (`[Base, Ext, PUP]` x `[Mincho, Gothic]`, ~240 MiB on disk)
//    via POSIX `pread()` with exact I/O byte & call accounting.
// 2. Real `gjs.db` (325 MiB SQLite database) via `/usr/lib/libsqlite3.dylib` for live
//    SKK Omni-Completion (`~` IVS variants, `&` IDS components, `?` dictionary).
// 3. Target B (`xy_host_render_gpui` / `xy_host_render_rgba8`) and Target A (`xy_host_render_rgb565`),
//    supporting both headless PNG snapshot generation (`--snapshot <dir>`) and an interactive
//    native macOS Cocoa Retina window (`--window`).

#import <Cocoa/Cocoa.h>
#import <ImageIO/ImageIO.h>
#include <fcntl.h>
#include <sqlite3.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

// ============================================================================
// C-ABI Declarations matching `src/xy/c_abi_host.zig`
// ============================================================================

typedef uint32_t (*CSliceReaderFn)(const void *ctx, uint32_t offset, uint8_t *out_buf, uint32_t len);

typedef struct {
    const void *ctx;
    CSliceReaderFn read_fn;
} CSliceReaderDesc;

typedef void (*COmniQueryFn)(
    void *ctx,
    uint8_t kind,
    uint8_t prefix_char,
    const uint8_t *query_ptr,
    uint32_t query_len
);

typedef struct {
    int32_t x_px;
    int32_t y_px;
    uint16_t width_px;
    uint16_t height_px;
} CursorRect;

typedef struct {
    uint32_t base_cp;
    uint32_t ivs_cp;
    uint32_t cluster_byte_offset;
    uint8_t run;
    uint8_t style_id;
    uint8_t px_size;
    uint8_t vertical;
    int32_t cell_x_px;
    int32_t cell_y_px;
    int32_t bitmap_x_px;
    int32_t bitmap_y_px;
    uint16_t bitmap_width;
    uint16_t bitmap_height;
} PlacedGlyph;

typedef struct {
    PlacedGlyph glyph;
    const uint8_t *alpha_ptr;
    uint32_t alpha_len;
    uint32_t rgba8_color;
} GpuiGlyphQuad;

typedef struct {
    uint16_t viewport_width_px;
    uint16_t viewport_height_px;
    uint8_t axis;
    uint8_t style_id;
    uint8_t body_px;
    uint8_t ruby_px;
    uint32_t bg_rgba8;
    CursorRect cursor;
    uint32_t cursor_rgba8;
    uint32_t quad_count;
    const uint8_t *minibuffer_ptr;
    uint16_t minibuffer_len;
} GpuiFrameDescriptor;

extern bool xy_host_init(
    const CSliceReaderDesc *mincho_descs,
    uint32_t mincho_count,
    const CSliceReaderDesc *gothic_descs,
    uint32_t gothic_count
);
extern void xy_host_set_omni_callback(void *ctx, COmniQueryFn cb);
extern bool xy_host_add_candidate(
    const uint8_t *insert_ptr,
    uint32_t insert_len,
    const uint8_t *ann_ptr,
    uint32_t ann_len
);
extern void xy_host_set_viewport(uint16_t width_px, uint16_t height_px);
extern int32_t xy_host_eval(
    const uint8_t *sexp_ptr,
    uint32_t sexp_len,
    uint8_t *out_buf,
    uint32_t out_cap
);
extern bool xy_host_handle_key(uint8_t key);
extern bool xy_host_feed_utf8_reading(const uint8_t *utf8_ptr, uint32_t utf8_len);
extern void xy_host_cache_stats(uint32_t *out_outline_misses, uint32_t *out_bitmap_misses);
extern int32_t xy_host_render_gpui(
    uint8_t theme_id,
    GpuiFrameDescriptor *out_frame,
    GpuiGlyphQuad *out_quads,
    uint32_t max_quads
);
extern int32_t xy_host_render_rgb565(
    uint8_t *fb_ptr,
    uint32_t width,
    uint32_t height,
    uint32_t stride,
    uint8_t theme_id
);
extern int32_t xy_host_render_rgba8(
    uint8_t *rgba_ptr,
    uint32_t width,
    uint32_t height,
    uint32_t stride,
    uint8_t theme_id
);

// ============================================================================
// Paged POSIX `pread` Font Reader with I/O Accounting
// ============================================================================

typedef struct {
    int fd;
    const char *path;
} FontFileCtx;

static uint64_t g_pread_calls = 0;
static uint64_t g_pread_bytes = 0;

static uint32_t posix_pread_callback(const void *ctx_raw, uint32_t offset, uint8_t *out_buf, uint32_t len) {
    const FontFileCtx *fctx = (const FontFileCtx *)ctx_raw;
    if (fctx->fd < 0) return 0;
    ssize_t n = pread(fctx->fd, out_buf, len, (off_t)offset);
    if (n <= 0) return 0;
    g_pread_calls += 1;
    g_pread_bytes += (uint64_t)n;
    return (uint32_t)n;
}

// ============================================================================
// Live `gjs.db` SQLite Omni-Completion Provider
// ============================================================================

static sqlite3 *g_db = NULL;

static size_t encode_utf8(uint32_t cp, uint8_t *out) {
    if (cp <= 0x7F) {
        out[0] = (uint8_t)cp;
        return 1;
    } else if (cp <= 0x7FF) {
        out[0] = (uint8_t)(0xC0 | (cp >> 6));
        out[1] = (uint8_t)(0x80 | (cp & 0x3F));
        return 2;
    } else if (cp <= 0xFFFF) {
        out[0] = (uint8_t)(0xE0 | (cp >> 12));
        out[1] = (uint8_t)(0x80 | ((cp >> 6) & 0x3F));
        out[2] = (uint8_t)(0x80 | (cp & 0x3F));
        return 3;
    } else {
        out[0] = (uint8_t)(0xF0 | (cp >> 18));
        out[1] = (uint8_t)(0x80 | ((cp >> 12) & 0x3F));
        out[2] = (uint8_t)(0x80 | ((cp >> 6) & 0x3F));
        out[3] = (uint8_t)(0x80 | (cp & 0x3F));
        return 4;
    }
}

static uint32_t decode_first_utf8_cp(const uint8_t *s, uint32_t len) {
    if (len == 0) return 0;
    uint8_t b0 = s[0];
    if (b0 < 0x80) return b0;
    if ((b0 & 0xE0) == 0xC0 && len >= 2)
        return ((uint32_t)(b0 & 0x1F) << 6) | (s[1] & 0x3F);
    if ((b0 & 0xF0) == 0xE0 && len >= 3)
        return ((uint32_t)(b0 & 0x0F) << 12) | ((uint32_t)(s[1] & 0x3F) << 6) | (s[2] & 0x3F);
    if ((b0 & 0xF8) == 0xF0 && len >= 4)
        return ((uint32_t)(b0 & 0x07) << 18) | ((uint32_t)(s[1] & 0x3F) << 12) | ((uint32_t)(s[2] & 0x3F) << 6) | (s[3] & 0x3F);
    return 0;
}

static void gjs_omni_query_callback(
    void *ctx,
    uint8_t kind,
    uint8_t prefix_char,
    const uint8_t *query_ptr,
    uint32_t query_len
) {
    (void)ctx;
    (void)prefix_char;
    if (!g_db || query_len == 0) return;

    char qstr[256];
    uint32_t clen = query_len < 255 ? query_len : 255;
    memcpy(qstr, query_ptr, clen);
    qstr[clen] = '\0';

    // Kind 2: `~` Variant & IVS lookup in `ivd_sequences`
    if (kind == 2) {
        uint32_t base_cp = decode_first_utf8_cp(query_ptr, query_len);
        if (base_cp == 0) return;
        sqlite3_stmt *stmt = NULL;
        const char *sql =
            "SELECT variation_selector, GROUP_CONCAT(identifier, '/') "
            "FROM ivd_sequences WHERE base_codepoint = ?1 "
            "GROUP BY variation_selector ORDER BY variation_selector LIMIT 8;";
        if (sqlite3_prepare_v2(g_db, sql, -1, &stmt, NULL) == SQLITE_OK) {
            sqlite3_bind_int(stmt, 1, (int)base_cp);
            while (sqlite3_step(stmt) == SQLITE_ROW) {
                uint32_t vs_cp = (uint32_t)sqlite3_column_int(stmt, 0);
                const char *ident = (const char *)sqlite3_column_text(stmt, 1);
                uint8_t ins_buf[16];
                size_t n1 = encode_utf8(base_cp, ins_buf);
                size_t n2 = encode_utf8(vs_cp, ins_buf + n1);
                char ann_buf[128];
                snprintf(ann_buf, sizeof(ann_buf), "U+%05X %s", vs_cp, ident ? ident : "");
                xy_host_add_candidate(ins_buf, (uint32_t)(n1 + n2), (const uint8_t *)ann_buf, (uint32_t)strlen(ann_buf));
            }
            sqlite3_finalize(stmt);
        }
        return;
    }

    // Kind 3: `&` IDS component search in `ids_entries`
    if (kind == 3) {
        sqlite3_stmt *stmt = NULL;
        char like_pat[256];
        snprintf(like_pat, sizeof(like_pat), "%%%s%%", qstr);
        const char *sql =
            "SELECT c.character, i.ids_string FROM ids_entries i "
            "JOIN characters c ON c.id = i.character_id "
            "WHERE i.ids_string LIKE ?1 LIMIT 8;";
        if (sqlite3_prepare_v2(g_db, sql, -1, &stmt, NULL) == SQLITE_OK) {
            sqlite3_bind_text(stmt, 1, like_pat, -1, SQLITE_TRANSIENT);
            while (sqlite3_step(stmt) == SQLITE_ROW) {
                const char *ch = (const char *)sqlite3_column_text(stmt, 0);
                const char *ids = (const char *)sqlite3_column_text(stmt, 1);
                if (ch && ids) {
                    xy_host_add_candidate(
                        (const uint8_t *)ch, (uint32_t)strlen(ch),
                        (const uint8_t *)ids, (uint32_t)strlen(ids)
                    );
                }
            }
            sqlite3_finalize(stmt);
        }
        return;
    }

    // Kind 1: `?` Dictionary / character reading & meaning lookup in `gjs.db`
    if (kind == 1) {
        uint32_t base_cp = decode_first_utf8_cp(query_ptr, query_len);
        sqlite3_stmt *stmt = NULL;
        const char *sql =
            "SELECT c.character, c.codepoint_hex, "
            "(SELECT GROUP_CONCAT(reading_value, '・') FROM readings r WHERE r.character_id = c.id), "
            "(SELECT GROUP_CONCAT(meaning_text, '; ') FROM meanings m WHERE m.character_id = c.id) "
            "FROM characters c WHERE c.codepoint = ?1 LIMIT 1;";
        if (sqlite3_prepare_v2(g_db, sql, -1, &stmt, NULL) == SQLITE_OK) {
            sqlite3_bind_int(stmt, 1, (int)base_cp);
            if (sqlite3_step(stmt) == SQLITE_ROW) {
                const char *ch = (const char *)sqlite3_column_text(stmt, 0);
                const char *hex = (const char *)sqlite3_column_text(stmt, 1);
                const char *rd = (const char *)sqlite3_column_text(stmt, 2);
                const char *mn = (const char *)sqlite3_column_text(stmt, 3);
                char ann[256];
                snprintf(ann, sizeof(ann), "U+%s 読:%s 義:%s", hex ? hex : "", rd ? rd : "-", mn ? mn : "-");
                if (ch) {
                    xy_host_add_candidate(
                        (const uint8_t *)ch, (uint32_t)strlen(ch),
                        (const uint8_t *)ann, (uint32_t)strlen(ann)
                    );
                }
            }
            sqlite3_finalize(stmt);
        }
    }
}

// ============================================================================
// Helper: Save RGBA8888 Buffer to PNG via macOS ImageIO
// ============================================================================

static bool save_rgba_png(const char *path, const uint8_t *rgba, uint32_t width, uint32_t height) {
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(
        (void *)rgba,
        width,
        height,
        8,
        width * 4,
        cs,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big
    );
    if (!ctx) {
        CGColorSpaceRelease(cs);
        return false;
    }
    CGImageRef img = CGBitmapContextCreateImage(ctx);
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(
        kCFAllocatorDefault, (const UInt8 *)path, (CFIndex)strlen(path), false
    );
    CGImageDestinationRef dest = CGImageDestinationCreateWithURL(url, CFSTR("public.png"), 1, NULL);
    bool ok = false;
    if (dest && img) {
        CGImageDestinationAddImage(dest, img, NULL);
        ok = CGImageDestinationFinalize(dest);
    }
    if (dest) CFRelease(dest);
    if (url) CFRelease(url);
    if (img) CGImageRelease(img);
    CGContextRelease(ctx);
    CGColorSpaceRelease(cs);
    return ok;
}

static void eval_sexp_checked(const char *sexp) {
    uint8_t out[256];
    int32_t n = xy_host_eval((const uint8_t *)sexp, (uint32_t)strlen(sexp), out, sizeof(out) - 1);
    if (n < 0) {
        fprintf(stderr, "eval error on: %s\n", sexp);
    }
}

// ============================================================================
// Interactive macOS Cocoa Retina Window View
// ============================================================================

@interface XyCanvasView : NSView {
    uint8_t *_rgba_buf;
    GpuiGlyphQuad *_quads_buf;
    uint32_t _fb_width;
    uint32_t _fb_height;
    uint8_t _theme_id;
    bool _is_vertical;
    bool _is_gothic;
    uint8_t _font_size;
}
- (instancetype)initWithFrame:(NSRect)frameRect width:(uint32_t)w height:(uint32_t)h;
- (IBAction)toggleDirection:(id)sender;
- (IBAction)toggleFontFamily:(id)sender;
- (IBAction)decreaseFontSize:(id)sender;
- (IBAction)increaseFontSize:(id)sender;
- (IBAction)toggleTheme:(id)sender;
- (IBAction)demoIvsOmni:(id)sender;
- (IBAction)demoIdsOmni:(id)sender;
- (IBAction)undoEdit:(id)sender;
@end

@implementation XyCanvasView

- (instancetype)initWithFrame:(NSRect)frameRect width:(uint32_t)w height:(uint32_t)h {
    self = [super initWithFrame:frameRect];
    if (self) {
        _fb_width = w;
        _fb_height = h;
        _rgba_buf = (uint8_t *)calloc((size_t)w * (size_t)h * 4, 1);
        _quads_buf = (GpuiGlyphQuad *)calloc(512, sizeof(GpuiGlyphQuad));
        _theme_id = 0;
        _is_vertical = true;
        _is_gothic = false;
        _font_size = 32;
    }
    return self;
}

- (BOOL)acceptsFirstResponder {
    return YES;
}

- (void)applyViewSettings {
    char cmd[256];
    snprintf(
        cmd, sizeof(cmd),
        "(view/set! #:font '%s #:size %u #:direction '%s #:line-gap 18)",
        _is_gothic ? "bunsen-gothic" : "bunsen-mincho",
        _font_size,
        _is_vertical ? "vertical" : "horizontal"
    );
    eval_sexp_checked(cmd);
    [self setNeedsDisplay:YES];
    [[self window] makeFirstResponder:self];
}

- (IBAction)toggleDirection:(id)sender {
    (void)sender;
    _is_vertical = !_is_vertical;
    [self applyViewSettings];
}

- (IBAction)toggleFontFamily:(id)sender {
    (void)sender;
    _is_gothic = !_is_gothic;
    [self applyViewSettings];
}

- (IBAction)decreaseFontSize:(id)sender {
    (void)sender;
    if (_font_size > 16) _font_size -= 4;
    [self applyViewSettings];
}

- (IBAction)increaseFontSize:(id)sender {
    (void)sender;
    if (_font_size < 64) _font_size += 4;
    [self applyViewSettings];
}

- (IBAction)toggleTheme:(id)sender {
    (void)sender;
    _theme_id = (_theme_id == 0) ? 1 : 0;
    [self setNeedsDisplay:YES];
    [[self window] makeFirstResponder:self];
}

- (IBAction)demoIvsOmni:(id)sender {
    (void)sender;
    xy_host_handle_key(0x1B); // Reset any active state
    xy_host_handle_key('~');
    xy_host_feed_utf8_reading((const uint8_t *)"葛", 3);
    xy_host_handle_key(' '); // Query gjs.db ivd_sequences (press Space to cycle, Enter to commit)
    [self setNeedsDisplay:YES];
    [[self window] makeFirstResponder:self];
}

- (IBAction)demoIdsOmni:(id)sender {
    (void)sender;
    xy_host_handle_key(0x1B);
    xy_host_handle_key('&');
    xy_host_feed_utf8_reading((const uint8_t *)"相心", 6);
    xy_host_handle_key(' '); // Query gjs.db ids_entries -> 想
    [self setNeedsDisplay:YES];
    [[self window] makeFirstResponder:self];
}

- (IBAction)undoEdit:(id)sender {
    (void)sender;
    eval_sexp_checked("(buffer/undo!)");
    [self setNeedsDisplay:YES];
    [[self window] makeFirstResponder:self];
}

- (BOOL)performKeyEquivalent:(NSEvent *)event {
    NSEventModifierFlags flags = [event modifierFlags] & NSEventModifierFlagDeviceIndependentFlagsMask;
    if ((flags & NSEventModifierFlagCommand) != 0 || (flags & NSEventModifierFlagControl) != 0) {
        NSString *chars = [event charactersIgnoringModifiers];
        if ([chars length] > 0) {
            unichar c = [chars characterAtIndex:0];
            if (c == '1') { [self toggleDirection:nil]; return YES; }
            if (c == '2') { [self toggleFontFamily:nil]; return YES; }
            if (c == '3' || c == '-') { [self decreaseFontSize:nil]; return YES; }
            if (c == '4' || c == '=' || c == '+') { [self increaseFontSize:nil]; return YES; }
            if (c == '5') { [self toggleTheme:nil]; return YES; }
            if (c == 'z' || c == 'Z') { [self undoEdit:nil]; return YES; }
            if (c == 'q' || c == 'Q') { [NSApp terminate:nil]; return YES; }
        }
    }
    return [super performKeyEquivalent:event];
}

- (void)keyDown:(NSEvent *)event {
    unsigned short keyCode = [event keyCode];
    // F1..F5 also supported if Fn is pressed
    if (keyCode == 122) { [self toggleDirection:nil]; return; }
    if (keyCode == 120) { [self toggleFontFamily:nil]; return; }
    if (keyCode == 99)  { [self decreaseFontSize:nil]; return; }
    if (keyCode == 118) { [self increaseFontSize:nil]; return; }
    if (keyCode == 96)  { [self toggleTheme:nil]; return; }

    // Arrow keys: Left (123), Right (124), Down (125), Up (126)
    if (keyCode == 123 || keyCode == 126) {
        eval_sexp_checked("(buffer/move-graphemes! -1)");
        [self setNeedsDisplay:YES];
        return;
    }
    if (keyCode == 124 || keyCode == 125) {
        eval_sexp_checked("(buffer/move-graphemes! 1)");
        [self setNeedsDisplay:YES];
        return;
    }

    NSString *chars = [event characters];
    if ([chars length] == 0) return;
    const char *utf8 = [chars UTF8String];
    if (!utf8) return;

    size_t len = strlen(utf8);
    if (len == 1) {
        uint8_t ch = (uint8_t)utf8[0];
        if (ch == 0x7F) ch = 0x08; // Backspace
        xy_host_handle_key(ch);
    } else {
        // Multi-byte UTF-8 character input (e.g. macOS IME or paste)
        char expr[512];
        snprintf(expr, sizeof(expr), "(buffer/insert! \"%s\")", utf8);
        eval_sexp_checked(expr);
    }
    [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    xy_host_render_rgba8(_rgba_buf, _fb_width, _fb_height, _fb_width * 4, _theme_id);

    GpuiFrameDescriptor frame;
    memset(&frame, 0, sizeof(frame));
    xy_host_render_gpui(_theme_id, &frame, _quads_buf, 512);

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef bmp = CGBitmapContextCreate(
        _rgba_buf,
        _fb_width,
        _fb_height,
        8,
        _fb_width * 4,
        cs,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big
    );
    CGImageRef img = CGBitmapContextCreateImage(bmp);
    CGContextRef viewCtx = [[NSGraphicsContext currentContext] CGContext];
    NSRect canvasRect = NSMakeRect(0, 32, _fb_width, _fb_height);
    CGContextDrawImage(viewCtx, canvasRect, img);

    CGImageRelease(img);
    CGContextRelease(bmp);
    CGColorSpaceRelease(cs);

    // Draw bottom status & minibuffer bar (0..32px)
    NSColor *barBg = (_theme_id == 1)
        ? [NSColor colorWithCalibratedRed:0.06 green:0.07 blue:0.09 alpha:1.0]
        : [NSColor colorWithCalibratedRed:0.92 green:0.90 blue:0.85 alpha:1.0];
    [barBg setFill];
    NSRectFill(NSMakeRect(0, 0, _fb_width, 32));

    uint32_t om = 0, bm = 0;
    xy_host_cache_stats(&om, &bm);

    NSString *mbStr = @"";
    if (frame.minibuffer_ptr && frame.minibuffer_len > 0) {
        mbStr = [[NSString alloc] initWithBytes:frame.minibuffer_ptr
                                         length:frame.minibuffer_len
                                       encoding:NSUTF8StringEncoding];
    }
    if (!mbStr || [mbStr length] == 0) {
        mbStr = @"SKK/Omni待機中 (ローマ字入力 / ~異体字 / &IDS / ?辞書 / (S式) / Spaceで変換)";
    }

    NSString *statusLine = [NSString stringWithFormat:
        @" %@   |   %@ %upx (%@)   |   Outlines:%u Bitmaps:%u pread:%.1f KiB",
        mbStr,
        _is_gothic ? @"BunsenGothic" : @"BunsenMincho",
        _font_size,
        _is_vertical ? @"縦組" : @"横組",
        om, bm, (double)g_pread_bytes / 1024.0];

    NSColor *barFg = (_theme_id == 1)
        ? [NSColor colorWithCalibratedRed:0.85 green:0.88 blue:0.92 alpha:1.0]
        : [NSColor colorWithCalibratedRed:0.15 green:0.14 blue:0.12 alpha:1.0];
    NSDictionary *attrs = @{
        NSFontAttributeName: [NSFont monospacedSystemFontOfSize:12.0 weight:NSFontWeightMedium],
        NSForegroundColorAttributeName: barFg
    };
    [statusLine drawInRect:NSMakeRect(8, 7, _fb_width - 16, 20) withAttributes:attrs];
}

@end

// ============================================================================
// Main Entrypoint
// ============================================================================

int main(int argc, const char **argv) {
    const char *font_dir = "/Users/masanork/repo/gjs/data/output/bunsen-build";
    const char *db_path = "/Users/masanork/repo/gjs/data/output/gjs.db";

    const char *mincho_paths[3] = {
        "/Users/masanork/repo/gjs/data/output/bunsen-build/BunsenMincho-Regular.ttf",
        "/Users/masanork/repo/gjs/data/output/bunsen-build/BunsenMinchoExt-Regular.ttf",
        "/Users/masanork/repo/gjs/data/output/bunsen-build/BunsenMinchoPUP-Regular.ttf",
    };
    const char *gothic_paths[3] = {
        "/Users/masanork/repo/gjs/data/output/bunsen-build/BunsenGothic-Regular.ttf",
        "/Users/masanork/repo/gjs/data/output/bunsen-build/BunsenGothicExt-Regular.ttf",
        "/Users/masanork/repo/gjs/data/output/bunsen-build/BunsenGothicPUP-Regular.ttf",
    };
    (void)font_dir;

    FontFileCtx mincho_ctxs[3];
    CSliceReaderDesc mincho_descs[3];
    FontFileCtx gothic_ctxs[3];
    CSliceReaderDesc gothic_descs[3];

    for (int i = 0; i < 3; i++) {
        mincho_ctxs[i].path = mincho_paths[i];
        mincho_ctxs[i].fd = open(mincho_paths[i], O_RDONLY);
        if (mincho_ctxs[i].fd < 0) {
            fprintf(stderr, "Failed to open %s\n", mincho_paths[i]);
            return 1;
        }
        mincho_descs[i].ctx = &mincho_ctxs[i];
        mincho_descs[i].read_fn = posix_pread_callback;

        gothic_ctxs[i].path = gothic_paths[i];
        gothic_ctxs[i].fd = open(gothic_paths[i], O_RDONLY);
        if (gothic_ctxs[i].fd < 0) {
            fprintf(stderr, "Failed to open %s\n", gothic_paths[i]);
            return 1;
        }
        gothic_descs[i].ctx = &gothic_ctxs[i];
        gothic_descs[i].read_fn = posix_pread_callback;
    }

    if (sqlite3_open_v2(db_path, &g_db, SQLITE_OPEN_READONLY, NULL) != SQLITE_OK) {
        fprintf(stderr, "Warning: could not open %s\n", db_path);
        g_db = NULL;
    }

    uint64_t init_calls_before = g_pread_calls;
    uint64_t init_bytes_before = g_pread_bytes;
    if (!xy_host_init(mincho_descs, 3, gothic_descs, 3)) {
        fprintf(stderr, "xy_host_init failed!\n");
        return 1;
    }
    xy_host_set_omni_callback(NULL, gjs_omni_query_callback);
    printf(
        "[xy_mac_host] Initialized 6 Bunsen OpenType faces (240 MiB on disk) via pread: %llu calls, %llu bytes read\n",
        (unsigned long long)(g_pread_calls - init_calls_before),
        (unsigned long long)(g_pread_bytes - init_bytes_before)
    );

    const uint32_t W = 960;
    const uint32_t H = 540;
    xy_host_set_viewport(W, H);

    // Check for `--snapshot <dir>` mode
    if (argc >= 3 && strcmp(argv[1], "--snapshot") == 0) {
        const char *out_dir = argv[2];
        uint8_t *rgba = (uint8_t *)calloc((size_t)W * (size_t)H * 4, 1);

        // Construct UTF-8 showcase text directly via raw UTF-8 bytes
        const char *setup_sexp =
            "(buffer/with-undo-group "
            "  (buffer/clear!) "
            "  (buffer/insert! \"吾輩は猫である。名前はまだ無い。\\n\") "
            "  (buffer/insert! \"「葛\xF3\xA0\x84\x80飾・葛\xF3\xA0\x84\x81城・葛\xF3\xA0\x84\x82・葛\xF3\xA0\x84\x84」\\n\") "
            "  (buffer/insert! \"戸籍PUA：\xF4\x80\x80\x80・\xF4\x80\x80\x81（Bunsen三層統合）\\n\") "
            "  (buffer/add-ruby! 0 6 \"わがはい\") "
            "  (buffer/add-ruby! 9 12 \"ねこ\") "
            "  (buffer/add-ruby! 24 30 \"なまえ\"))";
        eval_sexp_checked(setup_sexp);

        // Also test live `~葛` omni-completion against real `gjs.db`!
        xy_host_handle_key('~');
        xy_host_feed_utf8_reading((const uint8_t *)"葛", 3);
        xy_host_handle_key(' '); // Queries `gjs.db` ivd_sequences!
        xy_host_handle_key('\n'); // Commits first IVS candidate from `gjs.db`!

        // Test live `&相心` IDS search against real `gjs.db`!
        xy_host_handle_key('&');
        xy_host_feed_utf8_reading((const uint8_t *)"相心", 6);
        xy_host_handle_key(' '); // Queries `gjs.db` ids_entries -> `想`!
        xy_host_handle_key('\n'); // Commits `想`!

        // Scene 1: Horizontal Bunsen Mincho 32px (Washi Light)
        eval_sexp_checked("(view/set! #:font 'bunsen-mincho #:size 32 #:direction 'horizontal #:line-gap 18)");
        uint64_t bytes_before_s1 = g_pread_bytes;
        int32_t q1 = xy_host_render_rgba8(rgba, W, H, W * 4, 0);
        uint32_t om1 = 0, bm1 = 0;
        xy_host_cache_stats(&om1, &bm1);
        char path1[512];
        snprintf(path1, sizeof(path1), "%s/xy_scene1_horizontal_mincho.png", out_dir);
        save_rgba_png(path1, rgba, W, H);
        printf(
            "[Scene 1: Horizontal Mincho 32px] quads=%d, outline_misses=%u, bitmap_misses=%u, pread_bytes=%llu -> %s\n",
            q1, om1, bm1, (unsigned long long)(g_pread_bytes - bytes_before_s1), path1
        );

        // Scene 2: Live S-expression switch to Vertical (`縦書き`) Bunsen Mincho 36px!
        eval_sexp_checked("(view/set! #:font 'bunsen-mincho #:size 36 #:direction 'vertical #:line-gap 22)");
        uint64_t bytes_before_s2 = g_pread_bytes;
        int32_t q2 = xy_host_render_rgba8(rgba, W, H, W * 4, 0);
        uint32_t om2 = 0, bm2 = 0;
        xy_host_cache_stats(&om2, &bm2);
        char path2[512];
        snprintf(path2, sizeof(path2), "%s/xy_scene2_vertical_mincho.png", out_dir);
        save_rgba_png(path2, rgba, W, H);
        printf(
            "[Scene 2: Vertical Mincho 36px]   quads=%d, outline_misses=%u (+%u!), bitmap_misses=%u, pread_bytes=%llu -> %s\n",
            q2, om2, om2 - om1, bm2, (unsigned long long)(g_pread_bytes - bytes_before_s2), path2
        );

        // Scene 3: Live S-expression switch to Bunsen Gothic 34px Vertical (Hacker Dark theme)
        eval_sexp_checked("(view/set! #:font 'bunsen-gothic #:size 34 #:direction 'vertical #:line-gap 20)");
        uint64_t bytes_before_s3 = g_pread_bytes;
        int32_t q3 = xy_host_render_rgba8(rgba, W, H, W * 4, 1);
        uint32_t om3 = 0, bm3 = 0;
        xy_host_cache_stats(&om3, &bm3);
        char path3[512];
        snprintf(path3, sizeof(path3), "%s/xy_scene3_vertical_gothic_dark.png", out_dir);
        save_rgba_png(path3, rgba, W, H);
        printf(
            "[Scene 3: Vertical Gothic 34px]   quads=%d, outline_misses=%u, bitmap_misses=%u, pread_bytes=%llu -> %s\n",
            q3, om3, bm3, (unsigned long long)(g_pread_bytes - bytes_before_s3), path3
        );

        free(rgba);
        if (g_db) sqlite3_close(g_db);
        return 0;
    }

    // Interactive Cocoa Window Mode
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];

        const char *init_sexp =
            "(buffer/with-undo-group "
            "  (buffer/clear!) "
            "  (buffer/insert! \"吾輩は猫である。名前はまだ無い。\\n\") "
            "  (buffer/insert! \"「葛\xF3\xA0\x84\x80飾・葛\xF3\xA0\x84\x81城・葛\xF3\xA0\x84\x82・葛\xF3\xA0\x84\x84」\\n\") "
            "  (buffer/insert! \"戸籍PUA：\xF4\x80\x80\x80・\xF4\x80\x80\x81（Bunsen三層統合）\\n\") "
            "  (buffer/add-ruby! 0 6 \"わがはい\") "
            "  (buffer/add-ruby! 9 12 \"ねこ\") "
            "  (buffer/add-ruby! 24 30 \"なまえ\"))";
        eval_sexp_checked(init_sexp);
        eval_sexp_checked("(view/set! #:font 'bunsen-mincho #:size 32 #:direction 'vertical #:line-gap 18)");

        const CGFloat toolbarH = 38.0;
        const CGFloat statusH = 32.0;
        NSRect winRect = NSMakeRect(120, 120, W, H + toolbarH + statusH);
        NSWindow *window = [[NSWindow alloc]
            initWithContentRect:winRect
                      styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable)
                        backing:NSBackingStoreBuffered
                          defer:NO];
        [window setTitle:@"xy — Convivial Machine Host (⌘1:縦/横  ⌘2:明朝/ゴシック  ⌘-/⌘+:サイズ  ⌘5:テーマ  ⌘Z:Undo)"];

        NSView *root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, W, H + toolbarH + statusH)];
        XyCanvasView *view = [[XyCanvasView alloc] initWithFrame:NSMakeRect(0, 0, W, H + statusH) width:W height:H];
        [root addSubview:view];

        struct {
            NSString *title;
            SEL action;
            CGFloat width;
        } btns[] = {
            { @"縦/横 (⌘1)",       @selector(toggleDirection:),  96 },
            { @"明朝/ゴシック (⌘2)", @selector(toggleFontFamily:), 132 },
            { @"文字 - (⌘-)",      @selector(decreaseFontSize:), 96 },
            { @"文字 + (⌘+)",      @selector(increaseFontSize:), 96 },
            { @"テーマ (⌘5)",      @selector(toggleTheme:),      96 },
            { @"~葛 IVS検索",      @selector(demoIvsOmni:),      104 },
            { @"&相心 IDS検索",     @selector(demoIdsOmni:),      108 },
            { @"Undo (⌘Z)",        @selector(undoEdit:),         92 },
        };
        CGFloat bx = 10.0;
        for (size_t i = 0; i < sizeof(btns) / sizeof(btns[0]); i++) {
            NSButton *b = [[NSButton alloc] initWithFrame:NSMakeRect(bx, H + statusH + 5.0, btns[i].width, 28.0)];
            [b setTitle:btns[i].title];
            [b setBezelStyle:NSBezelStyleRounded];
            [b setTarget:view];
            [b setAction:btns[i].action];
            [root addSubview:b];
            bx += btns[i].width + 6.0;
        }

        [window setContentView:root];
        [window makeFirstResponder:view];
        [window makeKeyAndOrderFront:nil];
        [NSApp activateIgnoringOtherApps:YES];
        [NSApp run];
    }
    return 0;
}
