//! Opt-in first-frame experiment after native memory/IPI qualification.
//! CPU0 CLIC18 refreshes one descriptor; CPU1 never touches the framebuffer.
const board = @import("tab5_display");
const options = @import("native_options");
const panels = @import("tab5_panels");
const dcs = @import("display_dcs");
const Scanout = @import("scanout_state").State;
const boot = @import("boot_graphics");
const timer_group = @import("timer_group");
const Pins = @import("display_probe.zig").Pins;
extern fn nih_display_phy_power() callconv(.c) u32;
extern fn nih_display_phy_init(u32) callconv(.c) void;
extern fn nih_display_phy_status() callconv(.c) u32;
extern fn nih_display_phy_stop() callconv(.c) void;
extern fn nih_display_phy_power_off() callconv(.c) void;
extern fn nih_display_command_setup() callconv(.c) void;
extern fn nih_display_command_status() callconv(.c) u32;
extern fn nih_display_command_payload(u32) callconv(.c) void;
extern fn nih_display_command_header(u32, u32, u32) callconv(.c) void;
extern fn nih_display_scanout_begin(u32, *const panels.Timing, u32, u32, u32) callconv(.c) i32;
extern fn nih_display_scene_refresh(u32) callconv(.c) bool;
extern fn nih_display_scanout_poll() callconv(.c) u32;
extern fn nih_display_scanout_stop() callconv(.c) bool;
extern fn nih_display_scanout_pause_request() callconv(.c) bool;
extern fn nih_display_scanout_paused() callconv(.c) bool;
extern fn nih_display_backlight(bool) callconv(.c) void;
extern fn nih_display_pattern_enable(*const panels.Timing) callconv(.c) void;
extern fn nih_display_dma_irq_source() callconv(.c) u32;
extern fn nih_display_diagnostic(u32) callconv(.c) u32;
extern fn nih_display_notice_status() callconv(.c) u32;
extern fn nih_rom_cache_writeback(u32, u32, u32) callconv(.c) i32;

var state: Scanout = .{};
var running = false;
var attempted = false;
var last_event: u32 = 0;
var scene_updates: u32 = 0;
var max_scene_pause_us: u32 = 0;
var scene_stage: u32 = 0;
var scene_error: u32 = 0;
pub fn active() bool {
    return running;
}
pub fn irqSource() u32 {
    return nih_display_dma_irq_source();
}
pub noinline fn onInterrupt() void {
    // Bootstrap/foreground pollers share this path with CLIC18. A poll must
    // not itself be interrupted by another DMA completion/cache transaction.
    const previous = asm volatile ("csrrci %[value],mstatus,8"
        : [value] "=r" (-> u32),
        :
        : .{ .memory = true });
    defer if (previous & 8 != 0) asm volatile ("csrsi mstatus,8" ::: .{ .memory = true });
    if (!running) return;
    const event = nih_display_scanout_poll();
    if (event != 0) last_event = event;
    state.observe(event & 1 != 0, event & 10, event & 4 != 0);
    nih_display_backlight(state.backlight);
}
pub const Report = struct { status: u32 = 2, stage: u32 = 0, error_code: u32 = 0, panel: u32 = 0, commands: u32 = 0, last_command: u32 = 0, frames: u32 = 0, fault: u32 = 0, event: u32 = 0, backlight: u32 = 0, dpi_mhz: u32 = 10, lane_mbps: u32 = 0, cleanup: u32 = 0, dsi_error0: u32 = 0, dsi_error1: u32 = 0, dma_error: u32 = 0, bridge_error: u32 = 0, start_code: u32 = 0, prime_depth: u32 = 0, bl_latch: u32 = 0, bl_enable: u32 = 0, bl_level: u32 = 0, bl_mux: u32 = 0, bl_matrix: u32 = 0, white: u32 = 0, sram: u32 = 0, source: u32 = 0, dma_source: u32 = 0, dma_control: u32 = 0, word: u32 = 0, lease_start: u32 = 0, lease_bytes: u32 = 0, nodes: u32 = 0, font_low: u32 = 0, font_low_bytes: u32 = 0, pixel_bytes: u32 = 0, pool0_start: u32 = 0, pool0_bytes: u32 = 0, pool1_start: u32 = 0, pool1_bytes: u32 = 0 };
pub fn snapshot() Report {
    const previous = asm volatile ("csrrci %[previous], mstatus, 8"
        : [previous] "=r" (-> u32),
        :
        : .{ .memory = true });
    defer if (previous & 8 != 0) asm volatile ("csrsi mstatus, 8" ::: .{ .memory = true });
    return .{ .status = if (running and state.fault == 0) 1 else 2, .frames = state.frames, .fault = state.fault, .event = last_event, .backlight = @intFromBool(state.backlight), .dsi_error0 = nih_display_diagnostic(0), .dsi_error1 = nih_display_diagnostic(1), .dma_error = nih_display_diagnostic(2), .bridge_error = nih_display_diagnostic(3) };
}
pub const NoticeReport = struct { swaps: u32, panel_starts: u32, backlight_offs: u32, frames: u32, backlight: u32, fault: u32 };
pub const SceneReport = struct { updates: u32, max_pause_us: u32, stage: u32, error_code: u32 };
pub fn sceneSnapshot() SceneReport {
    return .{ .updates = scene_updates, .max_pause_us = max_scene_pause_us, .stage = scene_stage, .error_code = scene_error };
}
pub fn noticeSnapshot() NoticeReport {
    const current = snapshot();
    return .{ .swaps = nih_display_diagnostic(15), .panel_starts = nih_display_diagnostic(16), .backlight_offs = nih_display_diagnostic(17), .frames = current.frames, .backlight = current.backlight, .fault = current.fault };
}

