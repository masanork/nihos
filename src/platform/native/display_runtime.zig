//! Opt-in first-frame experiment after native memory/IPI qualification.
//! CPU0 CLIC18 refreshes one descriptor; CPU1 never touches the framebuffer.
const board = @import("tab5_display");
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
extern fn nih_display_scanout_begin(u32, *const panels.Timing) callconv(.c) i32;
extern fn nih_display_scanout_poll() callconv(.c) u32;
extern fn nih_display_scanout_stop() callconv(.c) bool;
extern fn nih_display_backlight(bool) callconv(.c) void;
extern fn nih_display_pattern_enable(*const panels.Timing) callconv(.c) void;
extern fn nih_display_dma_irq_source() callconv(.c) u32;
extern fn nih_display_diagnostic(u32) callconv(.c) u32;
extern fn nih_rom_cache_writeback(u32, u32, u32) callconv(.c) i32;

var state: Scanout = .{};
var running = false;
var attempted = false;
var last_event: u32 = 0;
pub fn active() bool {
    return running;
}
pub fn irqSource() u32 {
    return nih_display_dma_irq_source();
}
pub fn onInterrupt() void {
    if (!running) return;
    const event = nih_display_scanout_poll();
    if (event != 0) last_event = event;
    state.observe(event & 1 != 0, event & 10, event & 4 != 0);
    nih_display_backlight(state.backlight);
}
pub const Report = struct { status: u32 = 2, stage: u32 = 0, error_code: u32 = 0, panel: u32 = 0, commands: u32 = 0, last_command: u32 = 0, frames: u32 = 0, fault: u32 = 0, event: u32 = 0, backlight: u32 = 0, dpi_mhz: u32 = 10, lane_mbps: u32 = 0, cleanup: u32 = 0, dsi_error0: u32 = 0, dsi_error1: u32 = 0, dma_error: u32 = 0, bridge_error: u32 = 0, start_code: u32 = 0, prime_depth: u32 = 0, bl_latch: u32 = 0, bl_enable: u32 = 0, bl_level: u32 = 0, bl_mux: u32 = 0, bl_matrix: u32 = 0, white: u32 = 0 };
pub fn snapshot() Report {
    return .{ .status = if (running and state.fault == 0) 1 else 2, .frames = state.frames, .fault = state.fault, .event = last_event, .backlight = @intFromBool(state.backlight), .dsi_error0 = nih_display_diagnostic(0), .dsi_error1 = nih_display_diagnostic(1), .dma_error = nih_display_diagnostic(2), .bridge_error = nih_display_diagnostic(3) };
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
fn initialize(clock: timer_group.Timer, panel: u32, white: bool, pattern: bool, report: *Report, powered: *bool, phy_started: *bool) !void {
    var selected = panels.timing(panel) orelse return error.Panel;
    if (pattern) selected.dpi_mhz = 10;
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
        try send(sender, report, command.opcode, command.payload, @as(u32, command.delay_ms) + 5);
        if (command.opcode == 0x36 and command.payload.len == 1) madctl = command.payload[0];
    }
    try send(sender, report, 0x20, &.{}, 0);
    try send(sender, report, 0x36, &.{madctl & ~@as(u8, 3)}, 0);
    try send(sender, report, 0x29, &.{}, 50);
    report.stage = 3;
    const base: [*]u8 = @ptrFromInt(board.framebuffer);
    const frame = base[0..board.frame_bytes];
    if (white) @memset(frame, 0xff) else if (!boot.paintPlacedRgb565Le(".flash.rodata.boot_graphics", frame, 720, 1280, 1440, 0, .ready)) return error.Image;
    if (nih_rom_cache_writeback((1 << 4) | (1 << 5), board.framebuffer, board.frame_bytes) != 0) return error.Cache;
    const start_code = nih_display_scanout_begin(board.framebuffer, &selected);
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
    if (!white) for (1..17) |step| {
        try waitFrame(pins, state.frames);
        if (!boot.recolorPlacedRgb565Le(".flash.rodata.boot_graphics", frame, 720, 1280, 1440, @intCast(step * 255 / 16), .ready)) return error.Image;
        if (nih_rom_cache_writeback((1 << 4) | (1 << 5), board.framebuffer, board.frame_bytes) != 0) return error.Cache;
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
    report.status = 1;
}

/// Caller routes CLIC18 only after success. No framebuffer or DMA reuse on error.
pub fn start(clock: timer_group.Timer, panel: u32, white: bool, pattern: bool) Report {
    if (attempted) return .{ .error_code = 8 };
    attempted = true;
    var report = Report{};
    var powered = false;
    var phy_started = false;
    clock.start();
    clock.disarm();
    defer clock.stop();
    initialize(clock, panel, white, pattern, &report, &powered, &phy_started) catch |err| {
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
        report.cleanup = if (stopped) 1 else 2;
        if (stopped and powered) {
            if (phy_started) nih_display_phy_stop() else nih_display_phy_power_off();
        }
        return report;
    };
    return report;
}
