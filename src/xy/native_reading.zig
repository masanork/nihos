//! Tab5 scenes and bounded page fitting over the shared text renderer.
const std = @import("std");
const layout = @import("viewport_layout");
const adapter = @import("render_adapter.zig");
const session_module = @import("render_session.zig");
const rotated = @import("rotated_surface");
const catalog = @import("catalog.zig");
const reader = @import("reader.zig");
const protocol = @import("render_protocol.zig");
pub const page_glyphs = 2048;
pub const Session = session_module.SizedSession(page_glyphs);

pub const Page = struct {
    text: []const u8,
    readings: [2048]u8,
    reading_len: usize = 0,
    spans: [128]protocol.RubySpan,
    count: usize = 0,
    codes: [64]layout.CodeSpan,
    code_count: usize = 0,
    book_prose: bool = false,
};

pub fn prepare(instance: *Session, pack: catalog.Pack, entry: catalog.Entry, offset: u32, config: protocol.Config, page: *Page, chapter: u32) !void {
    return prepareViewport(instance, pack, entry, offset, config, page, chapter, 1280, 648);
}
pub fn prepareViewport(instance: *Session, pack: catalog.Pack, entry: catalog.Entry, offset: u32, config: protocol.Config, page: *Page, chapter: u32, width: u16, content_height: u16) !void {
    if (content_height <= @as(u16, config.style.body_px) + 2 * @as(u16, config.appearance.status_padding)) return error.ViewportTooSmall;
    if (offset >= entry.text.len or !@import("document.zig").isClusterBoundary(entry.text, offset)) return error.Range;
    var end: usize = offset;
    var clusters: usize = 0;
    while (end < entry.text.len and clusters < page_glyphs) : (clusters += 1) {
        const next = try @import("document.zig").nextClusterEnd(entry.text, end);
        if (next - offset > 4096) break;
        end = next;
    }
    var ruby_count: usize = 0;
    var ruby_bytes: usize = 0;
    var at: usize = 0;
    while (at < entry.ruby.len) : (at += 16) {
        const a = catalog.read(entry.ruby, at);
        const b = catalog.read(entry.ruby, at + 4);
        if (a < offset or a >= end) continue;
        ruby_count += 1;
        const n = catalog.read(entry.ruby, at + 12);
        if (b > end or ruby_count > page.spans.len or n > page.readings.len - ruby_bytes) {
            end = a;
            break;
        }
        ruby_bytes += n;
    }
    var style = config.style;
    style.viewport_width_px = width;
    style.viewport_height_px = content_height - @as(u16, style.body_px) - 2 * @as(u16, config.appearance.status_padding);
    const normal_faces = [_]layout.ttf.Face{ instance.faces[0], instance.faces[1 + @as(usize, style.style_id)] };
    const book_faces = [_]layout.ttf.Face{ instance.book_face, normal_faces[1] };
    const learning = if (try pack.learningBytes()) |bytes| try @import("learning_catalog.zig").Pack.init(bytes) else null;
    const styled = entry.book == 2 and learning != null and learning.?.style_count != 0;
    const family = layout.ttf.Family{ .faces = if (styled) &book_faces else &normal_faces, .code_faces = &normal_faces };
    if (styled) {
        style.style_id = 2 + style.style_id * 2;
        style.ruby_px = 0;
        style.line_gap_px = @min(style.line_gap_px, @max(2, style.body_px / 5));
    }
    while (end > offset) {
        if (styled) end = offset + reader.closeWord(entry.text[offset..], end - offset);
        // SAFETY: only the populated prefixes below are consumed; lengths start at zero.
        page.* = .{ .text = entry.text[offset..end], .readings = undefined, .spans = undefined, .codes = undefined, .book_prose = styled };
        at = 0;
        while (at < entry.ruby.len) : (at += 16) {
            const a = catalog.read(entry.ruby, at);
            const b = catalog.read(entry.ruby, at + 4);
            if (a < offset or b > end) continue;
            const text = try pack.slice(catalog.read(entry.ruby, at + 8), catalog.read(entry.ruby, at + 12));
            if (page.count == page.spans.len or text.len > page.readings.len - page.reading_len) return error.Capacity;
            @memcpy(page.readings[page.reading_len..][0..text.len], text);
            page.spans[page.count] = .{ .base_start = a - offset, .base_end = b - offset, .ruby_start = @intCast(page.reading_len), .ruby_end = @intCast(page.reading_len + text.len) };
            page.count += 1;
            page.reading_len += text.len;
        }
        try reader.validateBounded(4096, 2048, 128, page.text, page.readings[0..page.reading_len], page.spans[0..page.count]);
        var anns: [128]layout.ruby.Annotation = undefined;
        for (page.spans[0..page.count], 0..) |span, i| anns[i] = .{ .base = .{ .start = span.base_start, .end = span.base_end }, .ruby = .{ .start = span.ruby_start, .end = span.ruby_end } };
        if (styled) if (learning) |l| {
            while (try l.styleOnPage(chapter, offset, @intCast(end), @intCast(page.code_count))) |span| {
                if (page.code_count == page.codes.len) break;
                page.codes[page.code_count] = .{ .start = span.start, .end = span.end };
                page.code_count += 1;
            }
            if (try l.styleOnPage(chapter, offset, @intCast(end), @intCast(page.code_count)) != null) {
                end = offset + try reader.shorter(page.text, page.text.len, page.spans[0..page.count]);
                continue;
            }
        };
        const list = layout.layoutStyledParagraph(page_glyphs, 4096, 2048, session_module.Cache, &instance.cache, family, style, page.text, page.readings[0..page.reading_len], anns[0..page.count], &instance.scratch, &instance.placed, true, page.codes[0..page.code_count]) catch |err| switch (err) {
            error.BlockFull, error.Capacity, error.SpanTooWide => {
                end = offset + try reader.shorter(page.text, page.text.len, page.spans[0..page.count]);
                continue;
            },
            else => return err,
        };
        const fit = reader.visibleEnd(page.text.len, page.spans[0..page.count], list, style);
        if (fit == page.text.len) return;
        end = offset + fit;
    }
    return error.ViewportTooSmall;
}

