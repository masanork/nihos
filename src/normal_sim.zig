//! Host-only adapter for the production diagnostic UI's pure components.
const std = @import("std");
const console = @import("console.zig");
const boot = @import("graphics/boot_graphics.zig");
const pointer = @import("input/pointer.zig");
const controller = @import("touch_sim.zig");
const Text = console.Grid(console.raster.columns, console.raster.rows);
var model: console.boot.Model = .{};
var stream: pointer.Stream = .{};
var queue: pointer.Queue = .{};
var button: pointer.Button = .{};
var text: Text = .{};
var renderer: console.raster.Renderer(null, .basic_light) = .{};
var frame: [720 * 1280 * 2]u8 = @splat(0);
var reference: [720 * 1280 * 2]u8 = @splat(0);
var shown_details = false;
var palette: console.raster.Palette = .matrix;
pub const View = extern struct {
    details: u32 = 0,
    accepted: u32 = 0,
    down: u32 = 0,
    move: u32 = 0,
    up: u32 = 0,
    cancel: u32 = 0,
    overflow: u32 = 0,
    queued: u32 = 0,
    last_x: u32 = 0,
    last_y: u32 = 0,
    failed: u32 = 0,
    log_lines: u32 = 0,
    mismatches: u32 = 0,
};
var view: View = .{};
pub export fn normal_view(out: *View) void {
    view.details = @intFromBool(model.details);
    view.failed = @intFromBool(model.failure_latched);
    if (controller.selected != 0) {
        const counts = controller.service.eventSnapshot();
        view.down = counts.down;
        view.move = counts.move;
        view.up = counts.up;
        view.cancel = counts.cancel;
        view.overflow = counts.overflow;
        view.queued = counts.queued;
    } else {
        view.overflow = queue.overflows;
        view.queued = @intCast(queue.length);
    }
    out.* = view;
}
pub export fn normal_reset(selected_palette: u32) bool {
    if (selected_palette > 4) return false;
    palette = @fromBackingInt(selected_palette);
    model = .{ .input_available = true, .input_sources = 17 };
    for ([_]console.boot.Stage{ .crt, .memory, .display_prepare, .cores, .display_scanout, .input, .console }) |stage| {
        if (!model.begin(stage) or !model.complete(stage)) return false;
    }
    if (!model.unavailable(.storage)) return false;
    stream = .{};
    queue = .{};
    button = .{};
    view = .{};
    text = .{};
    renderer = .{};
    shown_details = false;
    console.snapshot.fill(&text, &model, .{ "NIHOS_SIM synthetic boot checkpoints\n", "NIHOS_SIM no device I/O\n" }, 0);
    return true;
}
fn enqueue(event: pointer.Event) void {
    switch (event.kind) {
        .down => view.down +|= 1,
        .move => view.move +|= 1,
        .up => view.up +|= 1,
        .cancel => view.cancel +|= 1,
    }
    view.last_x = event.x;
    view.last_y = event.y;
    if (!queue.push(event)) {
        _ = stream.cancel(.overflow, event.at);
        view.cancel +|= 1;
    }
}
pub export fn normal_drain() bool {
    var changed = false;
    while (if (controller.selected != 0) controller.service.pop() else queue.pop()) |event| {
        view.last_x = event.x;
        view.last_y = event.y;
        if (!model.failure_latched and button.observe(event, pointer.view_button)) {
            if (model.onKey(if (model.details) .splash else .escape)) {
                view.accepted +|= 1;
                changed = true;
            }
        }
    }
    return changed;
}
pub export fn normal_controller_reset(panel: u32, slots: u8) bool {
    return controller.reset(panel, slots);
}
pub export fn normal_controller_report(contacts: u8, x: u16, y: u16, sparse: bool, at: u64, dispatch: bool) bool {
    if (!controller.report(contacts, x, y, sparse)) return false;
    controller.poll(at);
    return if (dispatch) normal_drain() else false;
}
pub export fn normal_touch(contacts: u8, x: u16, y: u16, at: u64, dispatch: bool) bool {
    if (controller.selected != 0) {
        if (!controller.report(contacts, x, y, false)) return false;
        controller.poll(at);
    } else if (stream.fresh(contacts, x, y, at)) |event| enqueue(event);
    return if (dispatch) normal_drain() else false;
}
pub export fn normal_tick(at: u64, dispatch: bool) bool {
    if (controller.selected != 0) {
        controller.poll(at);
    } else if (stream.tick(at)) |event| enqueue(event);
    return if (dispatch) normal_drain() else false;
}
pub export fn normal_action(action: u32, count: u32) bool {
    switch (action) {
        0, 1 => return model.onKey(if (action == 0) .escape else .splash),
        2 => {
            if (count > 1024) return false;
            var line: [80]u8 = undefined;
            for (0..count) |_| {
                view.log_lines +|= 1;
                const message = std.fmt.bufPrint(&line, "NIHOS_SIM synthetic log {d}\n", .{view.log_lines}) catch return false;
                text.write(message);
            }
        },
        3 => {
            model.fail(1);
            renderer.invalidate();
        },
        else => return false,
    }
    return true;
}
fn control(bytes: []u8) bool {
    if (model.failure_latched) return true;
    const box = pointer.view_button;
    return console.raster.paintControl(null, bytes, 1440, .{ .left = box.x, .top = box.y, .right = box.x + box.width, .bottom = box.y + box.height }, if (model.details) "SPLASH" else "LOGS", palette);
}
pub export fn normal_corrupt() bool {
    if (!model.details) return false;
    frame[0] ^= 1;
    return true;
}
pub export fn normal_invalidate() void {
    renderer.invalidate();
}
pub export fn normal_render(out: [*]u8, length: usize) bool {
    if (length != frame.len) return false;
    if (shown_details != model.details) renderer.invalidate();
    if (model.details) {
        console.snapshot.refreshHeader(&text, &model, 0);
        if (!renderer.submit(&frame, 1440, &text, palette) or !renderer.finish(&frame, 1440, palette)) return false;
        if (!console.raster.paintFace(null, .basic_light, &reference, 1440, &text, palette)) return false;
    } else {
        if (!boot.paintLandscapePlacedRgb565Le(null, &frame, 720, 1280, 1440, model.dyeTarget(), .ready)) return false;
        if (!boot.paintLandscapePlacedRgb565Le(null, &reference, 720, 1280, 1440, model.dyeTarget(), .ready)) return false;
    }
    if (!control(&frame) or !control(&reference)) return false;
    view.mismatches = 0;
    for (frame, reference) |actual, expected| if (actual != expected) {
        view.mismatches += 1;
    };
    shown_details = model.details;
    @memcpy(out[0..length], &frame);
    return true;
}
