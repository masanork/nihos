//! Boot-only read-only slot-0 experiment; owns timer 0 before CPU1 release.
const sd = @import("sdmmc");
const timer_group = @import("timer_group");
extern fn nih_sdmmc_power_off() callconv(.c) void;
extern fn nih_sdmmc_power_on() callconv(.c) void;
extern fn nih_sdmmc_clock_init() callconv(.c) void;
extern fn nih_native_task_failed() callconv(.c) noreturn;
extern fn nih_rom_cache_writeback(u32, u32, u32) callconv(.c) i32;
extern fn nih_rom_cache_invalidate(u32, u32, u32) callconv(.c) i32;
var dma_data: [512]u8 align(64) = @splat(0);
var dma_descriptor: [16]u32 align(64) = @splat(0);
pub const Report = struct { status: u32 = 0, stage: u32 = 0, command: u32 = 0, interrupts: u32 = 0, response: u32 = 0, commands: u32 = 0, sectors_low: u32 = 0, sectors_high: u32 = 0, reads: u32 = 0, crc0: u32 = 0, crc1: u32 = 0, crc_middle: u32 = 0, crc_last: u32 = 0, bus_bits: u32 = 1, clock_khz: u32 = 400, writes: u32 = 0, error_code: u32 = 0, host_status: u32 = 0, data_words: u32 = 0, dma: u32 = 1 };
var last_error: u32 = 0;
const Bus = struct {
    clock: timer_group.Timer,
    pub fn read(_: Bus, offset: usize) u32 {
        return @as(*volatile u32, @ptrFromInt(sd.base + offset)).*;
    }
    pub fn write(_: Bus, offset: usize, value: u32) void {
        @as(*volatile u32, @ptrFromInt(sd.base + offset)).* = value;
        asm volatile ("fence iorw, iorw" ::: .{ .memory = true });
    }
    pub fn delay(self: Bus, microseconds: u32) void {
        const started = self.clock.counter() orelse nih_native_task_failed();
        for (0..100_000_000) |_| {
            const now = self.clock.counter() orelse nih_native_task_failed();
            if (now - started >= microseconds) return;
        }
        nih_native_task_failed();
    }
    pub fn prepareDma(_: Bus) ?u32 {
        dma_descriptor = @splat(0);
        dma_descriptor[0] = (1 << 31) | (1 << 4) | (1 << 3) | (1 << 2);
        dma_descriptor[1] = 512;
        dma_descriptor[2] = @intFromPtr(&dma_data);
        if (nih_rom_cache_writeback(1 << 4, @intFromPtr(&dma_data), 512) != 0 or
            nih_rom_cache_invalidate(1 << 4, @intFromPtr(&dma_data), 512) != 0 or
            nih_rom_cache_writeback(1 << 4, @intFromPtr(&dma_descriptor), 64) != 0) return null;
        asm volatile ("fence iorw, iorw" ::: .{ .memory = true });
        return @intFromPtr(&dma_descriptor);
    }
    pub fn finishDma(_: Bus, destination: *[512]u8) bool {
        asm volatile ("fence iorw, iorw" ::: .{ .memory = true });
        if (nih_rom_cache_invalidate(1 << 4, @intFromPtr(&dma_data), 512) != 0 or
            nih_rom_cache_invalidate(1 << 4, @intFromPtr(&dma_descriptor), 64) != 0) return false;
        if (@as(*volatile u32, &dma_descriptor[0]).* & ((1 << 31) | (1 << 30)) != 0) return false;
        for (destination, 0..) |*byte, index| byte.* = @as(*volatile u8, &dma_data[index]).*;
        return true;
    }
};

// Keep the temporary sector buffer out of the permanent bootstrap frame so
// its reservation is returned before SQLite uses the same stack.
pub noinline fn run(clock: timer_group.Timer) Report {
    var report = Report{};
    clock.start();
    clock.disarm();
    defer clock.stop();
    var controller = sd.Controller(Bus){ .io = .{ .clock = clock } };
    nih_sdmmc_power_off();
    controller.io.delay(250_000);
    nih_sdmmc_power_on();
    controller.io.delay(10_000);
    nih_sdmmc_clock_init();
    controller.io.delay(20);
    report.stage = 1;
    controller.prepare() catch return failure(report, &controller);
    report.stage = 2;
    controller.identify() catch return failure(report, &controller);
    report.sectors_low = @truncate(controller.sectors);
    report.sectors_high = @intCast(controller.sectors >> 32);
    const lbas = [_]u32{ 0, 1, @intCast(controller.sectors / 2), @intCast(controller.sectors - 1) };
    var checks: [4]u32 = @splat(0);
    var buffer: [512]u8 = undefined;
    report.stage = 3;
    for (0..2) |pass| {
        for (lbas, 0..) |lba, index| {
            controller.readSector(lba, &buffer) catch |err| {
                last_error = switch (err) {
                    error.Timeout => 1,
                    error.Controller => 2,
                    error.Response => 3,
                    error.Unsupported => 4,
                    error.InvalidAddress => 5,
                    error.ShortRead => 6,
                    else => 7,
                };
                return failure(report, &controller);
            };
            const checksum = sd.crc32(&buffer);
            if (pass == 0) checks[index] = checksum else if (checks[index] != checksum) return failure(report, &controller);
            report.reads += 1;
        }
    }
    report.crc0 = checks[0];
    report.crc1 = checks[1];
    report.crc_middle = checks[2];
    report.crc_last = checks[3];
    report.status = 1;
    report.stage = 4;
    report.commands = controller.commands;
    report.error_code = last_error;
    report.host_status = controller.last_status;
    report.data_words = controller.words_read;
    return report;
}

fn failure(previous: Report, controller: anytype) Report {
    var report = previous;
    report.status = 2;
    report.command = controller.last_command;
    report.interrupts = controller.last_interrupts;
    report.response = controller.last_response;
    report.commands = controller.commands;
    report.error_code = last_error;
    report.host_status = controller.last_status;
    report.data_words = controller.words_read;
    return report;
}