const Sender = struct {
    pins: Pins,
    pub fn wait(self: Sender, mask: u32) !void {
        const started_at = self.pins.clock.counter() orelse return error.Timer;
        for (0..100_000) |_| {
            const status = nih_display_command_status();
            if (status & 8 != 0) return error.Link;
            if (status & mask == mask) return;
            const now = self.pins.clock.counter() orelse return error.Timer;
            if (now - started_at >= 50_000) return error.Timeout;
        }
        return error.Timeout;
    }
    pub fn payload(_: Sender, word: u32) void {
        nih_display_command_payload(word);
    }
    pub fn header(_: Sender, kind: u32, low: u32, high: u32) void {
        nih_display_command_header(kind, low, high);
    }
};
fn send(sender: Sender, report: *Report, command: u8, parameters: []const u8, delay_ms: u32) !void {
    report.last_command = command;
    try dcs.send(sender, command, parameters);
    report.commands += 1;
    if (!sender.pins.delay(delay_ms * 1000)) return error.Timer;
}
fn waitFrame(pins: Pins, previous: u32) !void {
    const started_at = pins.clock.counter() orelse return error.Timer;
    for (0..1_000_000) |_| {
        onInterrupt();
        if (state.fault != 0) return error.Scanout;
        if (state.frames > previous) return;
        const now = pins.clock.counter() orelse return error.Timer;
        if (now - started_at >= 200_000) return error.Timeout;
    }
    return error.Timeout;
}
fn initialize(clock: timer_group.Timer, panel: u32, white: bool, pattern: bool, sram: bool, report: *Report, powered: *bool, phy_started: *bool) !void {
    var selected = panels.timing(panel) orelse return error.Panel;
    if (options.card_read or options.keypad_demo) {
        selected.dpi_mhz = if (panel == 1) 60 else 80;
    } else if (sram or options.psram_200) selected = panels.refreshProfile(panel, options.display_hz) orelse return error.Panel;
    report.panel = panel;
    report.dpi_mhz = selected.dpi_mhz;
    report.lane_mbps = selected.lane_mbps;
    const pins = Pins{ .clock = clock };
    const sender = Sender{ .pins = pins };
    report.stage = 1;
    _ = nih_display_phy_power();
    powered.* = true;
    if (!pins.delay(1000)) return error.Timer;
    nih_display_phy_init(selected.lane_mbps);
    phy_started.* = true;
    const started = clock.counter() orelse return error.Timer;
    for (0..100_000) |_| {
        if (nih_display_phy_status() == 3) break;
        const now = clock.counter() orelse return error.Timer;
        if (now - started >= 50_000) return error.Timeout;
        if (!pins.delay(10)) return error.Timer;
    } else return error.Timeout;
    report.stage = 2;
    nih_display_command_setup();
    try send(sender, report, 0x01, &.{}, 120);
    if (panel == 1) {
        try send(sender, report, 0xff, &.{ 0x98, 0x81, 1 }, 0);
        try send(sender, report, 0xb7, &.{3}, 0);
        try send(sender, report, 0xff, &.{ 0x98, 0x81, 0 }, 0);
        try send(sender, report, 0x11, &.{}, 120);
        try send(sender, report, 0x36, &.{0}, 0);
        try send(sender, report, 0x3a, &.{0x55}, 0);
    }
    var position: usize = 0;
    var madctl: u8 = 0;
    const commands = panels.table(".flash.rodata.display", panel) orelse return error.Panel;
    while (try panels.next(commands, &position)) |command| {
        try send(sender, report, command.opcode, command.payload, @as(u32, command.delay_ms) + (if (options.boot_fast) @as(u32, 0) else 5));
        if (command.opcode == 0x36 and command.payload.len == 1) madctl = command.payload[0];
    }
    try send(sender, report, 0x20, &.{}, 0);
    try send(sender, report, 0x36, &.{madctl & ~@as(u8, 3)}, 0);
    try send(sender, report, 0x29, &.{}, 50);
    report.stage = 3;
    const base: [*]u8 = @ptrFromInt(board.framebuffer);
    const frame = base[0..board.frame_bytes];
    const paint = if (options.display_tile) boot.paintPlacedRgb565Le else boot.paintLandscapePlacedRgb565Le;
    const recolor = if (options.display_tile) boot.recolorPlacedRgb565Le else boot.recolorLandscapePlacedRgb565Le;
    if (comptime options.keypad_demo or options.card_read) {
        const prepared = try @import("keypad_display.zig").prepare(clock, frame);
        report.lease_start = prepared.local_start;
        report.lease_bytes = prepared.local_bytes;
        report.font_low = prepared.font_low;
        report.font_low_bytes = prepared.font_low_bytes;
        report.pixel_bytes = prepared.pixel_bytes;
        const renderer = @import("keypad_display.zig");
        report.pool0_start = renderer.low_start;
        report.pool0_bytes = renderer.low_end - renderer.low_start;
        report.pool1_start = renderer.high_start;
        report.pool1_bytes = renderer.high_end - renderer.high_start;
    } else if (white) @memset(frame, 0xff) else if (!paint(".flash.rodata.boot_graphics", frame, 720, 1280, 1440, 0, if (options.console_live) .display else .ready)) return error.Image;
    if (nih_rom_cache_writeback((1 << 4) | (1 << 5), board.framebuffer, board.frame_bytes) != 0) return error.Cache;
    if (options.display_tile) {
        const rows: usize = if (options.display_scene) 40 + 112 + 14 + 10 else 40;
        const lease = @import("native_tasks").memory.alloc((1 + 2 * rows) * 64, 64) orelse return error.Image;
        report.lease_start = @intFromPtr(lease.ptr);
        report.lease_bytes = lease.len;
        if (options.display_scene and !nih_display_scene_refresh(board.framebuffer)) return error.Cache;
    }
    const source_kind: u32 = if (options.card_auto and @import("keypad_display.zig").notice_frame) 5 else if ((options.keypad_demo or options.card_read)) 4 else if (options.display_scene) 3 else if (options.display_tile) 2 else @intFromBool(sram);
    const start_code = nih_display_scanout_begin(board.framebuffer, &selected, source_kind, report.lease_start, report.lease_bytes);
    report.start_code = @bitCast(start_code);
    report.prime_depth = nih_display_diagnostic(4);
    if (start_code != 0) return error.Scanout;
    running = true;
    report.stage = 4;
    try waitFrame(pins, 0);
    try waitFrame(pins, state.frames);
    if (pattern) {
        nih_display_pattern_enable(&selected);
        report.dpi_mhz = if (panel == 1) 60 else 80;
    }
    if (!options.console_live and !options.card_read and !options.keypad_demo and !white and (!options.display_tile or options.display_scene)) for (0..60) |_| try waitFrame(pins, state.frames);
    if (!options.console_live and !options.card_read and !options.keypad_demo and !white and (!options.display_tile or options.display_scene)) for (1..33) |step| {
        try waitFrame(pins, state.frames);
        if (!recolor(".flash.rodata.boot_graphics", frame, 720, 1280, 1440, @intCast(step * 255 / 32), .ready)) return error.Image;
        if (options.display_scene) {
            if (!nih_display_scene_refresh(board.framebuffer)) return error.Cache;
            for (0..3) |_| try waitFrame(pins, state.frames);
        } else {
            if (nih_rom_cache_writeback((1 << 4) | (1 << 5), board.framebuffer, board.frame_bytes) != 0) return error.Cache;
            for (0..3) |_| try waitFrame(pins, state.frames);
        }
    };
    report.stage = 5;
    report.frames = state.frames;
    report.backlight = @intFromBool(state.backlight);
    report.bl_latch = nih_display_diagnostic(5);
    report.bl_enable = nih_display_diagnostic(6);
    report.bl_level = nih_display_diagnostic(7);
    report.bl_mux = nih_display_diagnostic(8);
    report.bl_matrix = nih_display_diagnostic(9);
    report.white = @intFromBool(white);
    report.sram = if ((options.keypad_demo or options.card_read)) 5 else if (options.display_scene) 2 else @intFromBool(sram);
    report.source = nih_display_diagnostic(10);
    report.dma_source = nih_display_diagnostic(11);
    report.dma_control = nih_display_diagnostic(12);
    report.word = nih_display_diagnostic(13);
    report.nodes = nih_display_diagnostic(14);
    report.status = 1;
}

