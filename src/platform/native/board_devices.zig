//! CPU0 board I2C owner after display/power setup. One bounded transaction job
//! per second, with interrupts enabled. No bus resets or recovery at runtime.
const display = @import("display_service");
const i2c = @import("boot_i2c");
const rtc = @import("tab5_rtc");
const timers = @import("timer_group");
const Bus = i2c.Master(display.probe.Pins);
// SAFETY: begin binds the bus before active allows poll or setCalendar.
var bus: Bus = undefined;
// SAFETY: begin binds the free-running timer before active is set.
var clock: timers.Timer = undefined;
var next: u64 = 0;
var job: u2 = 0;
var active = false;
pub const Report = extern struct {
    rtc_present: u32 = 0,
    rtc_valid: u32 = 0,
    rtc_flags: u32 = 0,
    rtc_control: u32 = 0,
    rtc_error: u32 = 0,
    rtc_raw_date: u32 = 0,
    rtc_raw_time: u32 = 0,
    year: u32 = 0,
    month: u32 = 0,
    day: u32 = 0,
    hour: u32 = 0,
    minute: u32 = 0,
    second: u32 = 0,
    ina_present: u32 = 0,
    bus_uv: u32 = 0,
    shunt_uv_x10: u32 = 0,
    shunt_negative: u32 = 0,
    imu_chip: u32 = 0,
    imu_initialized: u32 = 0,
    errors: u32 = 0,
    samples: u32 = 0,
};
var report: Report = .{};
pub fn begin(timer: timers.Timer) void {
    clock = timer;
    bus = .{ .pins = .{ .clock = timer } };
    report = .{};
    job = 0;
    next = 0;
    active = true;
}
fn word(register: u8) !u16 {
    var bytes: [2]u8 = undefined;
    try bus.transfer(0x41, &.{register}, &bytes);
    return (@as(u16, bytes[0]) << 8) | bytes[1];
}
fn step() !void {
    switch (job) {
        0 => {
            report.rtc_present = 0;
            report.rtc_valid = 0;
            const sample = try rtc.read(&bus);
            report.rtc_present = 1;
            report.rtc_flags = sample.registers[13];
            report.rtc_control = sample.registers[14];
            const raw = sample.registers;
            report.rtc_raw_time = (@as(u32, raw[2]) << 16) | (@as(u32, raw[1]) << 8) | raw[0];
            report.rtc_raw_date = (@as(u32, raw[6]) << 24) | (@as(u32, raw[5]) << 16) | (@as(u32, raw[4]) << 8) | raw[3];
            report.rtc_error = 0;
            const value = sample.calendar() catch |err| {
                report.rtc_error = switch (err) {
                    error.VoltageLow => 1,
                    error.Stopped => 2,
                    else => 3,
                };
                return;
            };
            report.rtc_valid = 1;
            report.year = value.year;
            report.month = value.month;
            report.day = value.day;
            report.hour = value.hour;
            report.minute = value.minute;
            report.second = value.second;
        },
        1 => {
            report.ina_present = 0;
            if (try word(0xfe) != 0x5449 or (try word(0xff)) & 0xfff0 != 0x2260) return error.WrongDevice;
            const voltage = try word(2);
            const shunt: i16 = @bitCast(try word(1));
            report.bus_uv = @as(u32, voltage) * 1250;
            report.shunt_uv_x10 = @as(u32, @abs(@as(i32, shunt))) * 25;
            report.shunt_negative = @intFromBool(shunt < 0);
            report.ina_present = 1;
        },
        2 => {
            report.imu_chip = 0;
            report.imu_initialized = 0;
            var value: [1]u8 = undefined;
            try bus.transfer(0x68, &.{0}, &value);
            report.imu_chip = value[0];
            if (value[0] != 0x24) return error.WrongDevice;
            try bus.transfer(0x68, &.{0x21}, &value);
            report.imu_initialized = @intFromBool(value[0] & 15 == 1);
        },
        else => unreachable,
    }
}
pub fn poll() void {
    if (!active) return;
    const now = clock.counter() orelse return;
    if (now < next) return;
    next = now + 1_000_000;
    step() catch {
        report.errors +|= 1;
    };
    report.samples +|= 1;
    job = if (job == 2) 0 else job + 1;
}
pub fn snapshot() Report {
    return report;
}

/// For a future settings/time service, never called implicitly during boot.
pub fn setCalendar(value: rtc.DateTime) !void {
    if (!active) return error.NotStarted;
    report.rtc_valid = 0;
    try rtc.set(&bus, value);
    job = 0;
    next = 0;
}
