//! Boot-only read-only slot-0 experiment; owns timer 0 before CPU1 release.
const sd = @import("sdmmc");
const timer_group = @import("timer_group");
const options = @import("native_options");
const block = @import("block_reader");
const storage_io = @import("storage_io");
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
    return ownedRead(controller, lba, destination);
}
// Normal owner context, mapped Flash with caches enabled; IRQs never call it.
noinline fn ownedRead(controller: *sd.Controller(Bus), lba: u32, destination: *[512]u8) linksection(".flash.text.storage") i32 {
    const control = beginIo() orelse return -1;
    io_owner.read(controller, lba, destination, control.ticket, control) catch |err| {
        // Do not return into FS/client cleanup with a lease still retained.
        // This boot fixture has no recovery owner: stop the qualification.
        if (err == error.Quarantined) nih_native_task_failed();
        return -1;
    };
    return 0;
}
extern fn nih_sdmmc_power_off() callconv(.c) void;
extern fn nih_sdmmc_power_on() callconv(.c) void;
extern fn nih_sdmmc_clock_init() callconv(.c) void;
extern fn nih_sdmmc_fourbit_pins() callconv(.c) void;
extern fn nih_native_task_failed() callconv(.c) noreturn;
extern fn nih_rom_cache_writeback(u32, u32, u32) callconv(.c) i32;
extern fn nih_rom_cache_invalidate(u32, u32, u32) callconv(.c) i32;
extern fn nih_rom_putc(u8) callconv(.c) i32;
extern fn nih_broker_io_issued() callconv(.c) void;
var dma_data: [512]u8 align(64) = @splat(0);
var dma_descriptor: [16]u32 align(64) = @splat(0);
// Only the owner mutates the ledger. IRQ/other-hart code can publish a stop
// request for the exact active ticket through one resident 32-bit CAS.
var io_owner: storage_io.ReadOwner = .{};
var io_signal: storage_io.Signal = .{};
var qualification_stop: u32 = 0;
var qualification_ticket: u32 = 0;
fn beginIo() ?storage_io.Signal.Control {
    if (io_owner.busy()) return null;
    return io_signal.begin();
}
pub export fn nih_storage_io_active() linksection(".iram1.storage_hooks") callconv(.c) u32 {
    return io_signal.active();
}
pub export fn nih_storage_io_stop(ticket: u32, reason: u32) linksection(".iram1.storage_hooks") callconv(.c) u32 {
    return @intFromBool(io_signal.stop(ticket, reason));
}
pub export fn nih_storage_io_removed() linksection(".iram1.storage_hooks") callconv(.c) void {
    io_signal.remove();
}
pub const StageReport = struct { index: u32 = 0, bus_bits: u32 = 0, clock_khz: u32 = 0, scr_widths: u32 = 0, host_width: u32 = 0, divider: u32 = 0, reads: u32 = 0, crc0: u32 = 0, crc1: u32 = 0, crc_middle: u32 = 0, crc_last: u32 = 0, samples: u32 = 0, digest: u32 = 0 };
pub const Report = struct { code_pc: u32 = 0, status: u32 = 0, stage: u32 = 0, command: u32 = 0, interrupts: u32 = 0, response: u32 = 0, commands: u32 = 0, sectors_low: u32 = 0, sectors_high: u32 = 0, reads: u32 = 0, crc0: u32 = 0, crc1: u32 = 0, crc_middle: u32 = 0, crc_last: u32 = 0, bus_bits: u32 = 1, clock_khz: u32 = 400, writes: u32 = 0, error_code: u32 = 0, host_status: u32 = 0, data_words: u32 = 0, dma: u32 = 1, stage_count: u32 = 0, stages: [3]StageReport = @splat(.{}), storage: StorageReport = .{}, storage_stack: StorageStack = .{}, api: ApiReport = .{} };
var last_error: u32 = 0;
// SAFETY: run fully initializes the controller; runtimeBegin requires the
// ready flag set only after all SD boot checks succeed.
var runtime_controller: sd.Controller(Bus) = undefined;
var runtime_ready = false;
var runtime_initialized = false;
const Bus = struct {
    pub const runtime_section = if (options.storage) ".flash.text.storage" else ".text";
    clock: timer_group.Timer,
    pub fn read(_: Bus, offset: usize) u32 {
        return @as(*volatile u32, @ptrFromInt(sd.base + offset)).*;
    }
    pub fn write(_: Bus, offset: usize, value: u32) void {
        @as(*volatile u32, @ptrFromInt(sd.base + offset)).* = value;
        asm volatile ("fence iorw, iorw" ::: .{ .memory = true });
        // Qualification gate after the real CMD17 register write. DMA owns
        // resident staging; the broker keeps the eventual PSRAM destination.
        if (options.broker and offset == sd.regs.command and value & 63 == 17 and value & (1 << 31) != 0)
            if (qualification_stop != 0) {
                qualification_ticket = nih_storage_io_active();
                if (qualification_stop == 1) {
                    _ = nih_storage_io_stop(qualification_ticket, 1);
                } else nih_storage_io_removed();
            } else nih_broker_io_issued();
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
    // Called only after reset self-clear, disabled DMA and idle IDMAC FSM.
    // OWN may still be set after an abort. The CPU may reclaim it only here.
    pub fn releaseDma(_: Bus) bool {
        asm volatile ("fence iorw, iorw" ::: .{ .memory = true });
        if (nih_rom_cache_invalidate(1 << 4, @intFromPtr(&dma_data), 512) != 0 or
            nih_rom_cache_invalidate(1 << 4, @intFromPtr(&dma_descriptor), 64) != 0) return false;
        dma_descriptor = @splat(0);
        if (nih_rom_cache_writeback(1 << 4, @intFromPtr(&dma_descriptor), 64) != 0) return false;
        asm volatile ("fence iorw, iorw" ::: .{ .memory = true });
        return true;
    }
};

// Keep the temporary sector buffer out of the permanent bootstrap frame so
// its reservation is returned before SQLite uses the same stack.
// Boot only, after mapping preparation and before CPU1/tasks are released.
// Controller callbacks/DMA state remain resident for the later owner task.
pub noinline fn run(clock: timer_group.Timer, workspace: ?*[8192]u8) linksection(".flash.text.sdboot") Report {
    var report = Report{};
    report.code_pc = asm volatile ("auipc %[pc], 0"
        : [pc] "=r" (-> u32),
    );
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
    if (options.storage_service) {
        runtime_initialized = true;
        runtime_ready = true;
    }
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
    if (io_owner.busy()) return; // Quarantined staging still belongs to this owner.
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

/// CPU0 after the legacy storage owner has retired. The driver stops DMA,
/// invalidates staging/descriptor caches and copies before returning success.
pub export fn nih_broker_sd_read(destination: *[512]u8) callconv(.c) i32 {
    if (!options.broker or runtime_ready or active_controller != null) return -1;
    if (ownedRead(&runtime_controller, 0, destination) != 0) return -1;
    if (runtime_controller.words_read != 128 or runtime_controller.cleanup_failed or
        runtime_controller.io.read(sd.regs.ctrl) & ((1 << 25) | (1 << 5) | 4) != 0 or
        runtime_controller.io.read(sd.regs.dma_mode) != 0) return -1;
    return 0;
}

pub const LifetimeReport = struct {
    version: u32 = 1,
    status: u32 = 0,
    normal_reads: u32 = 0,
    cancelled: u32 = 0,
    removed: u32 = 0,
    stale_rejected: u32 = 0,
    idle_denied: u32 = 0,
    fences: u32 = 0,
    unpublished: u32 = 0,
    crc: u32 = 0,
    ctrl: u32 = 0,
    dma_mode: u32 = 0,
    dma_fsm: u32 = 0,
    irq_mask: u32 = 0,
    dma_mask: u32 = 0,
    descriptor: u32 = 0,
    descriptor_word: u32 = 0,
};
/// Opt-in broker qualification only, after both storage and broker retire.
/// Injects NOTIFICATIONS after CMD17 MMIO, not an electrical card removal.
pub noinline fn qualifyLifetimes(expected_crc: u32) linksection(".flash.text.storage") LifetimeReport {
    var report = LifetimeReport{};
    const clock = timer_group.Timer.fromGroup(0x500c3000, 0).?;
    if (!options.broker or runtime_ready or active_controller != null or io_owner.busy() or
        clock.channel.config & (timer_group.counter_enable | timer_group.alarm_enable) != 0) return report;
    clock.start();
    clock.disarm();
    defer clock.stop();
    defer qualification_stop = 0;
    var data: [512]u8 = @splat(0xa5);
    if (ownedRead(&runtime_controller, 0, &data) != 0 or sd.crc32(&data) != expected_crc) return report;
    report.normal_reads += 1;
    report.crc = sd.crc32(&data);
    for (1..3) |mode| {
        data = @splat(0xa5);
        qualification_stop = @intCast(mode);
        if (ownedRead(&runtime_controller, 0, &data) == 0 or qualification_ticket == 0 or
            !runtime_controller.faulted or io_owner.busy() or !runtime_controller.quiescence.complete() or
            nih_storage_io_active() != 0) return report;
        if (mode == 1) report.cancelled = 1 else report.removed = 1;
        for (data) |byte| {
            if (byte != 0xa5) return report;
        }
        report.unpublished += 1;
        report.fences += 1;
        if (nih_storage_io_stop(qualification_ticket, 1) != 0) return report;
        report.stale_rejected += 1;
        qualification_stop = 0;
        if (mode == 1) {
            // This is a NEW controller/card session, only after the old fence.
            // Preserve the monotonically increasing notification tickets.
            io_owner.generation += 1;
            runtime_controller = .{ .io = .{ .clock = clock } };
            nih_sdmmc_power_off();
            runtime_controller.io.delay(250_000);
            nih_sdmmc_power_on();
            runtime_controller.io.delay(10_000);
            nih_sdmmc_clock_init();
            runtime_controller.io.delay(20);
            runtime_controller.prepare() catch return report;
            runtime_controller.identify() catch return report;
            if (ownedRead(&runtime_controller, 0, &data) != 0 or sd.crc32(&data) != expected_crc) return report;
            report.normal_reads += 1;
            if (nih_storage_io_stop(qualification_ticket, 2) != 0) return report;
            report.stale_rejected += 1;
        }
    }
    const commands = runtime_controller.commands;
    if (ownedRead(&runtime_controller, 0, &data) == 0 or runtime_controller.commands != commands) return report;
    report.idle_denied = 1;
    report.ctrl = runtime_controller.io.read(sd.regs.ctrl) & ((1 << 25) | (1 << 5) | (1 << 4) | 4);
    report.dma_mode = runtime_controller.io.read(sd.regs.dma_mode);
    report.dma_fsm = runtime_controller.io.read(sd.regs.dma_status) >> 13 & 15;
    report.irq_mask = runtime_controller.io.read(sd.regs.mask);
    report.dma_mask = runtime_controller.io.read(sd.regs.dma_mask);
    report.descriptor = runtime_controller.io.read(sd.regs.descriptor);
    report.descriptor_word = @as(*volatile u32, &dma_descriptor[0]).*;
    if (report.ctrl | report.dma_mode | report.dma_fsm | report.irq_mask | report.dma_mask | report.descriptor | report.descriptor_word != 0) return report;
    report.status = 1;
    return report;
}

pub const RemovalReport = struct {
    version: u32 = 1,
    status: u32 = 0,
    before_reads: u32 = 0,
    failed_command: u32 = 0,
    failed_interrupts: u32 = 0,
    unpublished: u32 = 0,
    fenced: u32 = 0,
    idle_denied: u32 = 0,
    stale_rejected: u32 = 0,
    reinserted: u32 = 0,
    after_reads: u32 = 0,
    crc: u32 = 0,
    generation_before: u32 = 0,
    generation_after: u32 = 0,
    ctrl: u32 = 0,
    dma_mode: u32 = 0,
    dma_fsm: u32 = 0,
    irq_mask: u32 = 0,
    dma_mask: u32 = 0,
    descriptor: u32 = 0,
    descriptor_word: u32 = 0,
};
fn operatorMarker(text: []const u8) linksection(".flash.text.storage") void {
    for (text) |byte| _ = nih_rom_putc(byte);
}

/// The ordinary owner may create a new session only after old DMA quiescence.
/// Keep tickets monotonic when clearing the old session's removal latch.
fn freshCardSession(clock: timer_group.Timer) linksection(".flash.text.storage") bool {
    if (!io_owner.canRestart(io_signal.active() != 0, runtime_ready or active_controller != null, runtime_controller.quiescence.complete())) return false;
    const next_ticket = io_signal.next_ticket;
    runtime_controller = .{ .io = .{ .clock = clock } };
    nih_sdmmc_power_off();
    runtime_controller.io.delay(250_000);
    nih_sdmmc_power_on();
    runtime_controller.io.delay(10_000);
    nih_sdmmc_clock_init();
    runtime_controller.io.delay(20);
    runtime_controller.prepare() catch return false;
    runtime_controller.identify() catch return false;
    io_owner.generation += 1;
    io_signal = .{ .next_ticket = next_ticket };
    return true;
}

/// Starts a separate read-only card session for a future FatFs owner. The
/// returned sector count belongs to this session only; zero means no session
/// was published. The caller must serialize probe/bind/mount and end with the
/// same controller generation before another owner may start.
fn beginFatFsSession(generation: *u32) linksection(".flash.text.storage") callconv(.c) u32 {
    if (!options.fatfs_native or !options.storage_service or !runtime_initialized) return 0;
    const clock = timer_group.Timer.fromGroup(0x500c3000, 0).?;
    if (clock.channel.config & (timer_group.counter_enable | timer_group.alarm_enable) != 0 or
        !io_owner.canRestart(io_signal.active() != 0, runtime_ready or active_controller != null, runtime_controller.quiescence.complete())) return 0;
    clock.start();
    clock.disarm();
    if (!freshCardSession(clock)) {
        // A failed reset/identify has not established a safe fresh controller.
        // Keep later starts blocked until an explicit recovery path proves it.
        runtime_controller.quiescence.device_idle = false;
        clock.stop();
        return 0;
    }
    if (runtime_controller.sectors == 0 or runtime_controller.sectors > 0xffff_ffff) {
        clock.stop();
        return 0;
    }
    runtime_ready = true;
    const sectors = runtimeBegin(clock) orelse return 0;
    generation.* = @intCast(io_owner.generation);
    return sectors;
}

/// Called only after the private filesystem and its disk binding are gone.
/// A busy or unfenced controller keeps its session and clock for recovery.
fn endFatFsSession(generation: u32) linksection(".flash.text.storage") callconv(.c) u32 {
    if (!options.fatfs_native or !runtime_ready or active_controller != &runtime_controller or
        generation == 0 or generation != io_owner.generation or io_owner.busy() or
        io_signal.active() != 0 or !runtime_controller.quiescence.complete()) return 0;
    runtimeEnd();
    timer_group.Timer.fromGroup(0x500c3000, 0).?.stop();
    return 1;
}
comptime {
    if (options.fatfs_native) {
        @export(&beginFatFsSession, .{ .name = "nih_storage_fatfs_session_begin" });
        @export(&endFatFsSession, .{ .name = "nih_storage_fatfs_session_end" });
    }
}

/// Operator-assisted READ-ONLY test. A read error alone is not proof of
/// electrical removal; retain the operator's action record alongside this log.
pub noinline fn qualifyRemoval(expected_crc: u32) linksection(".flash.text.storage") RemovalReport {
    var report = RemovalReport{};
    const clock = timer_group.Timer.fromGroup(0x500c3000, 0).?;
    if (!options.sd_removal or runtime_ready or active_controller != null or
        clock.channel.config & (timer_group.counter_enable | timer_group.alarm_enable) != 0) return report;
    clock.start();
    clock.disarm();
    defer clock.stop();
    if (!freshCardSession(clock)) return report;
    report.generation_before = @intCast(io_owner.generation);
    const sectors = runtime_controller.sectors;
    var data: [512]u8 = @splat(0xa5);
    if (ownedRead(&runtime_controller, 0, &data) != 0 or sd.crc32(&data) != expected_crc) return report;
    report.before_reads = 1;
    operatorMarker("NIHOS_SD_REMOVE_READY\n");
    const began = clock.counter() orelse return report;
    while (true) {
        const now = clock.counter() orelse return report;
        if (now - began >= 120_000_000) return report;
        data = @splat(0xa5);
        if (ownedRead(&runtime_controller, 0, &data) != 0) break;
        if (sd.crc32(&data) != expected_crc) return report;
        report.before_reads += 1;
        // Keep read duty high at the fresh session's 1-bit/400 kHz transport.
        // This improves coverage but still cannot timestamp physical contact
        // loss relative to an individual DMA beat without card-detect input.
        runtime_controller.io.delay(500);
    }
    report.failed_command = runtime_controller.last_command;
    report.failed_interrupts = runtime_controller.last_interrupts;
    if (!runtime_controller.faulted or runtime_controller.cleanup_failed or
        !runtime_controller.quiescence.complete() or io_owner.busy() or io_signal.active() != 0) return report;
    for (data) |byte| {
        if (byte != 0xa5) return report;
    }
    report.unpublished = 1;
    report.fenced = 1;
    const old_ticket = io_signal.next_ticket - 1;
    const commands = runtime_controller.commands;
    nih_storage_io_removed();
    if (ownedRead(&runtime_controller, 0, &data) == 0 or runtime_controller.commands != commands) return report;
    report.idle_denied = 1;
    if (nih_storage_io_stop(old_ticket, 1) != 0) return report;
    report.stale_rejected = 1;
    // Capture the failed session's stop state before creating a new session.
    report.ctrl = runtime_controller.io.read(sd.regs.ctrl) & ((1 << 25) | (1 << 5) | (1 << 4) | 4);
    report.dma_mode = runtime_controller.io.read(sd.regs.dma_mode);
    report.dma_fsm = runtime_controller.io.read(sd.regs.dma_status) >> 13 & 15;
    report.irq_mask = runtime_controller.io.read(sd.regs.mask);
    report.dma_mask = runtime_controller.io.read(sd.regs.dma_mask);
    report.descriptor = runtime_controller.io.read(sd.regs.descriptor);
    report.descriptor_word = @as(*volatile u32, &dma_descriptor[0]).*;
    if (report.ctrl | report.dma_mode | report.dma_fsm | report.irq_mask | report.dma_mask | report.descriptor | report.descriptor_word != 0) return report;
    operatorMarker("NIHOS_SD_INSERT_READY\n");
    const waiting = clock.counter() orelse return report;
    while (!freshCardSession(clock)) {
        const now = clock.counter() orelse return report;
        if (now - waiting >= 120_000_000) return report;
        runtime_controller.io.delay(500_000);
    }
    if (runtime_controller.sectors != sectors) return report;
    report.reinserted = 1;
    report.generation_after = @intCast(io_owner.generation);
    for (0..2) |_| {
        if (ownedRead(&runtime_controller, 0, &data) != 0 or sd.crc32(&data) != expected_crc) return report;
        report.after_reads += 1;
    }
    report.crc = sd.crc32(&data);
    if (nih_storage_io_stop(old_ticket, 2) != 0) return report;
    report.stale_rejected += 1;
    report.status = 1;
    return report;
}