fn label(instance: *Session, target: anytype, x: i32, y: i32, text: []const u8, size: u8, color: u16) !void {
    const family = layout.ttf.Family{ .faces = instance.faces[0..2] };
    var iterator = layout.ClusterIterator{ .text = text };
    var pen = x;
    while (try iterator.next()) |cl| {
        if (cl.base_cp == '\n') break;
        const glyph = try instance.cache.getOrRender(family, 0, cl.base_cp, cl.ivs_cp, size, false, &instance.scratch);
        if (pen + @as(i32, size) > @as(i32, @intCast(target.width)) - 16) break;
        const mask = adapter.surface.Mask{ .bytes = glyph.alpha, .width = glyph.metrics.width, .height = glyph.metrics.height, .stride = glyph.metrics.width };
        const baseline = y + @divTrunc(@as(i32, size) * 880 + 512, 1024);
        _ = target.blit(mask, pen + glyph.metrics.left_px, baseline - glyph.metrics.top_px, color);
        pen += @divTrunc(glyph.metrics.x_advance_26_6 + 32, 64);
    }
}
fn footer(instance: *Session, target: anytype, reading: bool, can_try: bool) !void {
    _ = target.fillRect(0, 648, 1280, 72, 0x2147);
    if (reading) {
        try label(instance, target, 24, 670, "ホーム", 24, 0xffff);
        try label(instance, target, 232, 670, "前へ", 24, 0xffff);
        try label(instance, target, 512, 670, "次へ", 24, 0xffff);
        if (can_try) try label(instance, target, 680, 670, "Try", 20, 0xffff);
        try label(instance, target, 792, 670, "目次", 24, 0xffff);
        try label(instance, target, 1060, 670, "設定", 24, 0xffff);
    } else try label(instance, target, 24, 670, "ホーム / Esc      前の一覧        次の一覧      矢印・Enter", 24, 0xffff);
}

