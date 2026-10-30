//! CPU0 live UI. All rendering/I2C is outside interrupts; ISR only rearms DMA.
const options = @import("native_options");
const pointer = @import("pointer_input");
extern fn nih_touch_available() callconv(.c) bool;
extern fn nih_touch_pop(*pointer.Event) callconv(.c) bool;
var touch_available = false;
var view_button: pointer.Button = .{};
var input_started: u64 = 0;
const console = @import("text_console");
const camera_preview = @import("camera_preview");
const camera_input = @import("camera_input");
const board = @import("tab5_display");
const boot = @import("boot_graphics");
const tasks = @import("native_tasks");
const i2c = @import("boot_i2c");
const Pins = @import("display_probe.zig").Pins;
const runtime = @import("display_runtime.zig");
const clock = @import("diagnostic_clock.zig");
extern fn nih_rom_cache_writeback(u32, u32, u32) callconv(.c) i32;
extern fn nih_rom_cache_invalidate(u32, u32, u32) callconv(.c) i32;
extern fn nih_keyboard_pads_init() callconv(.c) void;
extern fn nih_diagnostic_serial_dropped() callconv(.c) u32;
extern fn nih_diagnostic_serial_read() callconv(.c) i32;
extern fn nih_diagnostic_serial_write(u8) callconv(.c) void;

var journal = console.Journal(2048){};
pub var model = console.boot.Model{};
var dirty: u32 = 1;
var clock_ready = false;
var rendering = false;
var shown_details = false;
var shown_status: ?boot.Status = null;
var progress: u8 = 0;
var last_frame: u32 = 0;
var last_render: u64 = 0;
var last_input: u64 = 0;
var sequence: u32 = 0;
var settled_reported = false;
var serial = console.keys.Serial{};
const control = @import("device_control");
var device_commands: control.Parser = .{};
const storage_control = @import("storage_control");
var storage_commands: storage_control.Parser = .{};
extern fn nih_fs_command([*]const u8, u32) callconv(.c) void;
extern fn nih_device_request(u32) callconv(.c) bool;
var bus = i2c.Master(Pins){ .pins = .{ .clock = clock.timer() }, .data_pin = 0, .clock_pin = 1 };
var keyboard = console.keyboard.Keyboard(@TypeOf(bus)){ .bus = &bus };
var hardware_ready = false;
var revision: u32 = 0;
var shown_revision: u32 = 0;
const face: console.raster.Face = @fromBackingInt(options.console_font);
const geometry = console.raster.Layout(face);
const Text = console.Grid(geometry.columns, geometry.rows);
// The normal storage image maps an additional read-only Flash span before
// native startup. Keep larger font assets there when that span exists.
const font_section = if (options.normal_storage and (face == .jetbrains or face == .source_code)) ".flash.fs.console" else ".flash.rodata.display";
const Renderer = console.raster.Renderer(font_section, face);
// Unused tail of the existing private display reservation, not owner heaps.
const renderer: *Renderer = @ptrFromInt(board.framebuffer + board.frame_bytes);
const live_text: *Text = @ptrFromInt(board.framebuffer + board.frame_bytes + @sizeOf(Renderer));
const Session = console.session;
const xy_workspace = @hasDecl(options, "xy_workspace") and options.xy_workspace;
const xy_trace = @hasDecl(options, "xy_trace") and options.xy_trace;
var last_xy_trace_revision: u32 = 0;
var xy_input_bytes: u32 = 0;
var last_xy_input_bytes: u32 = 0;
const session_offset = (@sizeOf(Renderer) + @sizeOf(Text) + @alignOf(Session.Model) - 1) & ~@as(usize, @alignOf(Session.Model) - 1);
const session: *Session.Model = @ptrFromInt(board.framebuffer + board.frame_bytes + session_offset);
const scratch_offset = (session_offset + @sizeOf(Session.Model) + @alignOf(console.scratch.Model) - 1) & ~@as(usize, @alignOf(console.scratch.Model) - 1);
const scratch: *console.scratch.Model = @ptrFromInt(board.framebuffer + board.frame_bytes + scratch_offset);
var camera_overlay: camera_preview.Overlay = .{};
var camera_live: camera_preview.Live = .{};
pub fn cameraLiveActive() bool {
    return camera_live.state == .running;
}
pub fn cameraAcceptFrame() bool {
    return camera_live.acceptFrame();
}
pub fn cameraLiveEnd() void {
    camera_live.end();
}
pub fn cameraLiveFailure() bool {
    if (camera_live.state == .idle) return false;
    camera_live.end();
    if (camera_overlay.state == .visible) {
        camera_input_sequence +%= 1;
        _ = camera_overlay.dismiss(camera_input_sequence);
        requestCameraRepaint();
    }
    session.write(SerialSink{}, "Camera preview stopped after a capture failure.\r\n");
    @atomicStore(u32, &dirty, 1, .release);
    return true;
}
var camera_input_sequence: u32 = 0;
var camera_preview_mismatches: u32 = 0xffffffff;
var session_active = false;
var session_pending = false;
var session_serial = Session.input.Serial{};
var session_hid = Session.input.Hid{};
var shown_session_revision: u32 = 0;
var shown_session_view: ?Session.View = null;
const SerialSink = struct {
    pub fn write(_: @This(), bytes: []const u8) void {
        for (bytes) |byte| nih_diagnostic_serial_write(byte);
    }
};
/// Single optional CPU0 service reservation after all console objects. The
/// full tail already belongs to the display lease, outside both owner heaps.
/// No object in this range is a scanout/DMA source.
pub fn serviceBacking(comptime bytes: usize) *align(64) [bytes]u8 {
    const used = if (xy_workspace) scratch_offset + @sizeOf(console.scratch.Model) else session_offset + @sizeOf(Session.Model);
    const start = (board.framebuffer + board.frame_bytes + used + 63) & ~@as(usize, 63);
    comptime {
        if (start + bytes > board.framebuffer + board.reserve_bytes)
            @compileError("console and network state exceed the reserved display tail");
    }
    return @ptrFromInt(start);
}
var renderer_ready = false;
var max_scroll_us: u32 = 0;
var max_copy_us: u32 = 0;
var max_cache_us: u32 = 0;
var max_cache_chunk_us: u32 = 0;
var line_step_us: u32 = 0;
var cpu_mhz: u32 = 0;
comptime {
    if (session_offset + @sizeOf(Session.Model) > board.reserve_bytes - board.frame_bytes or @alignOf(Renderer) > 64)
        @compileError("console renderer exceeds private display tail");
    if (xy_workspace and scratch_offset + @sizeOf(console.scratch.Model) > board.reserve_bytes - board.frame_bytes)
        @compileError("xy workspace exceeds private display tail");
}
fn palette() console.raster.Palette {
    return @fromBackingInt(@intCast(options.console_palette));
}

