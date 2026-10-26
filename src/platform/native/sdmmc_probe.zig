//! Boot-only read-only slot-0 experiment; owns timer 0 before CPU1 release.
const sd = @import("sdmmc");
const timer_group = @import("timer_group");
const options = @import("native_options");
const block = @import("block_reader");
pub const StorageReport = extern struct {
    status: u32 = 0,
    error_code: u32 = 0,
    passes: u32 = 0,
    block_size: u32 = 0,
    block_count: u32 = 0,
    entries: u32 = 0,
    files: u32 = 0,
    directories: u32 = 0,
    directory_digest: u32 = 0,
    file_bytes: u32 = 0,
    file_crc: u32 = 0,
    file_name_digest: u32 = 0,
    reads: u32 = 0,
    denied_writes: u32 = 0,
};
pub const ApiReport = extern struct { status: u32 = 0, opens: u32 = 0, closes: u32 = 0, cancelled: u32 = 0, rejected: u32 = 0, read_calls: u32 = 0, workspace_bytes: u32 = 0, used_bytes: u32 = 0, cleared: u32 = 0 };
extern fn nih_storage_probe(*[8192]u8, u32, u32, *StorageReport, *ApiReport) callconv(.c) void;
extern fn nih_sqlite_stack_paint(u32) callconv(.c) u32;
extern var __stack0_bottom: u8;
extern var __stack0_top: u8;
pub const StorageStack = struct { low: u32 = 0, high: u32 = 0, painted_to: u32 = 0, used: u32 = 0, confirmed: u32 = 0 };
noinline fn runStorage(workspace: *[8192]u8, sectors: u32, report: *StorageReport, api: *ApiReport, stack: *StorageStack) void {
    stack.low = @intFromPtr(&__stack0_bottom) + 16;
    stack.high = @intFromPtr(&__stack0_top);
    stack.painted_to = nih_sqlite_stack_paint(stack.low);
    if (stack.painted_to <= stack.low or stack.painted_to >= stack.high) return;
    nih_storage_probe(workspace, 8192, sectors, report, api);
    var first = stack.low;
    while (first < stack.painted_to) : (first += 4) {
        if (@as(*const volatile u32, @ptrFromInt(first)).* != 0x5a7ec319) break;
    }
    stack.used = stack.high - first;
    if (first > stack.low + 160) stack.confirmed = 1;
}
var active_controller: ?*sd.Controller(Bus) = null;
pub export fn nih_storage_read(lba: u32, destination: *block.Sector) callconv(.c) i32 {
    if (!options.storage) return -1;
    const controller = active_controller orelse return -1;
    const device = block.Reader(sd.Controller(Bus)).init(controller, controller.sectors) catch return -1;
    device.read(lba, destination) catch return -1;
    return 0;
}
extern fn nih_sdmmc_power_off() callconv(.c) void;
extern fn nih_sdmmc_power_on() callconv(.c) void;
extern fn nih_sdmmc_clock_init() callconv(.c) void;
extern fn nih_sdmmc_fourbit_pins() callconv(.c) void;
extern fn nih_native_task_failed() callconv(.c) noreturn;
extern fn nih_rom_cache_writeback(u32, u32, u32) callconv(.c) i32;
extern fn nih_rom_cache_invalidate(u32, u32, u32) callconv(.c) i32;
var dma_data: [512]u8 align(64) = @splat(0);
var dma_descriptor: [16]u32 align(64) = @splat(0);
pub const StageReport = struct { index: u32 = 0, bus_bits: u32 = 0, clock_khz: u32 = 0, scr_widths: u32 = 0, host_width: u32 = 0, divider: u32 = 0, reads: u32 = 0, crc0: u32 = 0, crc1: u32 = 0, crc_middle: u32 = 0, crc_last: u32 = 0, samples: u32 = 0, digest: u32 = 0 };
pub const Report = struct { status: u32 = 0, stage: u32 = 0, command: u32 = 0, interrupts: u32 = 0, response: u32 = 0, commands: u32 = 0, sectors_low: u32 = 0, sectors_high: u32 = 0, reads: u32 = 0, crc0: u32 = 0, crc1: u32 = 0, crc_middle: u32 = 0, crc_last: u32 = 0, bus_bits: u32 = 1, clock_khz: u32 = 400, writes: u32 = 0, error_code: u32 = 0, host_status: u32 = 0, data_words: u32 = 0, dma: u32 = 1, stage_count: u32 = 0, stages: [3]StageReport = @splat(.{}), storage: StorageReport = .{}, storage_stack: StorageStack = .{}, api: ApiReport = .{} };
var last_error: u32 = 0;
// SAFETY: run fully initializes the controller; runtimeBegin requires the
// ready flag set only after all SD boot checks succeed.
var runtime_controller: sd.Controller(Bus) = undefined;
var runtime_ready = false;
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
    pub fn fourBitPins(_: Bus) void {
        nih_sdmmc_fourbit_pins();
    }
    pub fn prepareDma(_: Bus, length: u32) ?u32 {
        if (length != 8 and length != 512) return null;
        dma_descriptor = @splat(0);
        dma_descriptor[0] = (1 << 31) | (1 << 4) | (1 << 3) | (1 << 2);
        dma_descriptor[1] = length;
        dma_descriptor[2] = @intFromPtr(&dma_data);
        if (nih_rom_cache_writeback(1 << 4, @intFromPtr(&dma_data), 512) != 0 or
            nih_rom_cache_invalidate(1 << 4, @intFromPtr(&dma_data), 512) != 0 or
            nih_rom_cache_writeback(1 << 4, @intFromPtr(&dma_descriptor), 64) != 0) return null;
        asm volatile ("fence iorw, iorw" ::: .{ .memory = true });
        return @intFromPtr(&dma_descriptor);
    }
    pub fn finishDma(_: Bus, destination: *[512]u8, length: u32) bool {
        if (length != 8 and length != 512) return false;
        asm volatile ("fence iorw, iorw" ::: .{ .memory = true });
        if (nih_rom_cache_invalidate(1 << 4, @intFromPtr(&dma_data), 512) != 0 or
            nih_rom_cache_invalidate(1 << 4, @intFromPtr(&dma_descriptor), 64) != 0) return false;
        if (@as(*volatile u32, &dma_descriptor[0]).* & ((1 << 31) | (1 << 30)) != 0) return false;
        for (destination[0..length], 0..) |*byte, index| byte.* = @as(*volatile u8, &dma_data[index]).*;
        return true;
    }
};

