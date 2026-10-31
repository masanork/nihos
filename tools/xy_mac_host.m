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
#import <WebKit/WebKit.h>
#include <fcntl.h>
#include <sqlite3.h>
#include "nihos_xy_workspace.h"
#include "nihos_xy_learning.h"
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
    uint16_t advance_px;
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

extern bool xy_host_set_status(const uint8_t *, uint32_t);
extern bool xy_host_live_init(void);
extern int32_t xy_host_default_source(uint8_t *, uint32_t);
extern uint32_t xy_host_render_error(uint8_t *, uint32_t);
extern uint32_t xy_host_live_error(uint8_t *, uint32_t);
extern bool xy_host_live_prepare(const uint8_t *, uint32_t);
extern bool xy_host_live_activate(void);
extern void xy_host_live_discard(void);
extern int32_t xy_host_live_run(const uint8_t *, uint32_t, bool, uint8_t *, uint32_t);
extern int32_t xy_host_buffer_copy(uint8_t *, uint32_t);
extern bool xy_host_insert_text(const uint8_t *, uint32_t);
extern bool xy_host_buffer_replace(const uint8_t *, uint32_t);
extern bool xy_host_source_enter(const uint8_t *, uint32_t);
extern void xy_host_source_leave(void);

// The GUI and process-restart verifier use this same lifecycle coordinator.
static XyWorkspaceStore *g_workspace = NULL;
static int64_t g_workspace_revision = 0;
static uint8_t g_workspace_source[XY_SOURCE_LIMIT];
static uint32_t g_workspace_source_len = 0;
static char g_workspace_status[512] = "";
static bool g_workspace_fallback = false;

