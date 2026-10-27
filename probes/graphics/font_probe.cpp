#include "lazy_pool.h"
#include <ft2build.h>
#include FT_FREETYPE_H
#include FT_MODULE_H
#include FT_SYSTEM_H
#include <hb.h>
#include <hb-ft.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// Only this worker calls the libraries. Multiple client sessions stay open.
// HB process-shared allocations belong to owner 0, never a dying client.
static LazyPool pool;
static size_t measured_peak;
static void check(bool value, const char *what) {
    if (!value) { fprintf(stderr, "graphics probe failed: %s\n", what); abort(); }
}
extern "C" void *study_malloc(size_t n) { return pool.allocate(0, n); }
extern "C" void *study_calloc(size_t n, size_t size) {
    if (size && n > SIZE_MAX / size) return nullptr;
    void *p = study_malloc(n * size); if (p) memset(p, 0, n * size); return p;
}
extern "C" void *study_realloc(void *p, size_t n) { return pool.resize(0, p, n); }
extern "C" void study_free(void *p) { check(pool.release(0, p), "HB free ownership"); }

struct Session {
    static constexpr unsigned slots = 16, page = 16384;
    unsigned owner;
    FILE *file = nullptr;
    uint32_t length = 0, clock = 0, base[slots] = {}, valid[slots] = {}, stamp[slots] = {};
    unsigned char *cache = nullptr;
    FT_MemoryRec_ memory = {};
    FT_StreamRec stream = {};
    FT_Library library = nullptr;
    FT_Face face = nullptr;
    hb_font_t *font = nullptr;
    size_t source_bytes = 0, source_reads = 0;
    explicit Session(unsigned client) : owner(client) { memory.user = this; }
    Session(const Session &) = delete;
    Session &operator=(const Session &) = delete;
    ~Session() { close(); }
    static void *alloc(FT_Memory m, long n) {
        Session *s = (Session *)m->user;
        return n > 0 ? pool.allocate(s->owner, (size_t)n) : nullptr;
    }
    static void free(FT_Memory m, void *p) {
        check(pool.release(((Session *)m->user)->owner, p), "FT free ownership");
    }
    static void *resize(FT_Memory m, long, long n, void *p) {
        Session *s = (Session *)m->user;
        if (n <= 0) { free(m, p); return nullptr; }
        return pool.resize(s->owner, p, (size_t)n);
    }
    static unsigned long read(FT_Stream st, unsigned long offset, unsigned char *buffer, unsigned long count) {
        Session *s = (Session *)st->descriptor.pointer;
        if (offset > s->length || count > s->length - offset) return count ? 0 : 1;
        unsigned long done = 0;
        while (done < count) {
            unsigned at = (unsigned)(offset + done), slot = slots;
            for (unsigned i = 0; i < slots; ++i)
                if (s->valid[i] && at >= s->base[i] && at < s->base[i] + s->valid[i]) { slot = i; break; }
            if (slot == slots) {
                slot = 0;
                for (unsigned i = 0; i < slots; ++i) {
                    if (!s->valid[i]) { slot = i; break; }
                    if (s->stamp[i] < s->stamp[slot]) slot = i;
                }
                s->base[slot] = at & ~(page - 1u);
                unsigned n = s->length - s->base[slot]; if (n > page) n = page;
                if (fseek(s->file, (long)s->base[slot], SEEK_SET)) return done;
                if (fread(s->cache + slot * page, 1, n, s->file) != n) return done;
                s->valid[slot] = n; s->source_bytes += n; ++s->source_reads;
            }
            s->stamp[slot] = ++s->clock;
            unsigned in = at - s->base[slot], n = s->valid[slot] - in;
            if (n > count - done) n = (unsigned)(count - done);
            memcpy(buffer + done, s->cache + slot * page + in, n); done += n;
        }
        return done;
    }
    bool open(const char *path) {
        file = fopen(path, "rb"); if (!file) return false;
        if (fseek(file, 0, SEEK_END)) return false;
        long size = ftell(file); if (size <= 0 || (unsigned long)size > UINT32_MAX) return false;
        length = (uint32_t)size;
        cache = (unsigned char *)pool.allocate(owner, slots * page); if (!cache) return false;
        memory.alloc = alloc; memory.free = free; memory.realloc = resize;
        if (FT_New_Library(&memory, &library)) return false;
        FT_Add_Default_Modules(library);
        if (pool.failures) return false;
        stream.size = length; stream.read = read; stream.descriptor.pointer = this;
        FT_Open_Args args = {}; args.flags = FT_OPEN_STREAM; args.stream = &stream;
        if (FT_Open_Face(library, &args, 0, &face) || pool.failures) return false;
        if (FT_Select_Charmap(face, FT_ENCODING_UNICODE)) return false;
        font = hb_ft_font_create_referenced(face);
        hb_ft_font_set_load_flags(font, FT_LOAD_DEFAULT | FT_LOAD_NO_BITMAP);
        return font != hb_font_get_empty() && !pool.failures;
    }
    void close() {
        if (font) { hb_font_destroy(font); font = nullptr; }
        if (face) { FT_Done_Face(face); face = nullptr; }
        if (library) { FT_Done_Library(library); library = nullptr; }
        if (cache) { check(pool.release(owner, cache), "source cache free"); cache = nullptr; }
        if (file) { fclose(file); file = nullptr; }
    }
    bool draw(bool vertical, unsigned pixels, uint32_t *hash_out) {
        if (!font) return false;
        uint32_t hash = 2166136261u;
        hb_buffer_t *buffer = hb_buffer_create();
        bool good = buffer != hb_buffer_get_empty();
        for (unsigned ruby = 0; good && ruby < 2; ++ruby) {
            unsigned px = ruby ? pixels / 2 : pixels;
            if (FT_Set_Pixel_Sizes(face, 0, px)) { good = false; break; }
            hb_ft_font_changed(font); hb_font_set_scale(font, (int)px * 64, (int)px * 64);
            hb_font_set_ppem(font, px, px);
            hb_buffer_clear_contents(buffer);
            hb_buffer_add_utf8(buffer, ruby ? "わがはい　とうきょう" :
                "吾輩は猫である。名前はまだ無い。東京へ行く。第12章（明治時代）", -1, 0, -1);
            hb_buffer_set_direction(buffer, vertical ? HB_DIRECTION_TTB : HB_DIRECTION_LTR);
            hb_buffer_set_script(buffer, HB_SCRIPT_HAN);
            hb_buffer_set_language(buffer, hb_language_from_string("ja", -1));
            hb_feature_t feature; hb_feature_from_string("ruby=1", -1, &feature);
            hb_shape(font, buffer, ruby ? &feature : nullptr, ruby ? 1u : 0u);
            if (!hb_buffer_allocation_successful(buffer) || pool.failures) { good = false; break; }
            unsigned count = 0;
            hb_glyph_info_t *info = hb_buffer_get_glyph_infos(buffer, &count);
            hb_glyph_position_t *pos = hb_buffer_get_glyph_positions(buffer, nullptr);
            if (!count) { good = false; break; }
            for (unsigned i = 0; good && i < count; ++i) {
                unsigned gid = info[i].codepoint;
                if (!gid || FT_Load_Glyph(face, gid, FT_LOAD_DEFAULT | FT_LOAD_NO_BITMAP) ||
                    FT_Render_Glyph(face->glyph, FT_RENDER_MODE_NORMAL) || pool.failures) { good = false; break; }
                hash = (hash ^ gid) * 16777619u;
                hash = (hash ^ (uint32_t)pos[i].x_advance) * 16777619u;
                hash = (hash ^ (uint32_t)pos[i].y_advance) * 16777619u;
                FT_Bitmap &bm = face->glyph->bitmap;
                for (unsigned y = 0; y < bm.rows; ++y)
                    for (unsigned x = 0; x < bm.width; ++x) {
                        size_t row = bm.pitch >= 0 ? y : bm.rows - 1 - y;
                        size_t pitch = (size_t)(bm.pitch >= 0 ? bm.pitch : -bm.pitch);
                        hash = (hash ^ bm.buffer[row * pitch + x]) * 16777619u;
                    }
            }
        }
        hb_buffer_destroy(buffer);
        if (pool.failures) good = false;
        // The caller publishes nothing on failure, even if a library tolerated OOM.
        if (good) *hash_out = hash;
        return good;
    }
};

