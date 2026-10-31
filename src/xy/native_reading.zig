//! Tab5 scenes and bounded page fitting over the shared text renderer.
const std = @import("std");
const layout = @import("viewport_layout");
const adapter = @import("render_adapter.zig");
const session_module = @import("render_session.zig");
const rotated = @import("rotated_surface");
const catalog = @import("catalog.zig");
const reader = @import("reader.zig");
const protocol = @import("render_protocol.zig");
pub const Session = session_module.SizedSession(512);

pub const Page = struct {
    text: []const u8,
    readings: [1024]u8,
    reading_len: usize = 0,
    spans: [64]protocol.RubySpan,
    count: usize = 0,
};

pub fn prepare(instance: *Session, pack: catalog.Pack, entry: catalog.Entry, offset: u32, config: protocol.Config, page: *Page) !void {
    if (offset >= entry.text.len or !@import("document.zig").isClusterBoundary(entry.text, offset)) return error.Range;
    var end: usize = offset;
    var clusters: usize = 0;
    while (end < entry.text.len and end - offset < 3000 and clusters < 400) : (clusters += 1) end = try @import("document.zig").nextClusterEnd(entry.text, end);
    var ruby_count: usize = 0;
    var at: usize = 0;
    while (at < entry.ruby.len) : (at += 16) {
        const a = catalog.read(entry.ruby, at);
        const b = catalog.read(entry.ruby, at + 4);
        if (a < offset or a >= end) continue;
        ruby_count += 1;
        if (b > end or ruby_count > 64) end = a;
    }
    var style = config.style;
    style.viewport_width_px = 1280;
    style.viewport_height_px = 648 - @as(u16, style.body_px) - 2 * @as(u16, config.appearance.status_padding);
    const family = layout.ttf.Family{ .faces = &.{ instance.faces[0], instance.faces[1 + @as(usize, style.style_id)] } };
    while (end > offset) {
        // SAFETY: only the populated prefixes below are consumed; lengths start at zero.
        page.* = .{ .text = entry.text[offset..end], .readings = undefined, .spans = undefined };
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
        try reader.validate(page.text, page.readings[0..page.reading_len], page.spans[0..page.count]);
        var anns: [64]layout.ruby.Annotation = undefined;
        for (page.spans[0..page.count], 0..) |span, i| anns[i] = .{ .base = .{ .start = span.base_start, .end = span.base_end }, .ruby = .{ .start = span.ruby_start, .end = span.ruby_end } };
        const list = layout.layoutParagraphWithWordWrap(512, 4096, 1024, session_module.Cache, &instance.cache, family, style, page.text, page.readings[0..page.reading_len], anns[0..page.count], &instance.scratch, &instance.placed, true) catch |err| switch (err) {
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
fn footer(instance: *Session, target: anytype, reading: bool) !void {
    _ = target.fillRect(0, 648, 1280, 72, 0x2147);
    if (reading) {
        try label(instance, target, 24, 670, "ホーム", 24, 0xffff);
        try label(instance, target, 232, 670, "前へ", 24, 0xffff);
        try label(instance, target, 512, 670, "次へ", 24, 0xffff);
        try label(instance, target, 792, 670, "目次", 24, 0xffff);
        try label(instance, target, 1060, 670, "設定", 24, 0xffff);
    } else try label(instance, target, 24, 670, "ホーム / Esc      前の一覧        次の一覧      矢印・Enter", 24, 0xffff);
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
            try footer(instance, target, false);
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
            try footer(instance, target, false);
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
            try footer(instance, target, false);
        },
        .reading => {
            const e = try pack.chapter(nav.book, nav.chapter);
            nav.text_length = @intCast(e.text.len);
            // SAFETY: prepare fills every field and all published prefixes before use.
            var page: Page = undefined;
            try prepare(instance, pack, e, nav.offset, config, &page);
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
            read_request.status = line.ptr;
            read_request.status_length = line.len;
            read_request.ruby_text = &page.readings;
            read_request.ruby_text_length = page.reading_len;
            read_request.ruby_spans = &page.spans;
            read_request.ruby_count = page.count;
            try instance.render(&read_request);
            nav.end = nav.offset + @as(u32, @intCast(page.text.len));
            try footer(instance, target, true);
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
        .document => return error.Range,
    }
}