static bool workspace_scheme_error(void) {
    uint8_t error[256];
    uint32_t n = xy_host_live_error(error, sizeof(error));
    snprintf(g_workspace_status, sizeof(g_workspace_status), "Scheme: %.*s", (int)n, error);
    return false;
}
static bool workspace_db_error(void) {
    snprintf(g_workspace_status, sizeof(g_workspace_status), "%s", xy_workspace_error(g_workspace));
    return false;
}
static bool workspace_start(const char *path, bool safe) {
    if (!xy_host_live_init()) return workspace_scheme_error();
    g_workspace_source_len = (uint32_t)xy_host_default_source(g_workspace_source, sizeof(g_workspace_source));
    g_workspace_revision = 0;
    g_workspace_fallback = true;
    g_workspace = xy_workspace_open(path);
    if (!g_workspace || *xy_workspace_error(g_workspace)) return workspace_db_error();
    int32_t n = xy_workspace_load(g_workspace, 0, g_workspace_source, sizeof(g_workspace_source), &g_workspace_revision);
    if (n < 0) return workspace_db_error();
    if (g_workspace_revision) g_workspace_source_len = (uint32_t)n;
    if (safe) {
        snprintf(g_workspace_status, sizeof(g_workspace_status), "Safe mode: built-in commands; stored source is available for repair");
        return true;
    }
    if (g_workspace_revision) {
        if (!xy_host_live_prepare(g_workspace_source, g_workspace_source_len)) {
            workspace_scheme_error();
            size_t used = strlen(g_workspace_status);
            snprintf(g_workspace_status + used, sizeof(g_workspace_status) - used, "; using built-in commands");
            return true;
        }
        if (!xy_host_live_activate()) return workspace_scheme_error();
        g_workspace_fallback = false;
    }
    snprintf(g_workspace_status, sizeof(g_workspace_status), "Source revision %lld", (long long)g_workspace_revision);
    return true;
}
static bool workspace_apply(const uint8_t *source, uint32_t length) {
    if (!g_workspace) return workspace_db_error();
    if (!xy_host_live_prepare(source, length)) return workspace_scheme_error();
    int64_t revision = 0;
    if (xy_workspace_save(g_workspace, source, length, g_workspace_revision, &revision)) {
        xy_host_live_discard();
        return workspace_db_error();
    }
    // No event-loop yield between commit receipt and this infallible prepared swap.
    if (!xy_host_live_activate()) abort();
    memcpy(g_workspace_source, source, length);
    g_workspace_source_len = length;
    g_workspace_revision = revision;
    g_workspace_fallback = false;
    snprintf(g_workspace_status, sizeof(g_workspace_status), "Applied and saved revision %lld", (long long)revision);
    return true;
}
static bool workspace_select(int64_t revision) {
    uint8_t source[XY_SOURCE_LIMIT];
    int64_t loaded = 0;
    int32_t n = xy_workspace_load(g_workspace, revision, source, sizeof(source), &loaded);
    if (n < 0) return workspace_db_error();
    if (!xy_host_live_prepare(source, (uint32_t)n)) return workspace_scheme_error();
    if (xy_workspace_select(g_workspace, loaded, g_workspace_revision)) {
        xy_host_live_discard(); return workspace_db_error();
    }
    if (!xy_host_live_activate()) abort();
    memcpy(g_workspace_source, source, (size_t)n);
    g_workspace_source_len = (uint32_t)n;
    g_workspace_revision = loaded;
    g_workspace_fallback = false;
    snprintf(g_workspace_status, sizeof(g_workspace_status), "Restored revision %lld", (long long)loaded);
    return true;
}
static bool workspace_reload(void) {
    uint8_t source[XY_SOURCE_LIMIT];
    int64_t revision = 0;
    int32_t n = xy_workspace_load(g_workspace, 0, source, sizeof(source), &revision);
    if (n < 0) return workspace_db_error();
    if (!revision) n = xy_host_default_source(source, sizeof(source));
    if (!xy_host_live_prepare(source, (uint32_t)n)) return workspace_scheme_error();
    if (!xy_host_live_activate()) abort();
    memcpy(g_workspace_source, source, (size_t)n);
    g_workspace_source_len = (uint32_t)n;
    g_workspace_revision = revision;
    g_workspace_fallback = !revision;
    snprintf(g_workspace_status, sizeof(g_workspace_status), "Reloaded revision %lld", (long long)revision);
    return true;
}
static int workspace_cli(int argc, const char **argv) {
    if (argc < 4 || !workspace_start(argv[2], argc > 5 && strcmp(argv[5], "--safe") == 0)) {
        fprintf(stderr, "%s\n", g_workspace_status); return 1;
    }
    const char *action = argv[3];
    bool ok = true;
    uint8_t out[16384];
    if (strcmp(action, "source") == 0) fwrite(g_workspace_source, 1, g_workspace_source_len, stdout);
    else if (strcmp(action, "status") == 0) puts(g_workspace_status);
    else if (strcmp(action, "history") == 0) {
        int64_t revisions[XY_HISTORY_LIMIT];
        int32_t count = xy_workspace_history(g_workspace, revisions, XY_HISTORY_LIMIT);
        if (count < 0) ok = workspace_db_error();
        else for (int32_t i = 0; i < count; i++) printf("%lld\n", (long long)revisions[i]);
    } else if (strcmp(action, "apply-file") == 0 && argc >= 5) {
        FILE *file = fopen(argv[4], "rb");
        if (!file) { perror(argv[4]); return 1; }
        size_t length = fread(out, 1, XY_SOURCE_LIMIT + 1, file);
        int error = ferror(file);
        fclose(file);
        if (error || length > XY_SOURCE_LIMIT) { fprintf(stderr, "Source exceeds 4096 bytes or cannot be read\n"); return 1; }
        ok = workspace_apply(out, (uint32_t)length);
        if (ok) printf("revision=%lld\n", (long long)g_workspace_revision);
    } else if (strcmp(action, "select") == 0 && argc >= 5) {
        char *end = NULL;
        int64_t revision = strtoll(argv[4], &end, 10);
        ok = end != argv[4] && *end == 0 && revision > 0 && workspace_select(revision);
    } else if ((strcmp(action, "run") == 0 || strcmp(action, "eval") == 0) && argc >= 5) {
        bool named = strcmp(action, "run") == 0;
        int32_t n = xy_host_live_run((const uint8_t *)argv[4], (uint32_t)strlen(argv[4]), named, out, sizeof(out));
        if (n < 0) ok = workspace_scheme_error();
        else {
            if (named) n = xy_host_buffer_copy(out, sizeof(out));
            if (n < 0) ok = false;
            else fwrite(out, 1, (size_t)n, stdout);
        }
    } else { snprintf(g_workspace_status, sizeof(g_workspace_status), "Unknown workspace action"); ok = false; }
    if (!ok) fprintf(stderr, "%s\n", g_workspace_status);
    xy_workspace_close(g_workspace);
    return ok ? 0 : 1;
}

typedef struct { uint32_t base_start, base_end, ruby_start, ruby_end; } XyReaderRuby;
extern bool xy_host_reader_enter(void);
extern bool xy_host_document_load(const uint8_t *, uint32_t);
extern void xy_host_reader_leave(void);
extern int32_t xy_host_reader_load(const uint8_t *, uint32_t, const uint8_t *, uint32_t, const XyReaderRuby *, uint32_t);

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