/// Portrait navigation renders into the panel's native surface.
pub fn renderPortrait(instance: *Session, request: *const protocol.Request, pack: catalog.Pack) !void {
    const nav = request.navigation orelse return error.Range;
    if (nav.screen == .home) return renderPortraitHome(instance, request);
    const target = adapter.surface.Surface.init(request.frame[0..request.frame_length], 720, 1280, 1440) orelse return error.Geometry;
    nav.chapter_count = try pack.counts();
    _ = target.fillRect(0, 0, 720, 1280, 0xf7bd);
    switch (nav.screen) {
        .examples, .exercise => {
            const lessons = request.learning orelse return error.Range;
            return @import("learning_view.zig").renderPortrait(instance, request, lessons, nav.screen == .examples);
        },
        .settings => {
            try label(instance, target, 36, 40, "自分に合った読み心地に", 32, 0x2147);
            var number: [64]u8 = undefined;
            const line = try std.fmt.bufPrint(&number, "-          {d} px          +", .{request.config.style.body_px});
            try label(instance, target, 80, 178, line, 28, 0x2147);
            try label(instance, target, 80, 278, if (request.config.style.axis == 0) "横書き / 縦書き" else "縦書き / 横書き", 28, 0x2147);
            try label(instance, target, 80, 378, if (request.config.style.style_id == 0) "明朝 / ゴシック" else "ゴシック / 明朝", 28, 0x2147);
            try label(instance, target, 80, 478, "明るい紙面 / 暗い紙面", 28, 0x2147);
            try label(instance, target, 80, 578, "設定を反映して戻る", 28, 0x2147);
        },
        .chapters => {
            const titles = [_][]const u8{ "xyを使ってみる", "草枕 / 夏目漱石", "SICP / Scheme", "小さなOSを育てる" };
            try label(instance, target, 36, 32, titles[nav.book], 32, 0x2147);
            try label(instance, target, 36, 88, "目次 / 読みたい章を選んでください", 24, 0x528a);
            const top = (nav.selected_chapter / 8) * 8;
            var i: u16 = top;
            while (i < @min(top + 8, nav.chapter_count[nav.book])) : (i += 1) {
                const entry = try pack.chapter(nav.book, i);
                const y: i32 = 132 + @as(i32, i - top) * 110;
                if (i == nav.selected_chapter) _ = target.fillRect(24, y, 672, 90, 0x2147);
                try label(instance, target, 36, y + 30, entry.title, 24, if (i == nav.selected_chapter) 0xffff else 0x2147);
            }
        },
        .reading => {
            const entry = try pack.chapter(nav.book, nav.chapter);
            nav.text_length = @intCast(entry.text.len);
            var page: Page = undefined;
            try prepareViewport(instance, pack, entry, nav.offset, request.config.*, &page, nav.chapter, 720, 1208);
            var status: [256]u8 = undefined;
            const percent = @as(u64, nav.offset) * 100 / @max(1, entry.text.len);
            const line = try std.fmt.bufPrint(&status, "{s} / {d}%", .{ entry.title, percent });
            var req = request.*;
            req.navigation = null;
            req.reserved_bottom_px = 72;
            req.keyboard = 0;
            req.text = page.text.ptr;
            req.text_length = page.text.len;
            req.cursor = 0;
            req.show_cursor = 0;
            req.page_mode = 1;
            req.book_prose = @intFromBool(page.book_prose);
            req.code_spans = &page.codes;
            req.code_count = page.code_count;
            req.status = line.ptr;
            req.status_length = line.len;
            req.ruby_text = &page.readings;
            req.ruby_text_length = page.reading_len;
            req.ruby_spans = &page.spans;
            req.ruby_count = page.count;
            try instance.renderPortrait(&req);
            nav.end = nav.offset + @as(u32, @intCast(page.text.len));
            if (request.learning) |l| {
                if (nav.book == 2) {
                    try l.setPage(nav.chapter, nav.offset, nav.end);
                    nav.can_try = (try l.count()) > 0;
                } else {
                    l.page_valid = false;
                    nav.can_try = false;
                }
            } else nav.can_try = nav.book == 2 and page.code_count > 0;
        },
        .card_view => {
            _ = target.fillRect(24, 24, 672, 1060, 0xffff);
            _ = target.fillRect(24, 24, 672, 8, 0x2147);
            try label(instance, target, 48, 56, "マイナンバーカード 券面情報", 28, 0x2147);
            const data = &nav.card;
            if (data.valid) {
                try label(instance, target, 48, 140, "氏名", 20, 0x528a);
                try label(instance, target, 48, 178, if (data.name_len > 0) data.nameSlice() else "—", 30, 0x2147);
                try label(instance, target, 48, 260, "生年月日 / 性別", 20, 0x528a);
                var info: [48]u8 = undefined;
                const gender = if (std.mem.eql(u8, data.genderSlice(), "1")) "男" else if (std.mem.eql(u8, data.genderSlice(), "2")) "女" else data.genderSlice();
                const text = if (data.birth_len > 0) std.fmt.bufPrint(&info, "{s} / {s}", .{ data.birthSlice(), gender }) catch data.birthSlice() else "—";
                try label(instance, target, 48, 298, text, 26, 0x2147);
                try label(instance, target, 48, 390, "住所", 20, 0x528a);
                try label(instance, target, 48, 428, if (data.address_len > 0) data.addressSlice() else "—", 24, 0x2147);
            } else try label(instance, target, 48, 160, "カードデータがありません", 24, 0x528a);
            try label(instance, target, 48, 1060, "タップ / Esc: 戻る", 22, 0x528a);
        },
        .credits => {
            const entry = try pack.chapter(nav.book, nav.chapter);
            var req = request.*;
            req.navigation = null;
            req.keyboard = 0;
            req.reserved_bottom_px = 0;
            req.text = entry.credits.ptr;
            req.text_length = @min(4096, entry.credits.len);
            req.cursor = 0;
            req.show_cursor = 0;
            req.page_mode = 0;
            return instance.renderPortrait(&req);
        },
        else => return error.UnsupportedOrientation,
    }
    _ = target.fillRect(0, 1208, 720, 72, 0x2147);
    if (nav.screen == .reading) {
        for ([_]struct { x: i32, text: []const u8 }{ .{ .x = 8, .text = "Home" }, .{ .x = 128, .text = "前" }, .{ .x = 248, .text = "次" }, .{ .x = 368, .text = if (nav.can_try) "Try" else "" }, .{ .x = 488, .text = "目次" }, .{ .x = 608, .text = "設定" } }) |button| try label(instance, target, button.x, 1232, button.text, 20, 0xffff);
    } else if (nav.screen == .chapters) {
        try label(instance, target, 8, 1232, "Home", 20, 0xffff);
        try label(instance, target, 128, 1232, "前の一覧", 20, 0xffff);
        try label(instance, target, 368, 1232, "次の一覧", 20, 0xffff);
    } else try label(instance, target, 8, 1232, "Home", 20, 0xffff);
}

