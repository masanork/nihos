//! CPU0 board I2C owner after display/power setup. One bounded transaction job
//! per second, plus incremental IMU initialization/acquisition, with interrupts
//! enabled. No bus resets or recovery at runtime.
const display = @import("display_service");
const i2c = @import("boot_i2c");
const rtc = @import("tab5_rtc");
const bmi270 = @import("tab5_bmi270");
const options = @import("native_options");
pub const rs485 = @import("rs485_probe.zig");
pub const microphone = @import("microphone_probe.zig");
pub const audio = @import("audio_probe.zig");
const timers = @import("timer_group");
const Bus = i2c.Master(display.probe.Pins);
// SAFETY: begin binds the bus before active allows poll or setCalendar.
var bus: Bus = undefined;
// SAFETY: begin binds the free-running timer before active is set.
var clock: timers.Timer = undefined;
var next: u64 = 0;
var job: u1 = 0;
var imu: bmi270.Driver = .{};
var active = false;
var audio_requested = false;
var microphone_requested = false;
var rs485_requested = false;
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
    imu = .{};
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
    }
}
pub fn poll() void {
    if (!active) return;
    const now = clock.counter() orelse {
        if ((options.audio or options.devices) and audio_requested) audio.poll(&bus, clock);
        if ((options.microphone or options.devices) and microphone_requested) microphone.poll(&bus, clock);
        if ((options.rs485 or options.devices) and rs485_requested) rs485.poll(clock);
        return;
    };
    if ((options.audio and now >= 10_000_000) or (options.devices and audio_requested)) {
        if (!audio_requested) {
            audio_requested = true;
            _ = audio.request();
        }
        audio.poll(&bus, clock);
    }
    if ((options.microphone and now >= 10_000_000) or (options.devices and microphone_requested)) {
        if (!microphone_requested) {
            microphone_requested = true;
            _ = microphone.request();
        }
        microphone.poll(&bus, clock);
    }
    if ((options.rs485 and now >= 10_000_000) or (options.devices and rs485_requested)) {
        if (!rs485_requested) {
            rs485_requested = true;
            _ = rs485.request();
        }
        rs485.poll(clock);
    }
    if (now < next) {
        imu.poll(&bus, clock);
        return;
    }
    next = now + 1_000_000;
    step() catch {
        report.errors +|= 1;
    };
    report.samples +|= 1;
    job +%= 1;
}
pub fn snapshot() Report {
    report.imu_chip = imu.chip;
    report.imu_initialized = @intFromBool(imu.initialized);
    return report;
}
pub const ImuReport = extern struct {
    chip: u32,
    initialized: u32,
    stage: u32,
    fault: u32,
    uploaded: u32,
    valid: u32,
    samples: u32,
    acc_x: u32,
    acc_y: u32,
    acc_z: u32,
    gyr_x: u32,
    gyr_y: u32,
    gyr_z: u32,
    sensor_error: u32,
    ready_status: u32,
};
pub fn imuSnapshot() ImuReport {
    return .{
        .chip = imu.chip,
        .initialized = @intFromBool(imu.initialized),
        .stage = @backingInt(imu.state),
        .fault = @backingInt(imu.fault),
        .uploaded = imu.uploaded,
        .valid = @intFromBool(imu.valid),
        .samples = imu.samples,
        .acc_x = @bitCast(@as(i32, imu.sample.acceleration[0])),
        .acc_y = @bitCast(@as(i32, imu.sample.acceleration[1])),
        .acc_z = @bitCast(@as(i32, imu.sample.acceleration[2])),
        .gyr_x = @bitCast(@as(i32, imu.sample.gyroscope[0])),
        .gyr_y = @bitCast(@as(i32, imu.sample.gyroscope[1])),
        .gyr_z = @bitCast(@as(i32, imu.sample.gyroscope[2])),
        .sensor_error = imu.error_register,
        .ready_status = imu.ready_status,
    };
}

/// For a future settings/time service, never called implicitly during boot.
pub fn setCalendar(value: rtc.DateTime) !void {
    if (!active) return error.NotStarted;
    report.rtc_valid = 0;
    try rtc.set(&bus, value);
    job = 0;
    next = 0;
}

/// CPU0 foreground only. Explicit requests never run from an interrupt.
pub fn requestDevice(kind: u32) bool {
    if (!options.devices or !active) return false;
    return switch (kind) {
        1 => blk: {
            const accepted = audio.request();
            audio_requested = audio_requested or accepted;
            break :blk accepted;
        },
        2 => blk: {
            const accepted = microphone.request();
            microphone_requested = microphone_requested or accepted;
            break :blk accepted;
        },
        3, 4 => blk: {
            const accepted = rs485.requestFixture(if (kind == 3) 1 else 2);
            rs485_requested = rs485_requested or accepted;
            break :blk accepted;
        },
        5 => true,
        else => false,
    };
}

pub fn requestedMask() u32 {
    return @as(u32, @intFromBool(audio_requested)) | (@as(u32, @intFromBool(microphone_requested)) << 1) | (@as(u32, @intFromBool(rs485_requested)) << 2);
}
pub const ServiceReport = extern struct { available: u32, requested: u32, i2s_owner: u32, pinned: u32, workspace: u32 };
pub fn serviceSnapshot() ServiceReport {
    const workspace = @import("device_workspace.zig");
    return .{ .available = if (options.devices) 7 else 0, .requested = requestedMask(), .i2s_owner = @backingInt(workspace.gate.owner), .pinned = @intFromBool(workspace.gate.pinned), .workspace = workspace.bytesReserved() };
}