@interface XyCanvasView : NSView <NSWindowDelegate, NSApplicationDelegate> {
    uint8_t *_rgba_buf;
    GpuiGlyphQuad *_quads_buf;
    uint32_t _fb_width;
    uint32_t _fb_height;
    uint8_t _theme_id;
    bool _is_vertical;
    bool _is_gothic;
    uint8_t _font_size;
    bool _editingSource;
    bool _savedVertical;
    uint8_t _savedFontSize;
    bool _selectAll;
    NSData *_sourceDraft;
    NSString *_workspaceMessage;
    NSView *_home, *_readingBar;
    NSButton *_resumeReadingButton;
    NSTextField *_readingTitle;
    NSArray *_library;
    NSSegmentedControl *_directionPicker;
    NSPopUpButton *_sizePicker, *_familyPicker, *_themePicker, *_chapterPicker;
    BOOL _reading, _documentDirty;
    BOOL _learning;
    NSData *_learningData;
    NSView *_learningBar;
    NSURL *_documentURL;
    NSDictionary *_readingItem;
    NSData *_readingText;
    NSArray *_readingRuby;
    NSInteger _chapterIndex;
    NSUInteger _readingStart, _readingEnd;
    NSMutableArray<NSNumber *> *_pageStarts;
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
- (IBAction)editSource:(id)sender;
- (IBAction)applySource:(id)sender;
- (IBAction)runCommand:(id)sender;
- (IBAction)restoreSource:(id)sender;
- (IBAction)reloadSource:(id)sender;
- (NSData *)currentBuffer;
- (void)installHomeIn:(NSView *)root;
- (void)loadReadingChapter;
- (BOOL)layoutReadingPage;
- (void)saveDisplayPreferences;
- (void)syncHomeSettings;
- (void)leaveReader;
- (void)setReadingChrome:(BOOL)reading;
- (BOOL)saveDocument;
- (BOOL)confirmDocumentReplacement;
- (IBAction)showHome:(id)sender;
- (IBAction)resumeDocument:(id)sender;
- (IBAction)resumeReading:(id)sender;
- (IBAction)newDocument:(id)sender;
- (IBAction)openDocument:(id)sender;
- (IBAction)selectHomeBook:(id)sender;
- (IBAction)homeSettingsChanged:(id)sender;
- (IBAction)nextPage:(id)sender;
- (IBAction)previousPage:(id)sender;
- (IBAction)selectChapter:(id)sender;
- (IBAction)showAttribution:(id)sender;
- (void)showReadingFigures;
- (IBAction)showExamples:(id)sender;
- (IBAction)backToReading:(id)sender;
- (IBAction)runLearning:(id)sender;
- (IBAction)resetLearning:(id)sender;
- (IBAction)restoreLearning:(id)sender;
- (IBAction)toggleLearningNotes:(id)sender;
- (void)installLearningBarIn:(NSView *)root;
- (BOOL)openLearningOrdinal:(uint32_t)ordinal;


@end

@implementation XyCanvasView
#include "xy_home.inc"
#include "xy_learning.inc"

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
        NSDictionary *prefs=[[NSUserDefaults standardUserDefaults] dictionaryForKey:@"xy.home.display.v1"];
        if (prefs && [@[@16,@20,@24,@28,@32,@36,@40,@48,@56,@64] containsObject:prefs[@"size"]]) {
            _font_size=[prefs[@"size"] unsignedCharValue]; _is_vertical=[prefs[@"vertical"] boolValue];
            _is_gothic=[prefs[@"gothic"] boolValue]; _theme_id=[prefs[@"theme"] boolValue];
        }
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
        "(view/set! #:font '%s #:size %u #:direction '%s #:line-gap %u #:ruby-size %u)",
        _is_gothic ? "bunsen-gothic" : "bunsen-mincho",
        _font_size,
        _is_vertical ? "vertical" : "horizontal",
        _editingSource ? 0 : 18,
        _editingSource ? 6 : _font_size / 2
    );
    eval_sexp_checked(cmd);
    for (NSView *child in self.superview.subviews) if ([child isKindOfClass:[NSButton class]]) {
        NSButton *button=(NSButton *)child;
        if (button.action==@selector(applySource:)) button.title=_editingSource ? @"Apply & Save (⌘S)" : @"文書を保存 (⌘S)";
    }
    if (!_editingSource) { [self saveDisplayPreferences]; [self syncHomeSettings]; }
    if (_reading) [self layoutReadingPage];
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
    [self saveDisplayPreferences]; [self syncHomeSettings];
    eval_sexp_checked(_theme_id ? "(view/set! #:theme 'dark)" : "(view/set! #:theme 'light)");
    [self setNeedsDisplay:YES];
    [[self window] makeFirstResponder:self];
}

- (IBAction)demoIvsOmni:(id)sender {
    (void)sender;
    if (_reading || !_home.hidden) return;
    xy_host_handle_key(0x1B); // Reset any active state
    xy_host_handle_key('~');
    xy_host_feed_utf8_reading((const uint8_t *)"葛", 3);
    xy_host_handle_key(' '); // Query gjs.db ivd_sequences (press Space to cycle, Enter to commit)
    [self setNeedsDisplay:YES];
    [[self window] makeFirstResponder:self];
}

- (IBAction)demoIdsOmni:(id)sender {
    (void)sender;
    if (_reading || !_home.hidden) return;
    xy_host_handle_key(0x1B);
    xy_host_handle_key('&');
    xy_host_feed_utf8_reading((const uint8_t *)"相心", 6);
    xy_host_handle_key(' '); // Query gjs.db ids_entries -> 想
    [self setNeedsDisplay:YES];
    [[self window] makeFirstResponder:self];
}