// Keep the temporary sector buffer out of the permanent bootstrap frame so
// its reservation is returned before SQLite uses the same stack.
pub noinline fn run(clock: timer_group.Timer, workspace: ?*[8192]u8) Report {
    var report = Report{};
    clock.start();
    clock.disarm();
    defer clock.stop();
    var local_controller = sd.Controller(Bus){ .io = .{ .clock = clock } };
    const controller = if (options.storage_service) &runtime_controller else &local_controller;
    controller.* = .{ .io = .{ .clock = clock } };
    nih_sdmmc_power_off();
    controller.io.delay(250_000);
    nih_sdmmc_power_on();
    controller.io.delay(10_000);
    nih_sdmmc_clock_init();
    controller.io.delay(20);
    report.stage = 1;
    controller.prepare() catch return failure(report, controller);
    report.stage = 2;
    controller.identify() catch return failure(report, controller);
    report.sectors_low = @truncate(controller.sectors);
    report.sectors_high = @intCast(controller.sectors >> 32);
    const lbas = [_]u32{ 0, 1, @intCast(controller.sectors / 2), @intCast(controller.sectors - 1) };
    var checks: [4]u32 = @splat(0);
    var buffer: [512]u8 = undefined;
    const sample_count: u32 = if (options.sdmmc_profile == 0) 0 else 1024;
    var baseline_digest: u32 = 0;
    for (0..options.sdmmc_profile + 1) |phase| {
        report.stage = 3 + @as(u32, @intCast(phase));
        if (phase == 1) controller.switchFourBit() catch |err| {
            last_error = errorCode(err);
            return failure(report, controller);
        };
        if (phase == 2) controller.switch20MHz() catch |err| {
            last_error = errorCode(err);
            return failure(report, controller);
        };
        for (0..2) |pass| {
            for (lbas, 0..) |lba, index| {
                controller.readSector(lba, &buffer) catch |err| {
                    last_error = errorCode(err);
                    return failure(report, controller);
                };
                const checksum = sd.crc32(&buffer);
                if (phase == 0 and pass == 0) checks[index] = checksum else if (checks[index] != checksum) return failure(report, controller);
                report.reads += 1;
            }
        }
        var digest: u32 = 0x811c9dc5;
        for (0..sample_count) |sample| {
            const lba = sd.sampleLba(@intCast(sample), sample_count, controller.sectors).?;
            controller.readSector(lba, &buffer) catch |err| {
                last_error = errorCode(err);
                return failure(report, controller);
            };
            digest = sd.foldSample(digest, lba, sd.crc32(&buffer));
            report.reads += 1;
        }
        if (phase == 0) baseline_digest = digest else if (digest != baseline_digest) return failure(report, controller);
        report.stages[phase] = .{ .index = @intCast(phase), .bus_bits = controller.bus_bits, .clock_khz = controller.clock_khz, .scr_widths = controller.scr_widths, .host_width = controller.host_width, .divider = controller.divider, .reads = 8 + sample_count, .crc0 = checks[0], .crc1 = checks[1], .crc_middle = checks[2], .crc_last = checks[3], .samples = sample_count, .digest = digest };
        report.stage_count += 1;
    }
    if (options.storage) {
        // The opt-in raw littlefs fixture only accepts a full-card
        // volume smaller than 2 TiB; the generic block reader supports 2 TiB.
        if (controller.sectors > 0xffff_ffff) return failure(report, controller);
        active_controller = controller;
        runStorage(workspace orelse return failure(report, controller), @intCast(controller.sectors), &report.storage, &report.api, &report.storage_stack);
        active_controller = null;
    }
    report.crc0 = checks[0];
    report.crc1 = checks[1];
    report.crc_middle = checks[2];
    report.crc_last = checks[3];
    if (options.storage_service) runtime_ready = true;
    report.status = 1;
    report.bus_bits = controller.bus_bits;
    report.clock_khz = controller.clock_khz;
    report.stage = 4;
    report.commands = controller.commands;
    report.error_code = last_error;
    report.host_status = controller.last_status;
    report.data_words = controller.words_read;
    return report;
}