/// Caller routes CLIC18 only after success. No framebuffer or DMA reuse on error.
pub noinline fn start(clock: timer_group.Timer, panel: u32, white: bool, pattern: bool, sram: bool) linksection(if (options.card_read) ".flash.text.card" else ".text") Report {
    if (attempted) return .{ .error_code = 8 };
    attempted = true;
    var report = Report{};
    var powered = false;
    var phy_started = false;
    if (!options.console_live) {
        clock.start();
        clock.disarm();
    }
    defer if (!options.console_live) clock.stop();
    initialize(clock, panel, white, pattern, sram, &report, &powered, &phy_started) catch |err| {
        report.error_code = switch (err) {
            error.Timer => 1,
            error.Timeout => 2,
            error.Link => 3,
            error.Panel => 4,
            error.Image => 5,
            error.Cache => 6,
            else => 7,
        };
        report.frames = state.frames;
        report.fault = state.fault;
        report.event = last_event;
        report.dsi_error0 = nih_display_diagnostic(0);
        report.dsi_error1 = nih_display_diagnostic(1);
        report.dma_error = nih_display_diagnostic(2);
        report.bridge_error = nih_display_diagnostic(3);
        running = false;
        const stopped = nih_display_scanout_stop();
        const erased = stopped and wipePools();
        const released = if (erased and (options.keypad_demo or options.card_read)) @import("keypad_display.zig").release() else erased;
        report.cleanup = if (released) 1 else 2;
        if (stopped and powered) {
            if (phy_started) nih_display_phy_stop() else nih_display_phy_power_off();
        }
        return report;
    };
    return report;
}

