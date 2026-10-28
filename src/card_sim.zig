//! Host-only, synthetic card UI adapter. No APDU, reader, PIN buffer or keys.
const splash = @import("graphics/card_splash.zig");
const screen = @import("graphics/card_pin.zig");
const result = @import("graphics/card_read_result.zig");
const plan = @import("graphics/keypad_plan.zig");
const keypad = @import("card/keypad_demo.zig");
const presence = @import("card/presence.zig");
const result_input = @import("card/result_input.zig");
comptime {
    _ = @import("normal_sim.zig");
}
const Phase = enum(u32) { boot, ready, pin1, pin2, overview, details, error_screen };
const font = if (@import("builtin").os.tag == .macos) "__TEXT,__auto_font" else ".rodata.sim_auto_font";
var phase: Phase = .boot;
var model: keypad.Model = .{};
var gate: presence.Gate = .{};
var kind: u32 = 2;
var result_contact: result_input.Model = .{};
var paint_metrics: result.Paint = .{};
var portrait: [result.portrait_bytes]u8 = @splat(0);
pub const View = extern struct { phase: u32, count: u32, job: u32, present: u32, confirms: u32, missing: u32, truncated: u32 };
pub export fn sim_view(out: *View) void {
    out.* = .{ .phase = @backingInt(phase), .count = model.count, .job = gate.job, .present = @intFromBool(gate.previous), .confirms = model.confirms, .missing = paint_metrics.missing, .truncated = @intFromBool(paint_metrics.truncated) };
}
pub export fn sim_model_reset() void {
    phase = .boot;
    model = .{};
    gate = .{};
    kind = 2;
    result_contact = .{};
    for (&portrait, 0..) |*byte, index| byte.* = @truncate(index * 17);
}
fn change(next: Phase) void {
    const starting_result = next == .overview and phase != .overview and phase != .details;
    phase = next;
    model.count = 0;
    model.contact.disarm();
    if (starting_result) result_contact = .{ .mynumber = kind == 1 };
}
/// Semantic fixture actions: 0 ready, 1 classic insert, 2 My Number insert,
/// 3 remove, 4 details, 5 overview, 6 close. Only generated data is rendered.
pub export fn sim_action(action: u32) bool {
    switch (action) {
        0 => change(.ready),
        1, 2 => {
            if (phase != .ready) return false;
            _ = gate.observe(true);
            if (gate.observe(true) != .detect) return false;
            kind = if (action == 1) 2 else 1;
            change(.pin1);
        },
        3 => {
            _ = gate.observe(false);
            _ = gate.observe(false);
            change(.ready);
        },
        4 => {
            if (phase != .overview or kind != 2) return false;
            change(.details);
        },
        5 => {
            if (phase != .details) return false;
            change(.overview);
        },
        6 => {
            gate.finish();
            change(.ready);
        },
        else => return false,
    }
    return true;
}
pub export fn sim_touch(contacts: u8, x: u16, y: u16) u32 {
    if (phase == .overview or phase == .details) {
        const selected = result_contact.sample(contacts, x, y) orelse return 0;
        switch (selected) {
            .basic => change(.overview),
            .next => change(.details),
            .close => {
                gate.finish();
                change(.ready);
            },
        }
        return switch (selected) {
            .basic => 8,
            .next => 9,
            .close => 10,
        };
    }
    if (phase != .pin1 and phase != .pin2) return 0;
    const effect = model.sample(contacts, x, y) orelse return 0;
    switch (effect) {
        .cancel => {
            gate.finish();
            change(.ready);
        },
        .confirm => change(if (phase == .pin1 and kind == 2) .pin2 else .overview),
        else => {},
    }
    return @backingInt(effect);
}
pub export fn sim_render(frame: [*]u8, length: usize, spans: [*]plan.Segment, capacity: usize, config: *plan.Config) u32 {
    const bytes = frame[0..length];
    paint_metrics = .{};
    const pin = phase == .pin1 or phase == .pin2;
    const paper = if (phase == .boot) splash.background else screen.paper_color;
    switch (phase) {
        .boot => {
            if (!splash.paint(null, bytes, 1440)) return 0;
        },
        .ready => result.notice(font, bytes, "カードを置いてください", "検証用・実在するカードは使いません") catch return 0,
        .pin1, .pin2 => {
            var view = model.view();
            view.remaining = 3;
            if (!screen.paintRead(null, bytes, 1440, view)) return 0;
            if (kind == 2) result.licensePinHeader(font, bytes, if (phase == .pin1) 1 else 2) catch return 0;
        },
        .overview => {
            paint_metrics = result.automaticOverview(font, bytes, .{ .name = "表示テスト（架空）", .address = "架空県架空市一丁目", .birth_date = "20000101", .detail = if (kind == 2) "000000000000" else "1", .expiration = if (kind == 2) "20300101" else null }, &portrait) catch return 0;
            if (kind == 2) result.resultControls(font, bytes, false) catch return 0;
        },
        .details => {
            paint_metrics = result.licensePage(font, bytes, false, &.{.{ .label = "住所", .date = "20260101", .value = "画面シミュレーション・架空データ" }}) catch return 0;
        },
        .error_screen => result.notice(font, bytes, "検証用エラー画面", "実際のPIN残り回数は参照していません") catch return 0,
    }
    const output = spans[0..capacity];
    const selected = (if (pin) plan.build(bytes, output) else if (phase == .overview or phase == .details) plan.buildOverview(bytes, output) else plan.buildStaticColor(bytes, output, paper)) catch return 0;
    const dots = screen.dots_rect;
    const label = screen.submitRect();
    config.* = .{ .plan = plan.scratch_start, .count = @intCast(selected.len), .peer_start = 0, .peer_bytes = 0, .dots_x = dots.x, .dots_y = dots.y, .dots_width = dots.width, .dots_height = dots.height, .label_x = label.x, .label_y = label.y, .label_width = label.width, .label_height = if (pin) label.height else 0, .paper = paper, .keys = screen.key_color, .accent = screen.accent_color, .scratch = 0, .stride = if (pin) @intCast(plan.textureStride()) else 0, .capacity = 1280, .pixels = 0x48030000, .pixels_bytes = @intCast(length) };
    return @intCast(selected.len);
}
pub export fn sim_textures(out: [*]u8, length: usize) bool {
    const stride = plan.textureStride();
    if (length < 2 * stride) return false;
    var view = model.view();
    view.remaining = 3;
    for (0..2) |i| {
        const bytes = out[i * stride ..][0..stride];
        if (!screen.paintDynamic(null, bytes[0..plan.dots_bytes], bytes[plan.dots_bytes..][0..plan.labelBytes()], view)) return false;
    }
    return true;
}