static bool trial(const char *path, size_t fail, uint32_t expected, size_t *attempts) {
    pool.begin_operation(fail);
    bool success;
    uint32_t hash = 0;
    {
        Session second(2);
        success = second.open(path) && second.draw(true, 24, &hash);
        if (success && expected) check(hash == expected, "second session unchanged pixels");
    }
    if (pool.peak > measured_peak) measured_peak = pool.peak;
    *attempts = pool.attempts;
    check(pool.valid() && pool.owner_reserved[2] == 0, "second session fully reclaimed");
    return success && !pool.failures;
}

int main(int argc, char **argv) {
    if (argc != 3) { fprintf(stderr, "usage: font-probe gothic.ttf mincho.ttf\n"); return 2; }
    check(pool.reserved == 0, "no eager reservation");
    // Pin language process-global state to the service owner before client use.
    hb_language_from_string("ja", -1);
    size_t idle_initial = pool.reserved;
    pool.begin_operation();
    Session first(1);
    check(first.open(argv[1]), "first session open");
    uint32_t first_h = 0, first_v = 0;
    check(first.draw(false, 24, &first_h) && first.draw(true, 24, &first_v), "first body/ruby draw");
    size_t single_reserved = pool.reserved;
    measured_peak = pool.peak;
    uint32_t expected_second = 0;
    pool.begin_operation();
    {
        Session second(2); check(second.open(argv[2]), "simultaneous second session open");
        check(second.draw(true, 24, &expected_second), "second body/ruby draw");
        uint32_t again = 0; check(first.draw(true, 24, &again) && again == first_v, "both open; first survives");
        if (pool.peak > measured_peak) measured_peak = pool.peak;
    }
    size_t after_second_close = pool.reserved;
    check(pool.owner_reserved[2] == 0, "closed client has no backing pages");
    size_t attempts = 0;
    check(trial(argv[2], 0, expected_second, &attempts), "warm baseline trial");
    size_t baseline_attempts = attempts;
    size_t normal_two_client_peak = measured_peak;
    for (size_t failure = 1; failure <= baseline_attempts; ++failure) {
        bool adopted = trial(argv[2], failure, expected_second, &attempts);
        check(pool.failures && !adopted, "injected OOM never publishes a partial result");
        pool.begin_operation();
        uint32_t still = 0;
        check(first.draw(true, 24, &still) && still == first_v, "OOM does not damage surviving client");
        if (pool.peak > measured_peak) measured_peak = pool.peak;
        if (!(failure % 128)) fprintf(stderr, "graphics OOM %zu/%zu\n", failure, baseline_attempts);
    }
    check(trial(argv[2], 0, expected_second, &attempts), "reopen after all failures");
    for (unsigned cycle = 0; cycle < 32; ++cycle)
        check(trial(argv[2], 0, expected_second, &attempts), "repeat open/close");
    size_t two_client_stress_peak = measured_peak;
    pool.begin_operation();
    void *background = pool.allocate(3, 1024 * 1024);
    check(background != nullptr, "independent background allocation");
    memset(background, 0xa3, 1024 * 1024);
    check(!trial(argv[2], 0, expected_second, &attempts) && pool.failures,
        "shared memory pressure refuses only new session");
    pool.begin_operation(); uint32_t pressure_hash = 0;
    check(first.draw(true, 24, &pressure_hash) && pressure_hash == first_v,
        "existing session survives background pressure");
    for (size_t i = 0; i < 1024 * 1024; ++i)
        check(((unsigned char *)background)[i] == 0xa3, "background allocation intact");
    check(pool.release(3, background) && pool.owner_reserved[3] == 0, "background pages returned");
    check(trial(argv[2], 0, expected_second, &attempts), "new session opens after pressure clears");
    pool.begin_operation(); uint32_t final_h = 0;
    check(first.draw(false, 24, &final_h) && final_h == first_h, "first survives all trials");
    first.close();
    check(pool.owner_reserved[1] == 0 && pool.owner_reserved[2] == 0 && pool.valid(), "all clients reclaimed");
    printf("{\"status\":\"pass\",\"scope\":\"host FT+HB memory/lifetime probe, not native GUI\","
        "\"startup_reserved\":0,\"initial_service_reserved\":%zu,\"single_client_reserved\":%zu,"
        "\"two_client_normal_peak_reserved\":%zu,\"two_client_stress_peak_reserved\":%zu,"
        "\"including_background_pressure_peak\":%zu,\"pressure_recovery\":true,"
        "\"after_second_close\":%zu,\"after_all_clients_close\":%zu,"
        "\"shared_live_payload_after_close\":%zu,\"client_backing_after_close\":0,"
        "\"oom_points\":%zu,\"reopen_cycles\":32,\"controller_host_bytes\":%zu,"
        "\"gothic_horizontal_hash\":%u,\"gothic_vertical_hash\":%u,\"mincho_vertical_hash\":%u}\n",
        idle_initial, single_reserved, normal_two_client_peak, two_client_stress_peak,
        measured_peak, after_second_close, pool.reserved,
        pool.live_bytes(0), baseline_attempts, sizeof(pool), first_h, first_v, expected_second);
}