/// Foreground-only scene replacement. Retire DMA before clearing any retained
/// result pixels, then rebuild under masked local IRQs. No personal framebuffer
/// is modified while the display DMA borrows it.
pub noinline fn replace(clock: timer_group.Timer, panel: u32) linksection(if (options.card_read) ".flash.text.card" else ".text") Report {
    if ((options.card_read or options.keypad_demo) and running) return replaceCard(clock, panel) catch |err| {
        scene_error = switch (err) {
            error.Timer => 1,
            error.Timeout => 2,
            error.Cache => 3,
            error.Scanout => 4,
            else => 5,
        };
        // Capacity rejection precedes retirement and all live-SRAM writes.
        // The caller still decides whether its privacy policy must end the job.
        if (scene_stage == 1 and err == error.Lease) return .{ .error_code = 10 };
        // Never leave a private result visible or reuse possibly borrowed
        // SRAM after an unsuccessful handoff.
        const clean = emergency();
        return .{ .error_code = 9, .cleanup = if (clean) 1 else 2 };
    };
    const previous = asm volatile ("csrrci %[value],mstatus,8"
        : [value] "=r" (-> u32),
        :
        : .{ .memory = true });
    defer if (previous & 8 != 0) asm volatile ("csrsi mstatus,8" ::: .{ .memory = true });
    running = false;
    if (!nih_display_scanout_stop()) return .{ .error_code = 9 };
    nih_display_phy_stop();
    if (!wipePools()) return .{ .error_code = 6 };
    state = .{};
    last_event = 0;
    attempted = false;
    return start(clock, panel, false, false, true);
}
/// Stage solely in PSRAM while the old frame keeps scanning. At EOF retire
/// DMA/DPI, erase its SRAM, bind the new plan and restart video. The initialized
/// panel, DSI PHY and backlight stay on throughout ordinary UI transitions.
noinline fn replaceCard(clock: timer_group.Timer, panel: u32) linksection(if (options.card_read) ".flash.text.card" else ".text") !Report {
    const renderer = @import("keypad_display.zig");
    scene_stage = 1;
    scene_error = 0;
    if (!running or state.fault != 0) return error.Scanout;
    const frame = @as([*]u8, @ptrFromInt(board.framebuffer))[0..board.frame_bytes];
    const staged = try renderer.stage(frame);
    scene_stage = 2;
    const previous = asm volatile ("csrrci %[value],mstatus,8"
        : [value] "=r" (-> u32),
        :
        : .{ .memory = true });
    defer if (previous & 8 != 0) asm volatile ("csrsi mstatus,8" ::: .{ .memory = true });
    if (!nih_display_scanout_pause_request()) return error.Scanout;
    const pins = Pins{ .clock = clock };
    const requested = clock.counter() orelse return error.Timer;
    while (!nih_display_scanout_paused()) {
        onInterrupt();
        if (state.fault != 0) return error.Scanout;
        const now = clock.counter() orelse return error.Timer;
        if (now - requested >= 200_000) return error.Timeout;
    }
    const paused = clock.counter() orelse return error.Timer;
    scene_stage = 3;
    running = false;
    if (!wipePools()) return error.Cache;
    scene_stage = 4;
    const prepared = try renderer.bind(&staged);
    scene_stage = 5;
    var selected = panels.timing(panel) orelse return error.Panel;
    selected.dpi_mhz = if (panel == 1) 60 else 80;
    const source: u32 = if (options.card_auto and renderer.notice_frame) 5 else 4;
    if (nih_display_scanout_begin(board.framebuffer, &selected, source, prepared.local_start, prepared.local_bytes) != 0) return error.Scanout;
    running = true;
    scene_stage = 6;
    const resumed = clock.counter() orelse return error.Timer;
    max_scene_pause_us = @max(max_scene_pause_us, @as(u32, @intCast(@min(resumed - paused, 0xffffffff))));
    const before = state.frames;
    try waitFrame(pins, before);
    try waitFrame(pins, state.frames);
    scene_updates +|= 1;
    scene_stage = 7;
    return snapshot();
}
/// Public notices already scan from private SRAM banks. Keep the panel and
/// backlight running, publish the inactive bank, and await the frame handoff.
/// PIN/results use replace()'s frame-boundary handoff and erase retired pixels.
pub noinline fn presentNotice(clock: timer_group.Timer, panel: u32) linksection(if (options.card_auto) ".flash.photo" else ".text") !void {
    if (options.card_auto and running and nih_display_notice_status() != 0) {
        if (state.fault != 0) return error.Scanout;
        try @import("keypad_display.zig").publishNotice(@as([*]const u8, @ptrFromInt(board.framebuffer))[0..board.frame_bytes]);
        const pins = Pins{ .clock = clock };
        const started = clock.counter() orelse return error.Timer;
        while (nih_display_notice_status() == 2) {
            if (state.fault != 0) return error.Scanout;
            const now = clock.counter() orelse return error.Timer;
            if (now - started >= 200_000) return error.Timeout;
            if (!pins.delay(1000)) return error.Timer;
        }
        if (nih_display_notice_status() != 1) return error.Scanout;
    } else {
        const result = replace(clock, panel);
        clock.start();
        clock.disarm();
        if (result.status != 1) return error.Scanout;
    }
}
noinline fn wipePools() linksection(if (options.card_read) ".flash.text.card" else ".text") bool {
    if (!options.keypad_demo and !options.card_read) return true;
    const std = @import("std");
    const renderer = @import("keypad_display.zig");
    for ([_][2]u32{ .{ renderer.low_start, renderer.low_end }, .{ renderer.high_start, renderer.high_end } }) |span| {
        if (span[0] == span[1]) continue;
        const length = span[1] - span[0];
        std.crypto.secureZero(u8, @as([*]u8, @ptrFromInt(span[0]))[0..length]);
        if (nih_rom_cache_writeback(1 << 4, span[0], length) != 0) return false;
    }
    return true;
}
pub fn emergency() bool {
    running = false;
    const clean = nih_display_scanout_stop() and wipePools();
    const released = if (clean and (options.keypad_demo or options.card_read)) @import("keypad_display.zig").release() else clean;
    const std = @import("std");
    std.crypto.secureZero(u8, @as([*]u8, @ptrFromInt(board.framebuffer))[0..board.frame_bytes]);
    return nih_rom_cache_writeback((1 << 4) | (1 << 5), board.framebuffer, board.frame_bytes) == 0 and released;
}