- (IBAction)undoEdit:(id)sender {
    (void)sender;
    if (_reading || !_home.hidden) return;
    eval_sexp_checked("(buffer/undo!)");
    if (!_editingSource) _documentDirty=YES;
    [self setNeedsDisplay:YES];
    [[self window] makeFirstResponder:self];
}

- (void)workspaceNotice:(NSString *)message error:(BOOL)error {
    _workspaceMessage = message;
    [self setNeedsDisplay:YES];
    if (error) {
        NSAlert *alert = [[NSAlert alloc] init];
        [alert setMessageText:@"xy Workspace"];
        [alert setInformativeText:message];
        [alert runModal];
    }
    [[self window] makeFirstResponder:self];
}
- (NSData *)currentBuffer {
    uint8_t bytes[16384];
    int32_t n = xy_host_buffer_copy(bytes, sizeof(bytes));
    return n >= 0 ? [NSData dataWithBytes:bytes length:(NSUInteger)n] : nil;
}
- (IBAction)editSource:(id)sender {
    (void)sender;
    if (_reading) [self leaveReader];
    _home.hidden=YES;
    if (_editingSource) {
        _sourceDraft = [self currentBuffer];
        xy_host_source_leave();
        _editingSource = false;
        _is_vertical = _savedVertical;
        _font_size = _savedFontSize;
        [self applyViewSettings];
    } else {
        NSData *source = _sourceDraft ?: [NSData dataWithBytes:g_workspace_source length:g_workspace_source_len];
        if (!xy_host_source_enter([source bytes], (uint32_t)[source length])) {
            [self workspaceNotice:@"Cannot open source buffer" error:YES]; return;
        }
        _editingSource = true;
        _savedVertical = _is_vertical;
        _savedFontSize = _font_size;
        _is_vertical = false;
        _font_size = 25;
        [self applyViewSettings];
    }
    _selectAll = false;
    [self workspaceNotice:_editingSource ? @"user/init.scm — edit, then Apply & Save (⌘S). ⌘A / ⌘V supported." : @"Document — Run Command (⌘R) invokes the active Scheme definition." error:NO];
}
- (IBAction)applySource:(id)sender {
    (void)sender;
    if (!_editingSource) { [self saveDocument]; return; }
    NSData *source = [self currentBuffer];
    if (!source) { [self workspaceNotice:@"Open Source (⌘E) to edit user/init.scm first." error:NO]; return; }
    bool ok = workspace_apply([source bytes], (uint32_t)[source length]);
    if (ok) _sourceDraft = source;
    [self workspaceNotice:[NSString stringWithUTF8String:g_workspace_status] error:!ok];
}
- (IBAction)runCommand:(id)sender {
    (void)sender;
    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:@"Run Scheme Command"];
    [alert setInformativeText:@"Enter a registered command or a zero-argument function name. The default is stamp."];
    NSTextField *input = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 360, 24)];
    [input setStringValue:@"stamp"];
    [alert setAccessoryView:input];
    [alert addButtonWithTitle:@"Run"];
    [alert addButtonWithTitle:@"Cancel"];
    [[alert window] setInitialFirstResponder:input];
    if ([alert runModal] != NSAlertFirstButtonReturn) return;
    // Preserve an unfinished source draft and run commands against the document.
    if (_reading) [self resumeDocument:nil];
    if (_editingSource) [self editSource:nil];
    const char *name = [[input stringValue] UTF8String];
    uint8_t out[256];
    int32_t n = xy_host_live_run((const uint8_t *)name, (uint32_t)strlen(name), true, out, sizeof(out));
    if (n < 0) workspace_scheme_error();
    else _documentDirty=YES;
    NSString *message = n < 0 ? [NSString stringWithUTF8String:g_workspace_status] :
        [NSString stringWithFormat:@"%@: %@", [input stringValue], [[NSString alloc] initWithBytes:out length:(NSUInteger)n encoding:NSUTF8StringEncoding]];
    [self workspaceNotice:message error:n < 0];
}
- (BOOL)hasSourceChanges {
    NSData *draft = _editingSource ? [self currentBuffer] : _sourceDraft;
    return draft && ![draft isEqualToData:[NSData dataWithBytes:g_workspace_source length:g_workspace_source_len]];
}
- (BOOL)confirmDiscardSource {
    if (![self hasSourceChanges]) return YES;
    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:@"Discard unapplied source edits?"];
    [alert setInformativeText:@"The saved revision remains available. Choose Keep Editing to return to your draft."];
    [alert addButtonWithTitle:@"Keep Editing"];
    [alert addButtonWithTitle:@"Discard Draft"];
    return [alert runModal] == NSAlertSecondButtonReturn;
}
- (BOOL)windowShouldClose:(NSWindow *)sender {
    (void)sender;
    if (![self confirmDiscardSource]) return NO;
    if (_reading) [self leaveReader];
    if (_editingSource) [self editSource:nil];
    if (![self confirmDocumentReplacement]) return NO;
    [NSApp stop:nil];
    return YES;
}
- (void)windowDidChangeBackingProperties:(NSNotification *)notification {
    (void)notification;
    NSWindow *window = [self window];
    CGFloat scale = [window backingScaleFactor];
    if (scale <= 0) return;
    CGFloat viewHeight = MAX(500, _fb_height / scale);
    CGFloat delta = viewHeight - NSHeight([self frame]);
    CGFloat width = MAX(1040, _fb_width / scale);
    NSView *root = [window contentView];
    [window setContentSize:NSMakeSize(width, viewHeight + 76)];
    [root setFrameSize:NSMakeSize(width, viewHeight + 76)];
    for (NSView *child in [root subviews]) {
        if (child == self || child == _home || child == _readingBar) continue;
        NSRect frame = [child frame]; frame.origin.y += delta; [child setFrame:frame];
    }
    [self setFrameSize:NSMakeSize(width, viewHeight)];
    [self setNeedsDisplay:YES];
}
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    (void)sender;
    if (![self confirmDiscardSource]) return NSTerminateCancel;
    if (_reading) [self leaveReader];
    if (_editingSource) [self editSource:nil];
    return [self confirmDocumentReplacement] ? NSTerminateNow : NSTerminateCancel;
}
- (IBAction)reloadSource:(id)sender {
    (void)sender;
    if (![self confirmDiscardSource]) return;
    bool ok = workspace_reload();
    if (ok) {
        bool editing = _editingSource;
        if (editing) [self editSource:nil];
        _sourceDraft = nil;
        if (editing) [self editSource:nil];
    }
    [self workspaceNotice:[NSString stringWithUTF8String:g_workspace_status] error:!ok];
}
- (IBAction)restoreSource:(id)sender {
    (void)sender;
    if (![self confirmDiscardSource]) return;
    int64_t revisions[XY_HISTORY_LIMIT];
    int32_t count = xy_workspace_history(g_workspace, revisions, XY_HISTORY_LIMIT);
    if (count < 0) { workspace_db_error(); [self workspaceNotice:[NSString stringWithUTF8String:g_workspace_status] error:YES]; return; }
    if (!count) { [self workspaceNotice:@"No saved revisions yet." error:NO]; return; }
    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:@"Restore Source Revision"];
    [alert setInformativeText:@"Select a saved revision. It becomes active now and on the next launch. All saved revisions remain in history."];
    NSPopUpButton *picker = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 360, 28) pullsDown:NO];
    for (int32_t i = 0; i < count; i++) {
        [picker addItemWithTitle:[NSString stringWithFormat:@"Revision %lld%@", (long long)revisions[i], revisions[i] == g_workspace_revision ? @" (current)" : @""]];
    }
    [alert setAccessoryView:picker];
    [alert addButtonWithTitle:@"Restore"];
    [alert addButtonWithTitle:@"Cancel"];
    if ([alert runModal] != NSAlertFirstButtonReturn) return;
    bool ok = workspace_select(revisions[[picker indexOfSelectedItem]]);
    if (ok) {
        bool wasEditing = _editingSource;
        if (wasEditing) [self editSource:nil];
        _sourceDraft = nil;
        if (wasEditing) [self editSource:nil];
    }
    [self workspaceNotice:[NSString stringWithUTF8String:g_workspace_status] error:!ok];
}
- (void)insertRawText:(NSString *)text {
    if (_learning) {
        NSData *bytes=[text dataUsingEncoding:NSUTF8StringEncoding];
        if (bytes && xy_host_learning_insert(bytes.bytes,(uint32_t)bytes.length,_selectAll)) _selectAll=NO;
        [self setNeedsDisplay:YES]; return;
    }

    if (_reading || !_home.hidden) return;
    NSData *bytes = [text dataUsingEncoding:NSUTF8StringEncoding];
    bool ok = bytes && (_selectAll ? xy_host_buffer_replace([bytes bytes], (uint32_t)[bytes length]) : xy_host_insert_text([bytes bytes], (uint32_t)[bytes length]));
    _selectAll = false;
    if (ok && !_editingSource) _documentDirty=YES;
    if (ok && _editingSource) _workspaceMessage = @"Source draft changed — Apply & Save (⌘S).";
    if (!ok) [self workspaceNotice:@"Text could not be inserted (invalid input or buffer/undo capacity)." error:YES];
    [self setNeedsDisplay:YES];
}