/// Portrait Home uses the panel's physical coordinates and shared card geometry.
/// Other navigation scenes remain landscape until explicitly adapted.
pub fn renderPortraitHome(instance: *Session, request: *const protocol.Request) !void {
    const nav = request.navigation orelse return error.Range;
    if (nav.screen != .home) return error.UnsupportedOrientation;
    const target = adapter.surface.Surface.init(request.frame[0..request.frame_length], 720, 1280, 1440) orelse return error.Geometry;
    const N = @import("navigation.zig").State;
    _ = target.fillRect(0, 0, 720, 1280, 0xf7bd);
    try label(instance, target, 36, 36, "xy", 48, 0x2147);
    try label(instance, target, 155, 54, "読む。書く。試す。", 28, 0x2147);
    try label(instance, target, 36, 112, "本を選んで、考えを広げる。", 24, 0x528a);
    const titles = [_][]const u8{ "n  文書を書く・再開", "1  xyを使ってみる", "2  草枕", "3  SICP", "4  小さなOSを育てる", "s  表示設定" };
    for (titles, 0..) |title, i| {
        const y: u32 = N.portrait_home_top + @as(u32, @intCast(i)) * N.portrait_home_pitch;
        _ = target.fillRect(@intCast(N.portrait_home_x), @intCast(y), N.portrait_home_width, N.portrait_home_card_height, if (nav.home_selection == i) 0x2147 else 0xffff);
        try label(instance, target, @intCast(N.portrait_home_x + 24), @intCast(y + 49), title, 28, if (nav.home_selection == i) 0xffff else 0x2147);
    }
    try label(instance, target, 36, 1130, "本はオフラインで読めます。", 24, 0x528a);
    _ = target.fillRect(0, 1208, 720, 72, 0x2147);
    try label(instance, target, 36, 1230, "タッチで選択 / 矢印・Enter", 24, 0xffff);
}