fn errorCode(err: sd.Error) u32 {
    return switch (err) {
        error.Timeout => 1,
        error.Controller => 2,
        error.Response => 3,
        error.Unsupported => 4,
        error.InvalidAddress => 5,
        error.ShortRead => 6,
        else => 7,
    };
}

fn failure(previous: Report, controller: anytype) Report {
    var report = previous;
    report.status = 2;
    report.command = controller.last_command;
    report.interrupts = controller.last_interrupts;
    report.response = controller.last_response;
    report.commands = controller.commands;
    report.bus_bits = controller.bus_bits;
    report.clock_khz = controller.clock_khz;
    report.error_code = last_error;
    report.host_status = controller.last_status;
    report.data_words = controller.words_read;
    return report;
}

pub fn runtimeBegin(clock: timer_group.Timer) ?u32 {
    if (!options.storage_service or !runtime_ready or runtime_controller.faulted or runtime_controller.sectors > 0xffff_ffff) return null;
    runtime_controller.io.clock = clock;
    active_controller = &runtime_controller;
    return @intCast(runtime_controller.sectors);
}
pub fn runtimeEnd() void {
    runtime_ready = false;
    active_controller = null;
}

pub export fn nih_storage_controller_begin() callconv(.c) u32 {
    if (!options.storage_service) return 0;
    return runtimeBegin(timer_group.Timer.fromGroup(0x500c3000, 0).?) orelse 0;
}
pub export fn nih_storage_controller_end() callconv(.c) void {
    runtimeEnd();
}
