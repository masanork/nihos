//! Opt-in boot preparation only. This does not enable video or the backlight.
const board = @import("tab5_display");
const i2c = @import("boot_i2c");
const boot = @import("boot_graphics");
const timer_group = @import("timer_group");

extern fn nih_display_i2c_status() callconv(.c) u32;
extern fn nih_display_pads_init() callconv(.c) void;
extern fn nih_display_pin_release(u32, bool) callconv(.c) void;
extern fn nih_display_pin_level(u32) callconv(.c) bool;
extern fn nih_display_phy_power() callconv(.c) u32;
extern fn nih_display_phy_init(u32) callconv(.c) void;
extern fn nih_display_phy_status() callconv(.c) u32;
extern fn nih_display_phy_stop() callconv(.c) void;
extern fn nih_display_phy_power_off() callconv(.c) void;
extern fn nih_rom_cache_writeback(u32, u32, u32) callconv(.c) i32;

pub const Report = struct {
    initial_pins: u32 = 0,
    failed_pins: u32 = 0,
    recovery_pulses: u32 = 0,
    status: u32 = 0,
    stage: u32 = 0,
    error_code: u32 = 0,
    panel: u32 = 0,
    transactions: u32 = 0,
    frame_start: u32 = 0,
    frame_bytes: u32 = 0,
    reserve_bytes: u32 = 0,
    checksum: u32 = 0,
    phy_trim: u32 = 0,
    phy_status: u32 = 0,
    scanout: u32 = 0,
    backlight: u32 = 0,
};

pub const Pins = struct {
    clock: timer_group.Timer,
    pub fn release(_: Pins, pin: u32, high: bool) void {
        nih_display_pin_release(pin, high);
    }
    pub fn level(_: Pins, pin: u32) bool {
        return nih_display_pin_level(pin);
    }
    pub fn delay(self: Pins, microseconds: u32) bool {
        const start = self.clock.counter() orelse return false;
        for (0..10_000_000) |_| {
            const now = self.clock.counter() orelse return false;
            if (now - start >= microseconds) return true;
        }
        return false;
    }
};

pub fn run(clock: timer_group.Timer, selected: board.Layout) Report {
    var report = Report{ .status = 2, .frame_start = selected.frame_start, .frame_bytes = selected.frame_bytes, .reserve_bytes = board.reserve_bytes };
    clock.start();
    clock.disarm();
    defer clock.stop();
    const pins = Pins{ .clock = clock };
    nih_display_pads_init();
    // Let released open-drain inputs rise before the first idle-bus test.
    if (!pins.delay(100)) {
        report.error_code = 8;
        return report;
    }
    report.initial_pins = nih_display_i2c_status();
    var bus = i2c.Master(Pins){ .pins = pins };
    defer {
        nih_display_pin_release(i2c.sda, true);
        nih_display_pin_release(i2c.scl, true);
    }
    report.stage = 1;
    if (report.initial_pins & 3 != 3) {
        report.recovery_pulses = bus.clearBootBus() catch |err| {
            report.error_code = errorCode(err);
            report.failed_pins = nih_display_i2c_status();
            return report;
        };
    }
    board.prepareBoard(&bus) catch |err| {
        report.error_code = errorCode(err);
        report.failed_pins = nih_display_i2c_status();
        report.transactions = bus.transactions;
        return report;
    };
    report.stage = 2;
    if (!pins.delay(500_000)) {
        report.error_code = 8;
        return report;
    }
    const panel = board.identify(&bus) catch |err| {
        report.error_code = errorCode(err);
        report.transactions = bus.transactions;
        return report;
    };
    report.panel = @backingInt(panel);
    report.transactions = bus.transactions;
    report.stage = 3;
    // CPU-only image proof, kept separate from DMA/physical scanout evidence.
    const data: [*]u8 = @ptrFromInt(selected.frame_start);
    const frame = data[0..selected.frame_bytes];
    if (!boot.paintLandscapePlacedRgb565Le(".flash.rodata.boot_graphics", frame, 720, 1280, 1440, 255, .display)) {
        report.error_code = 9;
        return report;
    }
    var checksum: u32 = 0x811c9dc5;
    for (frame) |byte| checksum = (checksum ^ byte) *% 0x01000193;
    report.checksum = checksum;
    asm volatile ("fence rw, rw" ::: .{ .memory = true });
    if (nih_rom_cache_writeback((1 << 4) | (1 << 5), selected.frame_start, selected.frame_bytes) != 0) {
        report.error_code = 10;
        return report;
    }
    report.stage = 4;
    report.phy_trim = nih_display_phy_power();
    var phy_started = false;
    defer {
        if (phy_started) nih_display_phy_stop() else nih_display_phy_power_off();
    }
    if (!pins.delay(1000)) {
        report.error_code = 8;
        return report;
    }
    nih_display_phy_init(if (panel == .st7121) 960 else 1000);
    phy_started = true;
    report.stage = 5;
    const start = clock.counter() orelse {
        report.error_code = 8;
        return report;
    };
    for (0..100_000) |_| {
        report.phy_status = nih_display_phy_status();
        if (report.phy_status == 3) {
            // PREPARED only: command tables, bridge and DMA are separate gates.
            report.stage = 6;
            report.status = 1;
            return report;
        }
        const now = clock.counter() orelse {
            report.error_code = 8;
            return report;
        };
        if (now - start >= 50_000) break;
        if (!pins.delay(10)) {
            report.error_code = 8;
            return report;
        }
    }
    report.error_code = 11;
    return report;
}

fn errorCode(err: anyerror) u32 {
    return switch (err) {
        error.AddressNack => 1,
        error.Nack => 2,
        error.ClockTimeout => 3,
        error.BusBusy => 4,
        error.ArbitrationLost => 5,
        error.ExpanderIdentity => 6,
        error.UnsupportedPanel => 7,
        error.Timer => 8,
        error.Readback => 12,
        error.ReadAddressNack => 14,
        else => 13,
    };
}