fn mask() u32 {
    return asm volatile ("csrrci %[previous], mstatus, 8"
        : [previous] "=r" (-> u32),
        :
        : .{ .memory = true });
}
fn restore(previous: u32) void {
    if (previous & 8 != 0) asm volatile ("csrsi mstatus, 8" ::: .{ .memory = true });
}
pub noinline fn append(message: []const u8) void {
    if (!options.console) return;
    const hart = asm volatile ("csrr %[hart], mhartid"
        : [hart] "=r" (-> u32),
    );
    if (hart != 0) return;
    const previous = if (options.console_live) 0 else mask();
    journal.append(message);
    if (renderer_ready and !session_active) live_text.write(message);
    @atomicStore(u32, &dirty, 1, .release);
    if (!options.console_live) restore(previous);
}
pub fn initializeClock() bool {
    if (!options.console_live and options.boot_test == 0) return true;
    clock_ready = clock.initialize();
    return clock_ready;
}
pub fn begin(stage: console.boot.Stage) bool {
    if (!options.console) return true;
    const result = model.begin(stage);
    if (result) revision +%= 1;
    return result;
}
pub fn complete(stage: console.boot.Stage) bool {
    if (!options.console) return true;
    const result = model.complete(stage);
    if (result) revision +%= 1;
    return result;
}
pub fn unavailable(stage: console.boot.Stage) void {
    if (options.console) _ = model.unavailable(stage);
}
pub fn abandonCameraPreview() void {
    camera_overlay.abandon();
}
pub fn failed() void {
    abandonCameraPreview();
    if (options.console) {
        model.fail(1);
        session_pending = false;
        if (session_active) {
            // Rebuild the diagnostic grid from its own journal on failure.
            session_active = false;
            renderer_ready = false;
        }
    }
}
fn frame() []u8 {
    const data: [*]u8 = @ptrFromInt(board.framebuffer);
    return data[0..board.frame_bytes];
}
fn present() bool {
    // ROM cache commands share hardware state with the descriptor writeback
    // in the DMA ISR. Never let that ISR nest a command inside ours. Bound
    // each IRQ-off region instead of masking across the whole framebuffer.
    var offset: u32 = 0;
    while (offset < board.frame_bytes) {
        const length: u32 = @min(1024, board.frame_bytes - offset);
        const previous = mask();
        const result = nih_rom_cache_writeback((1 << 4) | (1 << 5), board.framebuffer + offset, length);
        restore(previous);
        if (result != 0) return false;
        if (previous & 8 == 0) runtime.onInterrupt(); // fatal-path manual owner
        offset += length;
    }
    return tasks.memory.stacks.bootGuardsIntact(0);
}
fn presentDamage() bool {
    const damage = renderer.takeDamage();
    if (damage.empty()) return true;
    if (damage.left == 0 and damage.top == 0 and damage.right == 1280 and damage.bottom == 720) return present();
    if (damage.bottom - damage.top >= 256) {
        const start = ((1280 - damage.right) * 1440 + damage.top * 2) & ~@as(usize, 63);
        const end = ((1279 - damage.left) * 1440 + damage.bottom * 2 + 63) & ~@as(usize, 63);
        return flushSpan(start, end);
    }
    // Rotation maps each logical rectangle to contiguous physical row spans.
    // Expand to cache lines without escaping the reserved framebuffer.
    for (1280 - damage.right..1280 - damage.left) |y| {
        const offset: usize = (y * 1440 + damage.top * 2) & ~@as(usize, 63);
        const end = (y * 1440 + damage.bottom * 2 + 63) & ~@as(usize, 63);
        if (!flushSpan(offset, end)) return false;
    }
    return tasks.memory.stacks.bootGuardsIntact(0);
}
fn flushSpan(start: usize, end: usize) bool {
    var offset = start;
    while (offset < end) {
        const length = @min(16384, end - offset);
        const previous = mask();
        const before = clock.timer().counter() orelse {
            restore(previous);
            return false;
        };
        const result = nih_rom_cache_writeback((1 << 4) | (1 << 5), board.framebuffer + @as(u32, @intCast(offset)), @intCast(length));
        const after = clock.timer().counter() orelse {
            restore(previous);
            return false;
        };
        restore(previous);
        max_cache_chunk_us = @max(max_cache_chunk_us, @as(u32, @intCast(@min(after - before, 0xffff_ffff))));
        if (result != 0) return false;
        if (previous & 8 == 0) runtime.onInterrupt();
        offset += length;
    }
    return tasks.memory.stacks.bootGuardsIntact(0);
}
fn invalidateCameraSpan(start: usize, end: usize) bool {
    var offset = start;
    while (offset < end) {
        const length = @min(16384, end - offset);
        const previous = mask();
        const result = nih_rom_cache_invalidate((1 << 4) | (1 << 5), board.framebuffer + @as(u32, @intCast(offset)), @intCast(length));
        restore(previous);
        if (result != 0) return false;
        if (previous & 8 == 0) runtime.onInterrupt();
        offset += length;
    }
    return true;
}
const fixture_pixels: [camera_preview.height][camera_preview.width]u8 = pixels: {
    @setEvalBranchQuota(20_000);
    var result: [camera_preview.height][camera_preview.width]u8 = undefined;
    for (&result, 0..) |*row, y| for (row, 0..) |*value, x| {
        value.* = @intCast((x * 3 + y * 5) % 256);
    };
    break :pixels result;
};
pub fn cameraPreviewMismatchCount() u32 {
    return camera_preview_mismatches;
}
/// Diagnostic still-image overlay for a ready session. The caller supplies a
/// stable sampled copy, not a DMA buffer; hardware capture is not wired here.
pub fn showCameraPreview(pixels: *const [camera_preview.height][camera_preview.width]u8, tone: bool) bool {
    const refresh = cameraLiveActive() and camera_overlay.state == .visible;
    if (!options.console_live or !session_active or !runtime.active() or rendering or (!camera_overlay.canShow() and !refresh) or runtime.snapshot().fault != 0) return false;
    if (refresh) _ = camera_overlay.beginRefresh();
    rendering = true;
    defer rendering = false;
    camera_preview_mismatches = 0xffffffff;
    var completed = false;
    defer if (!completed) {
        camera_overlay.failed();
        shown_session_view = null;
        if (renderer_ready) renderer.invalidate();
        @atomicStore(u32, &dirty, 1, .release);
    };
    if (!camera_preview.paint(frame(), pixels, tone)) return false;
    const low_row = 1279 - (camera_preview.display_left + camera_preview.display_width - 1);
    const high_row = 1279 - camera_preview.display_left;
    const start = (low_row * 1440 + camera_preview.display_top * 2) & ~@as(usize, 63);
    const end = (high_row * 1440 + (camera_preview.display_top + camera_preview.display_height) * 2 + 63) & ~@as(usize, 63);
    if (!flushSpan(start, end) or !invalidateCameraSpan(start, end)) return false;
    camera_preview_mismatches = camera_preview.mismatches(frame(), pixels, tone) orelse return false;
    if (camera_preview_mismatches != 0) return false;
    camera_overlay.shown();
    completed = true;
    return true;
}
fn requestCameraRepaint() void {
    camera_live.stop();
    shown_session_view = null;
    if (renderer_ready) renderer.invalidate();
    @atomicStore(u32, &dirty, 1, .release);
}