- (BOOL)performKeyEquivalent:(NSEvent *)event {
    NSEventModifierFlags flags = [event modifierFlags] & NSEventModifierFlagDeviceIndependentFlagsMask;
    if ((flags & NSEventModifierFlagCommand) != 0 || (flags & NSEventModifierFlagControl) != 0) {
        NSString *chars = [event charactersIgnoringModifiers];
        if ([chars length] > 0) {
            unichar c = [chars characterAtIndex:0];
            if (_learning) {
                if (c=='r' || c=='R' || c=='l' || c=='L') { [self runLearning:nil]; return YES; }
                if (c=='a' || c=='A') { _selectAll=YES; return YES; }
                if (c=='z' || c=='Z') { (void)xy_host_learning_action(4); [self setNeedsDisplay:YES]; return YES; }
                if (c=='v' || c=='V') {
                    NSString *text=[[NSPasteboard generalPasteboard] stringForType:NSPasteboardTypeString];
                    if (text) [self insertRawText:text]; return YES;
                }
            }

            if (c == 'q' || c == 'Q') { [NSApp terminate:nil]; return YES; }
            if (c == '0') { [self showHome:nil]; return YES; }
            if (c == 'n' || c == 'N') { [self newDocument:nil]; return YES; }
            if (c == 'o' || c == 'O') { [self openDocument:nil]; return YES; }
            if (c == 'l' || c == 'L') { [self reloadSource:nil]; return YES; }
            if (c == 'e' || c == 'E') { [self editSource:nil]; return YES; }
            if (c == 's' || c == 'S') { [self applySource:nil]; return YES; }
            if (c == 'r' || c == 'R') { [self runCommand:nil]; return YES; }
            if (c == 'b' || c == 'B') { [self restoreSource:nil]; return YES; }
            if (c == 'a' || c == 'A') { if (_reading || !_home.hidden) return YES; _selectAll = true; [self workspaceNotice:@"Entire buffer selected — type or paste to replace." error:NO]; return YES; }
            if (c == 'v' || c == 'V') {
                NSString *text = [[NSPasteboard generalPasteboard] stringForType:NSPasteboardTypeString];
                if (text) [self insertRawText:text]; return YES;
            }
            if (!_home.hidden) return YES;
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
    if (_learning) {
        if (keyCode==53) { [self backToReading:nil]; return; }
        if (keyCode>=123 && keyCode<=126) {
            xy_host_learning_key(keyCode==123 ? 130 : keyCode==124 ? 131 : keyCode==125 ? 129 : 128);
        } else {
            NSString *text=event.characters;
            if ([text isEqualToString:@"\x7f"]) {
                if (_selectAll) [self insertRawText:@""]; else xy_host_learning_key(8);
            } else if (text.length) [self insertRawText:[text isEqualToString:@"\r"] ? @"\n" : text];
        }
        [self setNeedsDisplay:YES]; return;
    }

    if (!_home.hidden) return;
    if (_reading) {
        if ([[event charactersIgnoringModifiers] isEqualToString:@"e"]) { [self showExamples:nil]; return; }
        if (keyCode==53) { [self showHome:nil]; return; }
        if (keyCode==123 || keyCode==126 || keyCode==116) [self previousPage:nil];
        if (keyCode==124 || keyCode==125 || keyCode==121 || keyCode==49) [self nextPage:nil];
        return;
    }
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
    if (_editingSource || _selectAll) {
        if (len == 1 && (utf8[0] == 0x7F || utf8[0] == 0x08)) {
            if (_selectAll) [self insertRawText:@""];
            else eval_sexp_checked("(buffer/delete-backward!)");
        } else if (len == 1 && (utf8[0] == '\r' || utf8[0] == '\n')) [self insertRawText:@"\n"];
        else if (len == 1 && utf8[0] == 0x1B) { _selectAll = false; }
        else [self insertRawText:chars];
        [self setNeedsDisplay:YES]; return;
    }
    if (len == 1) {
        uint8_t ch = (uint8_t)utf8[0];
        if (ch == 0x7F) ch = 0x08; // Backspace
        if (xy_host_handle_key(ch)) _documentDirty=YES;
    } else {
        // Multi-byte UTF-8 character input (e.g. macOS IME or paste)
        [self insertRawText:chars];
    }
    [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    if (_workspaceMessage) {
        NSString *line = _reading ? _workspaceMessage : [NSString stringWithFormat:@"%@ r%lld: %@", _editingSource ? @"user/init.scm" : @"Document", (long long)g_workspace_revision, _workspaceMessage];
        NSData *bytes = [line dataUsingEncoding:NSUTF8StringEncoding];
        if ([bytes length] <= 256) xy_host_set_status([bytes bytes], (uint32_t)[bytes length]);
    }
    int32_t rendered = xy_host_render_rgba8(_rgba_buf, _fb_width, _fb_height, _fb_width * 4, _theme_id);
    if (rendered < 0) {
        uint8_t error[128];
        uint32_t n = xy_host_render_error(error, sizeof(error));
        _workspaceMessage = [NSString stringWithFormat:@"Display error: %.*s", (int)n, error];
    }

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
    // A target pixel maps to exactly one backing pixel, including Retina.
    // Only the native host chrome uses point units and platform text rendering.
    const CGFloat pointWidth = NSWidth([self bounds]);
    NSRect backingBounds = [self convertRectToBacking:[self bounds]];
    NSRect targetPixels = NSMakeRect(floor((NSWidth(backingBounds) - _fb_width) / 2),
        floor((NSHeight(backingBounds) - _fb_height) / 2), _fb_width, _fb_height);
    NSRect canvasRect = [self convertRectFromBacking:targetPixels];
    [[NSColor colorWithCalibratedWhite:_theme_id ? 0.10 : 0.91 alpha:1] setFill];
    NSRectFill(NSMakeRect(0, 0, pointWidth, NSHeight([self bounds])));
    CGContextSetInterpolationQuality(viewCtx, kCGInterpolationNone);
    CGContextSetShouldAntialias(viewCtx, false);
    CGContextDrawImage(viewCtx, canvasRect, img);

    CGImageRelease(img);
    CGContextRelease(bmp);
    CGColorSpaceRelease(cs);


}

@end

// ============================================================================
// Main Entrypoint
// ============================================================================

int main(int argc, const char **argv) {
    if (argc >= 2 && strcmp(argv[1], "--workspace-cli") == 0) return workspace_cli(argc, argv);
    const char *workspace_path = NULL;
    bool safe_workspace = false;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--workspace") == 0 && i + 1 < argc) workspace_path = argv[++i];
        else if (strcmp(argv[i], "--safe") == 0) safe_workspace = true;
    }
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

    bool external_fonts = true;
    NSString *resourceRoot=[[NSBundle mainBundle] resourcePath];
    if (![[NSFileManager defaultManager] fileExistsAtPath:[resourceRoot stringByAppendingPathComponent:@"fonts/BunsenMincho-Regular.ttf"]])
        resourceRoot=[[NSString stringWithUTF8String:argv[0]] stringByDeletingLastPathComponent];
    bool bundled_fonts = [[NSFileManager defaultManager] fileExistsAtPath:[resourceRoot stringByAppendingPathComponent:@"fonts/BunsenMincho-Regular.ttf"]];
    NSString *bundledMincho[3], *bundledGothic[3];
    NSArray *layers=@[@"",@"Ext",@"PUP"];
    for (int i=0;i<3;i++) {
        bundledMincho[i]=[resourceRoot stringByAppendingPathComponent:[NSString stringWithFormat:@"fonts/BunsenMincho%@-Regular.ttf",layers[i]]];
        bundledGothic[i]=[resourceRoot stringByAppendingPathComponent:[NSString stringWithFormat:@"fonts/BunsenGothic%@-Regular.ttf",layers[i]]];
        // Packaged sample coverage makes the app independent of the developer's font directory.
        if ([[NSFileManager defaultManager] fileExistsAtPath:bundledMincho[i]]) mincho_paths[i]=bundledMincho[i].fileSystemRepresentation;
        if ([[NSFileManager defaultManager] fileExistsAtPath:bundledGothic[i]]) gothic_paths[i]=bundledGothic[i].fileSystemRepresentation;
    }
    FontFileCtx mincho_ctxs[3];
    CSliceReaderDesc mincho_descs[3];
    FontFileCtx gothic_ctxs[3];
    CSliceReaderDesc gothic_descs[3];

    for (int i = 0; i < 3; i++) {
        mincho_ctxs[i].path = mincho_paths[i];
        mincho_ctxs[i].fd = open(mincho_paths[i], O_RDONLY);
        if (mincho_ctxs[i].fd < 0) {
            external_fonts = false;
        }
        mincho_descs[i].ctx = &mincho_ctxs[i];
        mincho_descs[i].read_fn = posix_pread_callback;

        gothic_ctxs[i].path = gothic_paths[i];
        gothic_ctxs[i].fd = open(gothic_paths[i], O_RDONLY);
        if (gothic_ctxs[i].fd < 0) {
            external_fonts = false;
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
    if (!xy_host_init(mincho_descs, bundled_fonts ? 1 : (external_fonts ? 3 : 0), gothic_descs, bundled_fonts ? 1 : (external_fonts ? 3 : 0))) {
        fprintf(stderr, "xy_host_init failed!\n");
        return 1;
    }
    xy_host_set_omni_callback(NULL, gjs_omni_query_callback);
    printf(
        "[xy_mac_host] Initialized 6 Bunsen OpenType faces (240 MiB on disk) via pread: %llu calls, %llu bytes read\n",
        (unsigned long long)(g_pread_calls - init_calls_before),
        (unsigned long long)(g_pread_bytes - init_bytes_before)
    );

    const uint32_t W = 1280;
    const uint32_t H = 720;
    xy_host_set_viewport(W, H);

    // Check for `--snapshot <dir>` mode
    if (argc >= 3 && strcmp(argv[1], "--snapshot") == 0) {
        const char *out_dir = argv[2];
        NSError *directoryError = nil;
        if (![[NSFileManager defaultManager] createDirectoryAtPath:[NSString stringWithUTF8String:out_dir]
                                      withIntermediateDirectories:YES attributes:nil error:&directoryError]) {
            fprintf(stderr, "Snapshot directory: %s\n", [[directoryError description] UTF8String]);
            return 1;
        }
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
        if (!save_rgba_png(path1, rgba, W, H)) { free(rgba); return 1; }
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
        if (!save_rgba_png(path2, rgba, W, H)) { free(rgba); return 1; }
        printf(
            "[Scene 2: Vertical Mincho 36px]   quads=%d, outline_misses=%u (+%u!), bitmap_misses=%u, pread_bytes=%llu -> %s\n",
            q2, om2, om2 - om1, bm2, (unsigned long long)(g_pread_bytes - bytes_before_s2), path2
        );

        // Scene 3: Live S-expression switch to Bunsen Gothic 34px Vertical (Hacker Dark theme)
        eval_sexp_checked("(view/set! #:font 'bunsen-gothic #:size 34 #:direction 'vertical #:line-gap 20 #:theme 'dark)");
        uint64_t bytes_before_s3 = g_pread_bytes;
        int32_t q3 = xy_host_render_rgba8(rgba, W, H, W * 4, 1);
        uint32_t om3 = 0, bm3 = 0;
        xy_host_cache_stats(&om3, &bm3);
        char path3[512];
        snprintf(path3, sizeof(path3), "%s/xy_scene3_vertical_gothic_dark.png", out_dir);
        if (!save_rgba_png(path3, rgba, W, H)) { free(rgba); return 1; }
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
        if (!workspace_path) {
            NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/nihos/xy"];
            NSError *error = nil;
            if (![[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:&error]) {
                fprintf(stderr, "%s\n", [[error localizedDescription] UTF8String]); return 1;
            }
            workspace_path = [[dir stringByAppendingPathComponent:@"workspace.db"] fileSystemRepresentation];
        }
        if (!workspace_start(workspace_path, safe_workspace)) {
            fprintf(stderr, "Workspace: %s\n", g_workspace_status);
            // Native editing remains available; writes report the database error.
        }

        // workspace_start resets editor defaults; restore the actual host viewport.
        xy_host_set_viewport(W, H);
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];

        // The live workspace opens an empty document; source has its own buffer.
        eval_sexp_checked("(view/set! #:font 'bunsen-mincho #:size 32 #:direction 'vertical #:line-gap 18)");

        const CGFloat toolbarH = 76.0;
        const CGFloat statusH = 0.0;
        CGFloat backingScale = [[NSScreen mainScreen] backingScaleFactor];
        if (backingScale <= 0) backingScale = 1;
        const CGFloat canvasH = MAX(500, H / backingScale);
        const CGFloat windowW = MAX(1040, W / backingScale);
        NSRect winRect = NSMakeRect(120, 120, windowW, canvasH + toolbarH + statusH);
        NSWindow *window = [[NSWindow alloc]
            initWithContentRect:winRect
                      styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable)
                        backing:NSBackingStoreBuffered
                          defer:NO];
        [window setTitle:@"xy — ホーム"];

        NSView *root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, windowW, canvasH + toolbarH + statusH)];
        XyCanvasView *view = [[XyCanvasView alloc] initWithFrame:NSMakeRect(0, 0, windowW, canvasH + statusH) width:W height:H];
        [root addSubview:view];
        struct { NSString *title; SEL action; CGFloat width; } workspaceBtns[] = {
            { @"ホーム (⌘0)", @selector(showHome:), 120 },
            { @"Source (⌘E)", @selector(editSource:), 130 },
            { @"Apply & Save (⌘S)", @selector(applySource:), 180 },
            { @"Run Command (⌘R)", @selector(runCommand:), 190 },
            { @"History (⌘B)", @selector(restoreSource:), 140 },
            { @"Reload (⌘L)", @selector(reloadSource:), 130 },
        };
        CGFloat wx = 10;
        for (size_t i = 0; i < sizeof(workspaceBtns) / sizeof(workspaceBtns[0]); i++) {
            NSButton *button = [[NSButton alloc] initWithFrame:NSMakeRect(wx, canvasH + statusH + 43, workspaceBtns[i].width, 28)];
            [button setTitle:workspaceBtns[i].title]; [button setBezelStyle:NSBezelStyleRounded];
            [button setTarget:view]; [button setAction:workspaceBtns[i].action];
            [root addSubview:button]; wx += workspaceBtns[i].width + 6;
        }
        [view workspaceNotice:[NSString stringWithUTF8String:g_workspace_status] error:NO];

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
            NSButton *b = [[NSButton alloc] initWithFrame:NSMakeRect(bx, canvasH + statusH + 5.0, btns[i].width, 28.0)];
            [b setTitle:btns[i].title];
            [b setBezelStyle:NSBezelStyleRounded];
            [b setTarget:view];
            [b setAction:btns[i].action];
            [root addSubview:b];
            bx += btns[i].width + 6.0;
        }

        [view installHomeIn:root];
        [view applyViewSettings];
        [view showHome:nil];
        [window setDelegate:view];
        [NSApp setDelegate:view];
        [window setContentView:root];
        [window makeFirstResponder:view];
        [window makeKeyAndOrderFront:nil];
        [NSApp activateIgnoringOtherApps:YES];
        [NSApp run];
        xy_workspace_close(g_workspace);
        if (g_db) sqlite3_close(g_db);
    }
    return 0;
}
