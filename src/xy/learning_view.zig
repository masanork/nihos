//! Shared lesson pixels. Native uses rotated RGB565; desktop uses logical RGB565.
const learning = @import("learning_session.zig");
const protocol = @import("render_protocol.zig");
const layout = @import("viewport_layout");
const adapter = @import("render_adapter.zig");
const rotated = @import("rotated_surface");

fn label(instance: anytype, target: anytype, x: i32, y: i32, text: []const u8, size: u8, color: u16) !void {
    const family_faces = [_]layout.ttf.Face{ instance.faces[0], instance.faces[1] };
    const family = instance.external_mincho orelse layout.ttf.Family{ .faces = &family_faces };
    var iterator = layout.ClusterIterator{ .text = text };
    var pen = x;
    while (try iterator.next()) |cl| {
        if (cl.base_cp == '\n') break;
        const glyph = try instance.cache.getOrRender(family, 0, cl.base_cp, cl.ivs_cp, size, false, &instance.scratch);
        if (pen + size > 1264) break;
        const mask = adapter.surface.Mask{ .bytes = glyph.alpha, .width = glyph.metrics.width, .height = glyph.metrics.height, .stride = glyph.metrics.width };
        const baseline = y + @divTrunc(@as(i32, size) * 880 + 512, 1024);
        _ = target.blit(mask, pen + glyph.metrics.left_px, baseline - glyph.metrics.top_px, color);
        pen += @divTrunc(glyph.metrics.x_advance_26_6 + 32, 64);
    }
}

pub fn render(instance: anytype, request: *const protocol.Request, l: *learning.Session, examples: bool, comptime logical: bool) !void {
    const raw = adapter.surface.Surface.init(request.frame[0..request.frame_length], if (logical) 1280 else 720, if (logical) 720 else 1280, if (logical) 2560 else 1440) orelse return error.Geometry;
    const target = if (logical) raw else rotated.Rotated.init(raw);
    if (examples) {
        _ = target.fillRect(0, 0, 1280, 720, 0xf7bd);
        try label(instance, target, 32, 32, "SICP / examples on this page [RAM]", 28, 0x2147);
        const count = try l.count();
        if (count == 0) try label(instance, target, 32, 100, "No example here. Return to the book and turn the page.", 24, 0x528a);
        const top = l.selected / 6 * 6;
        var i: u32 = top;
        while (i < @min(count, top + 6)) : (i += 1) {
            const choice = (try l.choice(i)).?;
            const y: i32 = 132 + @as(i32, @intCast(i - top)) * 72;
            if (i == l.selected) _ = target.fillRect(24, y - 4, 1232, 66, 0x2147);
            try label(instance, target, 36, y, choice.id, 20, if (i == l.selected) 0xffff else 0x2147);
            try label(instance, target, 36, y + 28, choice.code, 22, if (i == l.selected) 0xffff else 0x2147);
        }
        _ = target.fillRect(0, 648, 1280, 72, 0x2147);
        try label(instance, target, 24, 670, "Back: Esc     Choose: arrows + Enter, or touch an example", 24, 0xffff);
        return;
    }
    const s = l.slot() orelse return error.Range;
    const d = l.doc().?;
    const snippet = try l.pack.snippet(s.snippet);
    var config = request.config.*;
    config.style.axis = 0;
    config.style.body_px = 25;
    config.style.ruby_px = 8;
    config.style.line_gap_px = 4;
    config.style.style_id = 0;
    var req = request.*;
    req.navigation = null;
    req.book_prose = 0;
    req.code_spans = null;
    req.code_count = 0;
    req.learning = null;
    req.config = &config;
    req.reserved_bottom_px = 200;
    req.text = d.slice().ptr;
    req.text_length = d.len;
    req.cursor = d.cursor;
    req.ruby_count = 0;
    req.ruby_text_length = 0;
    req.show_cursor = 1;
    req.page_mode = 0;
    const status = if (l.editing_notes) "Notes / RAM only; notes are never evaluated" else snippet.id;
    req.status = status.ptr;
    req.status_length = status.len;
    if (logical) try instance.renderLogical(&req, 1280, 720, 2560) else try instance.render(&req);
    _ = target.fillRect(0, 520, 1280, 128, 0xf7bd);
    const state = if (!try l.supported(s.snippet)) "This example needs language features not available yet." else if (s.result_len == 0) "Integer Scheme subset / Run to try your code. RAM only." else if (s.result_revision != s.code.revision) "Code changed since this result." else if (s.failed) "Evaluation error; the previous environment was kept." else "Result of your code (not a grade):";
    try label(instance, target, 24, 536, state, 22, 0x2147);
    try label(instance, target, 24, 576, if (l.message_len != 0) l.message[0..l.message_len] else s.result[0..s.result_len], 24, if (s.failed or l.message_len != 0) 0x9800 else 0x2147);
    _ = target.fillRect(0, 648, 1280, 72, 0x2147);
    for ([_]struct { x: i32, text: []const u8 }{
        .{ .x = 24, .text = "Back / Esc" },                              .{ .x = 212, .text = "Run / Ctrl-L" },
        .{ .x = 470, .text = "Reset VM" },                               .{ .x = 720, .text = "Original" },
        .{ .x = 980, .text = if (l.editing_notes) "Code" else "Notes" },
    }) |button| try label(instance, target, button.x, 670, button.text, 22, 0xffff);
}