fn status() boot.Status {
    if (model.failure_latched) return .failed;
    const stage = model.active orelse model.last_complete orelse return .display;
    return switch (stage) {
        .crt, .memory => .memory,
        .storage => .storage,
        .display_prepare, .display_scanout => .display,
        .cores => .cores,
        .input => .input,
        .console => .ready,
    };
}
noinline fn drawDetails() bool {
    if (!renderer_ready) {
        // Avoid a multi-kilobyte default-value constant in scarce SRAM.
        @memset(@import("std").mem.asBytes(renderer), 0);
        @memset(@import("std").mem.asBytes(live_text), 0);
        console.snapshot.fill(live_text, &model, journal.spans(), journal.dropped);
        renderer_ready = true;
    }
    if (!shown_details) renderer.invalidate();
    // A real stage transition must publish its header before entering work.
    if (renderer.moving() and !renderer.finish(frame(), 1440, palette())) return false;
    const previous = if (options.console_live) 0 else mask();
    console.snapshot.refreshHeader(live_text, &model, journal.dropped);
    if (!options.console_live) restore(previous);
    if (!renderer.submit(frame(), 1440, live_text, palette())) return false;
    if (!paintTouchControl()) return false;
    if (options.devices and touch_available) {
        const box = pointer.view_button;
        renderer.damage.include(box.x, box.y, box.x + box.width, box.y + box.height);
    }
    return presentDamage();
}
pub noinline fn snapshot() bool {
    if (!options.console) return true;
    if (!model.begin(.console) or !model.complete(.console)) return false;
    return drawDetails();
}
pub noinline fn report(log: anytype) void {
    if (!options.console) return;
    const values: extern struct { status: u32, columns: u32, rows: u32, log_bytes: u32, dropped_low: u32, input: u32 } = .{
        .status = 1,
        .columns = geometry.columns,
        .rows = geometry.rows,
        .log_bytes = @intCast(journal.length),
        .dropped_low = @truncate(journal.dropped),
        .input = @intFromBool(model.input_available),
    };
    log.record("NIHOS_NATIVE_CONSOLE", null, .{ "status", "columns", "rows", "log_bytes", "dropped_low", "input" }, &values);
    const selected = console.raster.colors(@fromBackingInt(@intCast(options.console_palette)));
    const style: extern struct { cell_width: u32, cell_height: u32, palette: u32, foreground: u32, accent: u32, background: u32, font: u32 } = .{
        .cell_width = geometry.cell_width,
        .cell_height = geometry.cell_height,
        .palette = options.console_palette,
        .foreground = selected.foreground,
        .accent = selected.accent,
        .background = selected.background,
        .font = options.console_font,
    };
    log.record("NIHOS_NATIVE_CONSOLE_STYLE", null, .{ "cell_width", "cell_height", "palette", "foreground", "accent", "background", "font" }, &style);
}
pub noinline fn input(log: anytype) void {
    model.input_sources = console.keys.capability(.serial); // Independent of USB-A host.
    model.input_available = true;
    input_started = clock.timer().counter() orelse 0;
    var error_code: u32 = 0;
    if (options.keyboard_i2c) {
        nih_keyboard_pads_init();
        hardware_ready = keyboard.begin() catch blk: {
            error_code = 1;
            break :blk false;
        };
        if (hardware_ready) model.input_sources |= console.keys.capability(.tab5_keyboard);
    }
    const values: extern struct { status: u32, firmware: u32, mode: u32, transactions: u32, error_code: u32, sources: u32 } = .{
        .status = if (hardware_ready) 1 else 2,
        .firmware = keyboard.report.firmware,
        .mode = keyboard.report.mode,
        .transactions = bus.transactions,
        .error_code = error_code,
        .sources = model.input_sources,
    };
    log.record("NIHOS_NATIVE_KEYBOARD", null, .{ "status", "firmware", "mode", "transactions", "error_code", "sources" }, &values);
}
noinline fn action(value: console.keys.Action, source: console.keys.Source, modifiers: u8, usage: u8, log: anytype) void {
    const key: console.boot.Key = switch (value) {
        .logs => .escape,
        .splash => .splash,
        .pause => .break_boot,
        .resume_boot => .resume_boot,
    };
    const accepted = model.onKey(key);
    if (accepted) revision +%= 1;
    sequence +%= 1;
    const values: extern struct { sequence: u32, source: u32, action: u32, modifiers: u32, usage: u32, accepted: u32, view: u32, stage: u32, frames: u32 } = .{ .sequence = sequence, .source = @as(u32, @backingInt(source)), .action = @as(u32, @backingInt(value)), .modifiers = @as(u32, modifiers), .usage = @as(u32, usage), .accepted = @as(u32, @intFromBool(accepted)), .view = @as(u32, @intFromBool(model.details)), .stage = if (model.active) |stage| @as(u32, @backingInt(stage)) + 1 else 0, .frames = runtime.snapshot().frames };
    log.record("NIHOS_NATIVE_DIAGNOSTIC_KEY", null, .{ "sequence", "source", "action", "modifiers", "usage", "accepted", "view", "stage", "frames" }, &values);
    @atomicStore(u32, &dirty, 1, .release);
}
noinline fn poll(now: u64, log: anytype) linksection(if (options.camera_id) ".flash.text.devices" else ".text") void {
    if (now - last_input < 10_000 or !model.input_available) return;
    last_input = now;
    if (options.devices) {
        const available = nih_touch_available();
        if (available != touch_available) {
            touch_available = available;
            view_button = .{};
            if (available) model.input_sources |= console.keys.capability(.touch) else model.input_sources &= ~console.keys.capability(.touch);
            revision +%= 1;
            if (renderer_ready) renderer.invalidate();
            const box = pointer.view_button;
            const input_status: extern struct { available: u32, sources: u32, x: u32, y: u32, width: u32, height: u32 } = .{ .available = @intFromBool(available), .sources = model.input_sources, .x = box.x, .y = box.y, .width = box.width, .height = box.height };
            log.record("NIHOS_NATIVE_TOUCH_UI", null, .{ "available", "sources", "x", "y", "width", "height" }, &input_status);
        }
        for (0..8) |_| {
            var event: pointer.Event = .{ .kind = .cancel };
            if (!nih_touch_pop(&event)) break;
            if (!available or model.failure_latched or event.at < input_started) continue;
            if (view_button.observe(event, pointer.view_button)) {
                if (xy_workspace and session_active) {
                    sessionKey(.escape, log);
                    continue;
                }
                if (camera_overlay.state == .visible) {
                    camera_input_sequence +%= 1;
                    _ = camera_overlay.dismiss(camera_input_sequence);
                    requestCameraRepaint();
                } else if (camera_overlay.state == .idle) {
                    if (camera_live.state != .idle) sessionKey(.escape, log) else action(if (model.details) .splash else .logs, .touch, 0, 1, log);
                }
            }
        }
    }
    for (0..16) |_| {
        const byte = Session.input.transportByte(nih_diagnostic_serial_read()) orelse break;
        if (xy_workspace and session_active) {
            if (xy_trace) xy_input_bytes +%= 1;
            scratch.feedSerial(byte, now);
            @atomicStore(u32, &dirty, 1, .release);
            continue;
        }
        var consumed = false;
        if (@hasDecl(options, "normal_storage") and options.normal_storage) {
            var command: ?storage_control.Command = null;
            consumed = storage_commands.feed(@intCast(byte), &command);
            if (command) |value| nih_fs_command(value.path.ptr, @intCast(value.path.len));
        }
        if (options.devices) {
            var command: ?control.Command = null;
            if (device_commands.feed(@intCast(byte), &command)) {
                if (command) |value| _ = nih_device_request(@backingInt(value));
                consumed = true;
            }
        }
        if (consumed) continue;
        if (session_active) {
            if (session_serial.feed(@intCast(byte), now)) |key| sessionKey(key, log);
        } else if (serial.feed(@intCast(byte), now)) |value| action(value, .serial, 0, @intCast(byte), log);
    }
    if (session_active) {
        if (xy_workspace) scratch.expireSerial(now) else if (session_serial.expire(now)) |key| sessionKey(key, log);
    } else if (serial.expire(now)) |value| action(value, .serial, 0, 0x1b, log);
    if (hardware_ready) {
        var events: [4]console.keyboard.Event = undefined;
        const count = keyboard.poll(&events) catch blk: {
            hardware_ready = false;
            model.input_sources &= ~console.keys.capability(.tab5_keyboard);
            break :blk 0;
        };
        for (events[0..count]) |event| {
            if (session_active) {
                if (session_hid.feed(event.modifiers, event.usage)) |key| sessionKey(key, log);
            } else if (console.keys.hid(event.modifiers, event.usage)) |value| action(value, .tab5_keyboard, event.modifiers, event.usage, log);
        }
    }
}