pub fn render(instance: *Session, request: *const protocol.Request, pack: catalog.Pack) !void {
    const nav = request.navigation orelse return error.Range;
    const physical = adapter.surface.Surface.init(request.frame[0..request.frame_length], 720, 1280, 1440) orelse return error.Geometry;
    const target = rotated.Rotated.init(physical);
    nav.chapter_count = try pack.counts();
    const book_titles = [_][]const u8{ "xyを使ってみる", "草枕 / 夏目漱石", "SICP / Scheme", "小さなOSを育てる" };
    const config = request.config.*;
    _ = target.fillRect(0, 0, 1280, 720, 0xf7bd);
    switch (nav.screen) {
        .examples, .exercise => {
            const l = request.learning orelse return error.Range;
            try @import("learning_view.zig").render(instance, request, l, nav.screen == .examples, false);
        },
        .home => {
            try label(instance, target, 48, 36, "xy", 48, 0x2147);
            try label(instance, target, 180, 54, "読む。書く。試す。", 32, 0x2147);
            try label(instance, target, 48, 114, "本を選んで、考えを広げる。", 24, 0x528a);
            const titles = [_][]const u8{ "n  文書を書く・再開", "1  xyを使ってみる", "2  草枕", "3  SICP", "4  小さなOSを育てる", "s  表示設定" };
            for (titles, 0..) |title, i| {
                const x: i32 = if (i % 2 == 0) 48 else 664;
                const y: i32 = 170 + @as(i32, @intCast(i / 2)) * 130;
                _ = target.fillRect(x, y, 568, 106, if (nav.home_selection == i) 0x2147 else 0xffff);
                try label(instance, target, x + 24, y + 34, title, 28, if (nav.home_selection == i) 0xffff else 0x2147);
            }
            try label(instance, target, 48, 596, "本はオフラインで読めます。タッチでも選べます。", 24, 0x528a);
            try footer(instance, target, false, false);
        },
        .chapters => {
            try label(instance, target, 48, 32, book_titles[nav.book], 32, 0x2147);
            try label(instance, target, 48, 88, "目次 / 読みたい章を選んでください", 24, 0x528a);
            const top = (nav.selected_chapter / 8) * 8;
            var i: u16 = top;
            while (i < @min(top + 8, nav.chapter_count[nav.book])) : (i += 1) {
                const e = try pack.chapter(nav.book, i);
                const y: i32 = 132 + @as(i32, i - top) * 60;
                if (i == nav.selected_chapter) _ = target.fillRect(32, y, 1216, 54, 0x2147);
                try label(instance, target, 48, y + 12, e.title, 24, if (i == nav.selected_chapter) 0xffff else 0x2147);
            }
            try footer(instance, target, false, false);
        },
        .settings => {
            try label(instance, target, 48, 40, "自分に合った読み心地に", 36, 0x2147);
            var number: [64]u8 = undefined;
            const line = try std.fmt.bufPrint(&number, "-          {d} px          +", .{config.style.body_px});
            try label(instance, target, 160, 178, line, 32, 0x2147);
            try label(instance, target, 160, 278, if (config.style.axis == 0) "横書き  /  v で縦書きへ" else "縦書き  /  v で横書きへ", 32, 0x2147);
            try label(instance, target, 160, 378, if (config.style.style_id == 0) "明朝    /  f でゴシックへ" else "ゴシック /  f で明朝へ", 32, 0x2147);
            try label(instance, target, 160, 478, "明るい紙面・暗い紙面 / t", 32, 0x2147);
            try label(instance, target, 160, 578, "設定を反映して戻る / Enter", 28, 0x2147);
            try footer(instance, target, false, false);
        },
        .reading => {
            const e = try pack.chapter(nav.book, nav.chapter);
            nav.text_length = @intCast(e.text.len);
            // SAFETY: prepare fills every field and all published prefixes before use.
            var page: Page = undefined;
            try prepare(instance, pack, e, nav.offset, config, &page, nav.chapter);
            var status: [256]u8 = undefined;
            const percent = @as(u64, nav.offset) * 100 / @max(1, e.text.len);
            const line = try std.fmt.bufPrint(&status, "{s} / {d}%  [h:Home c:Contents s:Settings i:Source]", .{ e.title, percent });
            var read_request = request.*;
            read_request.navigation = null;
            read_request.reserved_bottom_px = 72;
            read_request.text = page.text.ptr;
            read_request.text_length = page.text.len;
            read_request.cursor = 0;
            read_request.show_cursor = 0;
            read_request.page_mode = 1;
            read_request.book_prose = @intFromBool(page.book_prose);
            read_request.code_spans = &page.codes;
            read_request.code_count = page.code_count;
            read_request.status = line.ptr;
            read_request.status_length = line.len;
            read_request.ruby_text = &page.readings;
            read_request.ruby_text_length = page.reading_len;
            read_request.ruby_spans = &page.spans;
            read_request.ruby_count = page.count;
            try instance.render(&read_request);
            nav.end = nav.offset + @as(u32, @intCast(page.text.len));
            var can_try = false;
            if (request.learning) |l| {
                if (nav.book == 2) {
                    try l.setPage(nav.chapter, nav.offset, nav.end);
                    can_try = (try l.count()) > 0;
                } else l.page_valid = false;
            } else if (nav.book == 2 and page.code_count > 0) {
                can_try = true;
            }
            nav.can_try = can_try;
            try footer(instance, target, true, can_try);
        },
        .credits => {
            const e = try pack.chapter(nav.book, nav.chapter);
            var read_request = request.*;
            read_request.navigation = null;
            read_request.text = e.credits.ptr;
            read_request.text_length = @min(4096, e.credits.len);
            read_request.cursor = 0;
            read_request.show_cursor = 0;
            read_request.page_mode = 0;
            try instance.render(&read_request);
        },
        .card_view => {
            _ = target.fillRect(0, 0, 1280, 720, 0xf7bd);
            _ = target.fillRect(48, 28, 1184, 600, 0xffff);
            _ = target.fillRect(48, 28, 1184, 8, 0x2147);

            try label(instance, target, 72, 56, "マイナンバーカード 券面情報", 32, 0x2147);
            try label(instance, target, 72, 98, "券面事項入力補助APより取得（暗証番号照会済み）", 18, 0x528a);

            const card_data = &nav.card;
            if (card_data.valid) {
                try label(instance, target, 72, 140, "氏名", 18, 0x528a);
                const name = if (card_data.name_len > 0) card_data.nameSlice() else "—";
                try label(instance, target, 72, 172, name, 32, 0x2147);

                try label(instance, target, 72, 230, "生年月日 / 性別", 18, 0x528a);
                var bg_buf: [48]u8 = undefined;
                const gender_str = if (std.mem.eql(u8, card_data.genderSlice(), "1")) "男" else if (std.mem.eql(u8, card_data.genderSlice(), "2")) "女" else card_data.genderSlice();
                const bg_text = if (card_data.birth_len > 0)
                    std.fmt.bufPrint(&bg_buf, "{s}  /  {s}", .{ card_data.birthSlice(), gender_str }) catch card_data.birthSlice()
                else
                    "—";
                try label(instance, target, 72, 260, bg_text, 26, 0x2147);

                try label(instance, target, 72, 315, "住所", 18, 0x528a);
                const addr = if (card_data.address_len > 0) card_data.addressSlice() else "—";
                if (addr.len > 48) {
                    const split_idx = @min(addr.len, 48);
                    const line1 = addr[0..split_idx];
                    const line2 = addr[split_idx..];
                    try label(instance, target, 72, 345, line1, 24, 0x2147);
                    try label(instance, target, 72, 380, line2, 24, 0x2147);
                } else {
                    try label(instance, target, 72, 345, addr, 24, 0x2147);
                }

                _ = target.fillRect(896, 136, 200, 264, 0xef5d);
                _ = target.fillRect(900, 140, 192, 256, 0xdf1a);
                try label(instance, target, 960, 260, "顔写真", 24, 0x528a);
            } else {
                try label(instance, target, 72, 160, "カードデータがありません", 24, 0x528a);
            }

            _ = target.fillRect(0, 648, 1280, 72, 0x2147);
            try label(instance, target, 48, 672, "Esc / タップ: 戻る        Enter: 本文に挿入        s: 保存", 24, 0xffff);
        },
        .document => return error.Range,
    }
}