pub fn startSession(log: anytype) bool {
    if (!options.console_live or model.failure_latched) return false;
    // Finish the existing milestone-driven splash before handing over input.
    session_pending = true;
    model.details = false;
    revision +%= 1;
    return service(log);
}
fn beginSession(log: anytype) void {
    @memset(@import("std").mem.asBytes(session), 0);
    if (comptime xy_workspace) {
        scratch.initInPlace();
        (SerialSink{}).write("\r\nxy / *scratch* [RAM]\r\n");
    } else session.begin(SerialSink{});
    // Do not let a boot-time partial serial escape leak into the shell.
    session_serial = .{};
    session_hid = .{};
    session_active = true;
    session_pending = false;
    if (comptime xy_workspace) {
        const values: extern struct { document_bytes: u32, undo_ops: u32, workspace_bytes: u32, persistent: u32, unicode_raster: u32 } = .{ .document_bytes = 4096, .undo_ops = 256, .workspace_bytes = @sizeOf(console.scratch.Model), .persistent = 0, .unicode_raster = 0 };
        log.record("NIHOS_NATIVE_XY_READY", null, .{ "document_bytes", "undo_ops", "workspace_bytes", "persistent", "unicode_raster" }, &values);
    } else {
        const values: extern struct { view: u32, line_bytes: u32, history_bytes: u32 } = .{ .view = @as(u32, @backingInt(session.view)), .line_bytes = @as(u32, session.line.len), .history_bytes = @as(u32, session.output.bytes.len) };
        log.record("NIHOS_NATIVE_SESSION_READY", null, .{ "view", "line_bytes", "history_bytes" }, &values);
    }
    @atomicStore(u32, &dirty, 1, .release);
}
noinline fn sessionKey(key: Session.input.Key, log: anytype) linksection(if (options.camera_id) ".flash.text.devices" else ".text") void {
    if (xy_workspace) {
        scratch.handle(key);
        @atomicStore(u32, &dirty, 1, .release);
        return;
    }
    const before = session.view;
    if (camera_live.state == .draining and camera_overlay.state == .idle) return;
    if (cameraLiveActive() and camera_overlay.state == .idle) {
        camera_live.stop();
        session.write(SerialSink{}, "Camera preview stopped.\r\n");
        @atomicStore(u32, &dirty, 1, .release);
        return;
    }
    if (options.camera_ui_fixture and key == .clear and camera_overlay.canShow()) {
        const ok = showCameraPreview(&fixture_pixels, true);
        const values: extern struct { ok: u32, view: u32, line_bytes: u32, selected: u32, mismatches: u32, frames: u32 } = .{ .ok = @intFromBool(ok), .view = @backingInt(session.view), .line_bytes = @intCast(session.length), .selected = @intCast(session.selected), .mismatches = camera_preview_mismatches, .frames = runtime.snapshot().frames };
        log.record("NIHOS_NATIVE_CAMERA_UI_FIXTURE", null, .{ "ok", "view", "line_bytes", "selected", "mismatches", "frames" }, &values);
        return;
    }
    camera_input_sequence +%= 1;
    const routed = camera_input.route(&camera_overlay, camera_input_sequence, session, key, SerialSink{});
    if (routed.disposition != .forwarded) {
        if (routed.disposition == .dismissed) requestCameraRepaint();
        return;
    }
    if (routed.command) |command| {
        switch (command) {
            .camera, .camera_live => {
                const accepted = options.camera_id and camera_live.state == .idle and nih_device_request(if (command == .camera_live and !options.camera_diagnostics) 30 else 26);
                if (accepted and command == .camera_live) _ = camera_live.start();
                session.write(SerialSink{}, if (!accepted) "Camera unavailable or busy.\r\n" else if (command == .camera_live) "Camera preview: press a key to stop.\r\n" else "Taking a camera snapshot. Press a key to close after it appears.\r\n");
            },
            .mem => {
                session.write(SerialSink{}, "CPU0 owner only (bytes; excludes stacks/display):\r\n");
                if (tasks.memory.localUsage()) |usage| sessionUsage("SRAM boot arena", usage.capacity, usage.free) else session.write(SerialSink{}, "SRAM boot arena unavailable\r\n");
                if (tasks.memory.reusable.localUsage()) |usage| sessionUsage("PSRAM reusable heap", usage.capacity, usage.free) else session.write(SerialSink{}, "PSRAM reusable heap unavailable\r\n");
            },
            .tasks => {
                session.write(SerialSink{}, "Published runtime counters (per-field snapshots):\r\n");
                for (0..2) |index| {
                    const observed = tasks.report(@intCast(index));
                    session.write(SerialSink{}, "hart ");
                    session.number(SerialSink{}, @intCast(index));
                    session.write(SerialSink{}, " ticks=");
                    session.number(SerialSink{}, observed.ticks);
                    session.write(SerialSink{}, " switches=");
                    session.number(SerialSink{}, observed.switches);
                    session.write(SerialSink{}, " calls=");
                    session.number(SerialSink{}, observed.calls);
                    session.write(SerialSink{}, "\r\n");
                }
                session.write(SerialSink{}, "Normal boot runs bootstrap/idle; no user apps yet.\r\n");
            },
            else => unreachable,
        }
    }
    if (session.view != before) {
        if (session.view == .logs) {
            for (journal.spans()) |part| (SerialSink{}).write(part);
            (SerialSink{}).write("\r\nEsc: launcher\r\n");
        }
        const values = .{ .from = @as(u32, @backingInt(before)), .to = @as(u32, @backingInt(session.view)) };
        log.record("NIHOS_NATIVE_SESSION_VIEW", null, .{ "from", "to" }, &values);
    }
    session.finishInput(key, before, SerialSink{});
    @atomicStore(u32, &dirty, 1, .release);
}
fn sessionUsage(label: []const u8, capacity: u32, free: u32) void {
    session.write(SerialSink{}, label);
    session.write(SerialSink{}, " capacity=");
    session.number(SerialSink{}, capacity);
    session.write(SerialSink{}, " free=");
    session.number(SerialSink{}, free);
    session.write(SerialSink{}, " used=");
    session.number(SerialSink{}, capacity - free);
    session.write(SerialSink{}, "\r\n");
}
noinline fn traceScratch(log: anytype) void {
    if (!xy_trace or (scratch.revision == last_xy_trace_revision and xy_input_bytes == last_xy_input_bytes)) return;
    last_xy_trace_revision = scratch.revision;
    last_xy_input_bytes = xy_input_bytes;
    var fnv: u32 = 0x811c9dc5;
    for (scratch.doc.slice()) |byte| fnv = (fnv ^ byte) *% 0x01000193;
    const values: extern struct { revision: u32, bytes: u32, cursor: u32, fnv: u32, mode: u32, frames: u32, input_bytes: u32, pending_utf8: u32, status: u32 } = .{ .revision = scratch.revision, .bytes = scratch.doc.len, .cursor = scratch.doc.cursor, .fnv = fnv, .mode = @backingInt(scratch.mode), .frames = runtime.snapshot().frames, .input_bytes = xy_input_bytes, .pending_utf8 = scratch.utf8_length, .status = @backingInt(scratch.status) };
    log.record("NIHOS_NATIVE_XY_STATE", null, .{ "revision", "bytes", "cursor", "fnv", "mode", "frames", "input_bytes", "pending_utf8", "status" }, &values);
}
fn drawSession() bool {
    if (!renderer_ready) {
        @memset(@import("std").mem.asBytes(renderer), 0);
        renderer_ready = true;
    }
    if (renderer.moving() and !renderer.finish(frame(), 1440, palette())) return false;
    if (shown_session_view != session.view) renderer.invalidate();
    if (xy_workspace) scratch.render(live_text) else if (session.view == .logs) {
        console.snapshot.fill(live_text, &model, journal.spans(), journal.dropped);
        // The boot snapshot's controls no longer apply after session handoff.
        @memset(live_text.cells[5 * geometry.columns .. 6 * geometry.columns], ' ');
        const hint = "Esc: launcher | Ctrl-C: return";
        @memcpy(live_text.cells[5 * geometry.columns ..][0..hint.len], hint);
    } else session.render(live_text);
    if (!renderer.submit(frame(), 1440, live_text, palette()) or !presentDamage()) return false;
    shown_session_view = session.view;
    shown_session_revision = if (xy_workspace) scratch.revision else session.revision;
    return true;
}
pub noinline fn service(log: anytype) bool {
    if (!options.console_live or !runtime.active()) return true;
    if (!clock_ready or rendering) return false;
    const observed = runtime.snapshot();
    if (observed.fault != 0) return false;
    const now = clock.timer().counter() orelse return false;
    poll(now, log);
    // Input may dismiss an overlay while the next frame is already in DMA.
    // Drain it before a full shell repaint competes for PSRAM/cache bandwidth.
    if (!camera_live.canRepaint()) return true;
    if (camera_overlay.state == .visible) return true;
    const next_status = status();
    const forced = shown_status != next_status or shown_details != model.details or revision != shown_revision or camera_overlay.state == .repaint_pending or camera_overlay.state == .recovery_pending;
    const new_frame = observed.frames != last_frame;
    if (!new_frame and !forced) return true;
    last_frame = observed.frames;
    const changed = @atomicRmw(u32, &dirty, .Xchg, 0, .acquire) != 0;
    if (session_active) {
        if (changed or shown_session_view != session.view or shown_session_revision != (if (xy_workspace) scratch.revision else session.revision) or renderer.moving()) {
            rendering = true;
            defer rendering = false;
            if (!drawSession()) return false;
            if (comptime xy_trace) traceScratch(log);
            if (camera_overlay.repainted()) |result| {
                const values: extern struct { kind: u32, sequence: u32, view: u32, line_bytes: u32, selected: u32, frames: u32 } = .{ .kind = switch (result) {
                    .dismissal => 1,
                    .recovery => 2,
                }, .sequence = switch (result) {
                    .dismissal => |seq| seq,
                    .recovery => 0,
                }, .view = @backingInt(session.view), .line_bytes = @intCast(session.length), .selected = @intCast(session.selected), .frames = runtime.snapshot().frames };
                log.record("NIHOS_NATIVE_CAMERA_UI_REPAINT", null, .{ "kind", "sequence", "view", "line_bytes", "selected", "frames" }, &values);
            }
            return true;
        }
        return true;
    }
    const selected = status();
    const target = model.dyeTarget();
    const old_progress = progress;
    if (new_frame and progress < target) progress = @intCast(@min(@as(u16, progress) + 3, target));
    const full = forced;
    rendering = true;
    defer rendering = false;
    if (model.details) {
        if (renderer_ready and renderer.moving() and new_frame) {
            const started = clock.timer().counter() orelse return false;
            const cycles = asm volatile ("csrr %[value], mcycle"
                : [value] "=r" (-> u32),
            );
            if (!renderer.step(frame(), 1440, palette())) return false;
            const copied = clock.timer().counter() orelse return false;
            if (!presentDamage()) return false;
            const ended = clock.timer().counter() orelse return false;
            const cycles_end = asm volatile ("csrr %[value], mcycle"
                : [value] "=r" (-> u32),
            );
            cpu_mhz = (cycles_end -% cycles) / @max(@as(u32, @intCast(@min(ended - started, 0xffff_ffff))), 1);
            max_copy_us = @max(max_copy_us, @as(u32, @intCast(@min(copied - started, 0xffff_ffff))));
            max_cache_us = @max(max_cache_us, @as(u32, @intCast(@min(ended - copied, 0xffff_ffff))));
            max_scroll_us = @max(max_scroll_us, @as(u32, @intCast(@min(ended - started, 0xffff_ffff))));
            if (renderer.distance <= geometry.cell_height * 2) line_step_us = @max(line_step_us, @as(u32, @intCast(@min(ended - started, 0xffff_ffff))));
        }
        if (full or (changed and (!renderer_ready or !renderer.moving()) and now - last_render >= 33_333)) {
            if (!drawDetails()) return false;
            last_render = now;
        } else if (changed) @atomicStore(u32, &dirty, 1, .release);
    } else if (full) {
        if (!boot.paintLandscapePlacedRgb565Le(".flash.rodata.boot_graphics", frame(), 720, 1280, 1440, progress, selected) or !paintTouchControl() or !present()) return false;
    } else if (progress != old_progress) {
        if (!boot.recolorLandscapePlacedRgb565Le(".flash.rodata.boot_graphics", frame(), 720, 1280, 1440, progress, selected) or !paintTouchControl() or !present()) return false;
    }
    shown_revision = revision;
    shown_status = selected;
    shown_details = model.details;
    if (!settled_reported and !model.details and progress == 255 and target == 255) {
        settled_reported = true;
        const values: extern struct { frames: u32, progress: u32, target: u32 } = .{ .frames = runtime.snapshot().frames, .progress = progress, .target = target };
        log.record("NIHOS_NATIVE_UI_SETTLED", null, .{ "frames", "progress", "target" }, &values);
    }
    if (session_pending and progress == 255) {
        if (model.details) {
            // A late boot-time Esc may have selected logs. Publish the final
            // splash/settled record before the next frame hands over the UI.
            model.details = false;
            revision +%= 1;
            return true;
        }
        beginSession(log);
        return drawSession();
    }
    return true;
}
pub noinline fn checkpoint(log: anytype) bool {
    if (!options.console_live) return true;
    if (!model.atSafeCheckpoint()) return true;
    const entered: extern struct { frames: u32, last_stage: u32 } = .{ .frames = runtime.snapshot().frames, .last_stage = if (model.last_complete) |stage| @as(u32, @backingInt(stage)) + 1 else 0 };
    log.record("NIHOS_NATIVE_UI_PAUSE", null, .{ "frames", "last_stage" }, &entered);
    while (model.atSafeCheckpoint()) {
        if (!service(log)) return false;
        asm volatile ("wfi" ::: .{ .memory = true });
    }
    const resumed: extern struct { frames: u32 } = .{ .frames = runtime.snapshot().frames };
    log.record("NIHOS_NATIVE_UI_RESUME", null, .{"frames"}, &resumed);
    return true;
}
/// Direct fatal path: no allocation, scheduler, key requirement or IRQ dependence.
pub noinline fn failureFrame() bool {
    if (!options.console_live or !clock_ready or !runtime.active() or rendering or runtime.snapshot().fault != 0) return false;
    failed();
    if (renderer_ready) renderer.invalidate();
    rendering = true;
    defer rendering = false;
    return drawDetails();
}
pub noinline fn liveReport(log: anytype, comptime ready: bool) void {
    const values: extern struct { frames: u32, clock_hz: u32, sources: u32, view: u32, progress: u32, target: u32 } = .{ .frames = runtime.snapshot().frames, .clock_hz = @as(u32, 1_000_000), .sources = @as(u32, model.input_sources), .view = @as(u32, @intFromBool(model.details)), .progress = @as(u32, progress), .target = @as(u32, model.dyeTarget()) };
    if (ready) {
        if (renderer_ready) {
            const stats: extern struct { full: u32, partial: u32, scrolls: u32, steps: u32, max_step_us: u32, copy_us: u32, cache_us: u32, cache_chunk_us: u32, line_step_us: u32, cpu_mhz: u32 } = .{ .full = renderer.full_paints, .partial = renderer.partial_updates, .scrolls = renderer.scrolls, .steps = renderer.steps, .max_step_us = max_scroll_us, .copy_us = max_copy_us, .cache_us = max_cache_us, .cache_chunk_us = max_cache_chunk_us, .line_step_us = line_step_us, .cpu_mhz = cpu_mhz };
            log.record("NIHOS_NATIVE_CONSOLE_RENDER", null, .{ "full", "partial", "scrolls", "steps", "max_step_us", "copy_us", "cache_us", "cache_chunk_us", "line_step_us", "cpu_mhz" }, &stats);
        }
        const io: extern struct { tx_dropped: u32 } = .{ .tx_dropped = nih_diagnostic_serial_dropped() };
        log.record("NIHOS_NATIVE_UI_IO", null, .{"tx_dropped"}, &io);
    }
    log.record(if (ready) "NIHOS_NATIVE_UI_READY" else "NIHOS_NATIVE_UI_START", null, .{ "frames", "clock_hz", "sources", "view", "progress", "target" }, &values);
}

pub fn timer() @import("timer_group").Timer {
    return clock.timer();
}

fn paintTouchControl() bool {
    if (!options.devices or !touch_available or !model.input_available or model.failure_latched) return true;
    const box = pointer.view_button;
    return console.raster.paintControl(".flash.rodata.display", frame(), 1440, .{ .left = box.x, .top = box.y, .right = box.x + box.width, .bottom = box.y + box.height }, if (model.details) "SPLASH" else "LOGS", palette());
}
