//! Independent native boot experiment: no IDF application or FreeRTOS link.
const std = @import("std");
const options = @import("native_options");
const storage_runtime = if (options.storage_service) @import("storage_service_abi.zig") else struct {};
const normal_storage = @hasDecl(options, "normal_storage") and options.normal_storage;
const normal_fs = @import("normal_fs_abi.zig");
const broker_runtime = if (options.broker) @import("broker_abi.zig") else struct {};
const timer_group = @import("timer_group");
const reset_capture = @import("reset_capture");
const tasks = @import("native_tasks");
const native_psram = @import("psram.zig");
const record_log = @import("record_log");
const text_console = @import("text_console");
const display_service = @import("display_service");
const card_boot = @import("card_boot.zig");
const ui = display_service.ui;
const cpu_boot = @import("cpu_boot");
const network = @import("network_service");
const network_config = @import("network_config");
const board_devices = @import("board_devices.zig");
const flash_records = @import("flash_records.zig");
pub const panic = std.debug.no_panic;
const pointer = @import("pointer_input");
export fn nih_touch_available() callconv(.c) bool {
    return options.devices and board_devices.touch.ready();
}
export fn nih_touch_pop(output: *pointer.Event) callconv(.c) bool {
    if (!options.devices) return false;
    const event = board_devices.touch.pop() orelse return false;
    output.* = event;
    return true;
}
export fn nih_device_request(kind: u32) callconv(.c) bool {
    if (!options.devices) return false;
    const accepted = board_devices.requestDevice(kind);
    const workspace = @import("device_workspace.zig");
    const words: extern struct { kind: u32, accepted: u32, i2s_owner: u32, pinned: u32, workspace: u32 } = .{ .kind = kind, .accepted = @intFromBool(accepted), .i2s_owner = @backingInt(workspace.gate.owner), .pinned = @intFromBool(workspace.gate.pinned), .workspace = workspace.bytesReserved() };
    logger.record("NIHOS_DEVICE_REQUEST", null, .{ "kind", "accepted", "i2s_owner", "pinned", "workspace" }, &words);
    return accepted;
}

fn storageClient() u32 {
    const handle = tasks.calls.current() orelse return 0;
    return (@as(u32, handle.generation) << 16) | handle.slot;
}
export fn nih_normal_c6_dma_release() callconv(.c) u32 {
    return if (options.network and normal_storage) network.releaseDmaForHost() else 1;
}
export fn nih_normal_fs_wake() callconv(.c) void {
    tasks.wakeNormalStorage();
}
export fn nih_fs_command(path: [*]const u8, length: u32) callconv(.c) void {
    if (!normal_storage or length > 512) return;
    const accepted = normal_fs.submit(storageClient(), path[0..length]);
    if (!accepted) printBoot("Storage request unavailable or busy.\n");
}
var last_storage_status: u32 = 0xffffffff;
fn serviceStorage() void {
    if (!normal_storage) return;
    const completed = normal_fs.poll(storageClient());
    const report = normal_fs.snapshot();
    const changed = last_storage_status != @backingInt(report.status);
    if (!completed and !changed) return;
    last_storage_status = @backingInt(report.status);
    const words: extern struct { status: u32, epoch: u32, kind: u32, requests: u32, completed: u32, bytes: u32, crc: u32, eof: u32, error_code: u32, reads: u32, yields: u32 } = .{
        .status = @backingInt(report.status),
        .epoch = report.generation,
        .kind = report.kind,
        .requests = report.requests,
        .completed = report.completed,
        .bytes = report.bytes,
        .crc = report.crc,
        .eof = report.eof,
        .error_code = @bitCast(report.error_code),
        .reads = report.io_reads,
        .yields = report.yields,
    };
    logger.record("NIHOS_NORMAL_FS", null, .{ "status", "epoch", "kind", "requests", "completed", "bytes", "crc", "eof", "error_code", "reads", "yields" }, &words);
    if (report.io_error != 0) {
        const io_words: extern struct { error_code: u32, command: u32, interrupts: u32, dma_status: u32 } = .{ .error_code = report.io_error, .command = report.command, .interrupts = report.interrupts, .dma_status = report.dma_status };
        logger.record("NIHOS_NORMAL_FS_IO", null, .{ "error_code", "command", "interrupts", "dma_status" }, &io_words);
    }
    if (changed) switch (report.status) {
        .mounted => printBoot("SD ready. :read path reads up to 4096 bytes; :storage refreshes.\n"),
        .no_card => printBoot("No SD card. Insert a card and enter :storage.\n"),
        .rejected => printBoot("SD unavailable. Enter :storage to retry.\n"),
        .no_memory => printBoot("Storage memory unavailable.\n"),
        .quarantined => printBoot("Storage stopped. Restart to recover.\n"),
        else => {},
    };
    if (completed and report.error_code == 0 and report.bytes != 0) {
        var preview: [128]u8 = undefined;
        const count = normal_fs.result(0, &preview);
        // An arbitrary file must not inject terminal commands into the journal.
        for (preview[0..count]) |*byte| if ((byte.* < 32 and byte.* != 10 and byte.* != 9) or byte.* >= 127) {
            byte.* = '.';
        };
        print(preview[0..count]);
        printBoot("\n");
        if (report.bytes > count or report.eof == 0) printBoot("[preview truncated]\n");
    }
}

comptime {
    if (@sizeOf(tasks.context.IntegerContext) != tasks.memory.stacks.layout.frame_bytes)
        @compileError("stack observations must use the native integer frame ABI");
}

extern fn nih_diagnostic_serial_write(u8) callconv(.c) void;
extern fn nih_rom_putc(u8) callconv(.c) i32;
extern fn nih_rom_set_cpu1_entry(u32) callconv(.c) void;
extern fn nih_rom_reset_reason(u32) callconv(.c) u32;
extern var nih_rom_saved_pc: [2]u32;
extern fn nih_boot_capture_getc() callconv(.c) i32;
extern fn nih_storage_clock_start() callconv(.c) u32;
extern fn nih_sqlite_stack_paint(u32) callconv(.c) u32;
extern fn nih_native_cpu1_start() callconv(.c) void;
extern var __stack0_bottom: u8;
extern var __stack0_top: u8;
extern var __stack1_bottom: u8;
extern var __stack1_top: u8;
extern var __irq_stack0_bottom: [4]u32;
extern var __irq_stack0_top: u8;
extern var __irq_stack1_bottom: [4]u32;
extern var __irq_stack1_top: u8;
extern var __flash_boot_start: u8;
extern var __flash_boot_end: u8;

export var nih_native_return_states: [2]tasks.context.ReturnState = @splat(.{ .mstatus = 0, .mcause = 0 });

var progress = [_]u32{ 0, 0 };
var boot_ipi = [_]u32{ 0, 0 };
var boot_clock_ready = false;
var exceptions = [_]u32{ 0, 0 };
var ticks = [_]u32{ 0, 0 };
var display_refresh_reported = false;
var display_refresh_pending: u32 = 0;
var network_report_at: u64 = 0;
var network_ready = false;
var devices_report_at: u64 = 0;
fn serviceNetwork() void {
    if (options.console_live and options.boot_fast) {
        board_devices.poll();
        const now = ui.timer().counter() orelse fail("device report clock");
        if (now >= devices_report_at) {
            devices_report_at = now + 5_000_000;
            const devices = board_devices.snapshot();
            if (options.devices) {
                const touch = board_devices.touch.snapshot();
                logger.record("NIHOS_NATIVE_TOUCH_INPUT", null, .{ "status", "panel", "width", "height", "slots", "polls", "fresh", "errors", "error_code", "max_poll_us" }, &touch);
                const events = board_devices.touch.eventSnapshot();
                logger.record("NIHOS_NATIVE_POINTER", null, .{ "down", "move", "up", "cancel", "multi", "overflow", "quadrants", "queued" }, &events);
                const service = board_devices.serviceSnapshot();
                logger.record("NIHOS_NATIVE_DEVICE_SERVICE", null, .{ "available", "requested", "i2s_owner", "pinned", "workspace" }, &service);
            }
            if (options.audio or (options.devices and board_devices.requestedMask() & 1 != 0)) {
                const audio = board_devices.audio.snapshot();
                logger.record("NIHOS_NATIVE_AUDIO", null, .{ "phase", "fault", "dma", "bclk", "fifo", "eof_descriptor", "parked", "codec_off", "stopped", "returned" }, &audio);
                const io = board_devices.audio.ioFailure();
                logger.record("NIHOS_NATIVE_AUDIO_IO", null, .{ "device", "register", "expected", "actual", "stage" }, &io);
            }
            if (options.microphone or (options.devices and board_devices.requestedMask() & 2 != 0)) {
                const mic = board_devices.microphone.snapshot();
                logger.record("NIHOS_NATIVE_MICROPHONE", null, .{ "phase", "fault", "dma", "end", "parked", "codec_off", "stopped", "returned", "samples", "erased" }, &mic);
                const signal = board_devices.microphone.signal();
                logger.record("NIHOS_NATIVE_MICROPHONE_SIGNAL", null, .{ "active", "clipped", "peak0", "peak1", "peak2", "peak3", "span0", "span1", "span2", "span3" }, &signal);
                const io = board_devices.microphone.ioFailure();
                logger.record("NIHOS_NATIVE_MICROPHONE_IO", null, .{ "register", "expected", "actual", "stage" }, &io);
            }
            if (options.rs485 or (options.devices and board_devices.requestedMask() & 4 != 0)) {
                const io = board_devices.rs485.diagnostic();
                logger.record("NIHOS_NATIVE_RS485_IO", null, .{ "stage", "a", "b", "c" }, &io);
                const rs485 = board_devices.rs485.snapshot();
                logger.record("NIHOS_NATIVE_RS485", null, .{ "phase", "fault", "tx", "rx", "raw", "tx_idle", "dir_low", "stopped", "matched" }, &rs485);
            }
            const imu = board_devices.imuSnapshot();
            logger.record("NIHOS_NATIVE_IMU", null, .{ "chip", "initialized", "stage", "fault", "uploaded", "valid", "samples", "acc_x", "acc_y", "acc_z", "gyr_x", "gyr_y", "gyr_z", "sensor_error", "ready_status" }, &imu);
            logger.record("NIHOS_NATIVE_DEVICES", null, .{ "rtc_present", "rtc_valid", "rtc_flags", "rtc_control", "rtc_error", "rtc_raw_date", "rtc_raw_time", "year", "month", "day", "hour", "minute", "second", "ina_present", "bus_uv", "shunt_uv_x10", "shunt_negative", "imu_chip", "imu_initialized", "errors", "samples" }, &devices);
        }
    }
    if (!options.network) return;
    network.poll();
    serviceTime();
    const now = ui.timer().counter() orelse fail("network report clock");
    const state = network.snapshot();
    if (network_ready and state.ip == 0) {
        network_ready = false;
        print("Wi-Fi disconnected; addresses retired, retry scheduled\n");
    }
    if (!network_ready and state.ip != 0 and state.linklocal != 0) {
        network_ready = true;
        var line: [96]u8 = undefined;
        const message = std.fmt.bufPrint(&line, "Wi-Fi IPv4: {d}.{d}.{d}.{d}; IPv6 link-local ready\n", .{
            state.ip >> 24, (state.ip >> 16) & 255, (state.ip >> 8) & 255, state.ip & 255,
        }) catch fail("network message");
        print(message);
        print("NIHOS_NATIVE_NETWORK_READY\n");
    }
    if (now < network_report_at) return;
    network_report_at = now + 5_000_000;
    logger.record("NIHOS_NATIVE_NETWORK", null, .{ "phase", "station", "error_code", "ip", "linklocal", "echo_requests", "rx", "tx", "polls", "max_poll_us", "renewals", "reconnects", "acquisitions", "failures", "disconnect_reason", "failed_station" }, &state);
    logger.record("NIHOS_NATIVE_CONNECTIVITY", null, .{ "configured", "capabilities", "bluetooth_status" }, &state);
    const bluetooth = network.bluetoothSnapshot();
    logger.record("NIHOS_NATIVE_BLE", null, .{ "phase", "commands", "events", "advertisements", "malformed", "status", "timeouts" }, &bluetooth);
    const heartbeat = .{ .frames = display_service.runtime.snapshot().frames, .ticks0 = @atomicLoad(u32, &ticks[0], .acquire), .ticks1 = @atomicLoad(u32, &ticks[1], .acquire) };
    logger.record("NIHOS_NATIVE_NETWORK_UI", null, .{ "frames", "ticks0", "ticks1" }, &heartbeat);
}
fn flushDisplayReport() void {
    if (!options.console_live or @atomicRmw(u32, &display_refresh_pending, .Xchg, 0, .acquire) == 0) return;
    const observed = display_service.runtime.snapshot();
    logger.record("NIHOS_NATIVE_DISPLAY_IRQ_PASS", null, .{ "frames", "fault", "event", "dsi_error0", "dsi_error1", "dma_error", "bridge_error" }, &observed);
}
noinline fn stageBegin(stage: text_console.boot.Stage) void {
    if (options.console_live and !ui.checkpoint(&logger)) fail("diagnostic checkpoint");
    if (!ui.begin(stage)) fail("boot stage begin");
    if (options.console_live and !ui.service(&logger)) fail("diagnostic stage display");
}
noinline fn stageComplete(stage: text_console.boot.Stage) void {
    if (!ui.complete(stage)) fail("boot stage completion");
    if (options.boot_fast and boot_clock_ready) {
        const stamp = .{ .stage = @as(u32, @backingInt(stage)), .elapsed_us = @as(u32, @truncate(ui.timer().counter() orelse 0)) };
        logger.record("NIHOS_NATIVE_BOOT_TIME", null, .{ "stage", "elapsed_us" }, &stamp);
    }
    if (options.console_live and !ui.service(&logger)) fail("diagnostic stage display");
}
noinline fn showDiagnosticSnapshot() void {
    if (!options.console) return;
    if (!ui.snapshot()) fail("console snapshot");
    if (!tasks.memory.stacks.finish(0)) fail("console stack guards");
    ui.report(&logger);
}

var initialized: u32 = 0x4e494853;

fn reg(address: usize) *volatile u32 {
    return @ptrFromInt(address);
}

noinline fn print(message: []const u8) void {
    ui.append(message);
    for (message) |byte| {
        if (options.console_live) {
            if (byte == '\n') nih_diagnostic_serial_write('\r');
            nih_diagnostic_serial_write(byte);
        } else {
            if (byte == '\n') _ = nih_rom_putc('\r');
            _ = nih_rom_putc(byte);
        }
    }
}
/// Ordinary boot messages share the existing immutable diagnostic Flash span.
/// Fatal strings/output remain resident so failure reporting keeps its fallback.
inline fn printBoot(comptime message: []const u8) void {
    const Store = struct {
        const data linksection(".flash.rodata.records") = blk: {
            var bytes: [128]u8 = @splat(0);
            @memcpy(bytes[0..message.len], message);
            break :blk bytes;
        };
    };
    print(Store.data[0..message.len]);
}

const Console = struct {
    pub fn write(_: Console, message: []const u8) void {
        print(message);
    }
};
var logger = record_log.PlacedWriter(Console, ".flash.rodata.records"){ .sink = .{} };

noinline fn hex(value: u32) void {
    const digits = "0123456789abcdef";
    var bytes: [8]u8 = undefined;
    for (&bytes, 0..) |*byte, index| byte.* = digits[(value >> @as(u5, @intCast((7 - index) * 4))) & 15];
    print(&bytes);
}

/// Bounded serial TX calls this only while waiting. Panic has MIE clear and
/// must still rearm DMA; normal operation leaves the IRQ as the sole owner.
export fn nih_diagnostic_serial_idle() callconv(.c) void {
    if (!options.console_live) return;
    const status = asm volatile ("csrr %[status], mstatus"
        : [status] "=r" (-> u32),
    );
    const hart = asm volatile ("csrr %[hart], mhartid"
        : [hart] "=r" (-> u32),
    );
    if (hart == 0 and status & 8 == 0 and display_service.runtime.active()) display_service.runtime.onInterrupt();
}

fn fail(reason: []const u8) noreturn {
    asm volatile ("csrci mstatus, 8");
    if (options.card_auto) {
        if (@import("card_auto.zig").armed) {
            const diagnostic = @import("card_auto.zig").diagnostic();
            logger.record("NIHOS_NATIVE_CARD_AUTO_ABORT", null, .{ "job", "kind", "state", "fault", "pin1_verifies", "pin2_verifies" }, &diagnostic);
            if (!@import("card_auto.zig").emergency()) print("NIHOS_NATIVE_CARD_ERASE_FAIL\n");
        }
    } else if (options.card_read and @import("card_read.zig").armed) {
        const diagnostic = @import("card_read.zig").diagnostic();
        logger.record("NIHOS_NATIVE_CARD_ABORT", null, .{ "state", "verifies", "surface_verifies", "outstanding", "remaining", "fault" }, &diagnostic);
        if (!@import("card_read.zig").emergency()) print("NIHOS_NATIVE_CARD_ERASE_FAIL\n");
    } else if (options.console) {
        const hart = asm volatile ("csrr %[hart], mhartid"
            : [hart] "=r" (-> u32),
        );
        if (hart == 0) ui.failed();
    }
    print("NIHOS_NATIVE_FAIL ");
    print(reason);
    print("\n");
    if (options.console_live) {
        const hart = asm volatile ("csrr %[hart], mhartid"
            : [hart] "=r" (-> u32),
        );
        if (hart == 0 and ui.failureFrame()) {
            print("NIHOS_NATIVE_UI_FAILURE visible=1 scheduler=stopped\n");
            while (true) {
                display_service.runtime.onInterrupt();
                _ = ui.service(&logger);
            }
        }
    }
    while (true) asm volatile ("nop");
}

fn cycle() u32 {
    return asm volatile ("csrr %[result], mcycle"
        : [result] "=r" (-> u32),
    );
}

fn watchdogOff() void {
    // ESP-IDF v5.4.4 lpwdt_ll.h: unlock, disable RWDT, relock.
    reg(0x50116018).* = 0x50d83aa1;
    reg(0x50116000).* &= ~@as(u32, 1 << 31);
    reg(0x50116018).* = 0;
}

fn startCpu1() void {
    // PMU.cpu_sw_stall.hpcore1_sw_stall_code = 0xff (unstall).
    reg(0x50115200).* = (reg(0x50115200).* & ~@as(u32, 0xff0000)) | 0xff0000;
    var attempts: u32 = 0;
    while (reg(0x500e5064).* & 2 != 0) : (attempts += 1) {
        if (attempts == 100_000) fail("CPU1 unstall timeout");
    }
    // HP_SYS_CLKRST: core1 clock on, global reset released.
    reg(0x500e6014).* |= 1 << 4;
    reg(0x500e60c0).* &= ~@as(u32, 1 << 8);
    asm volatile ("fence rw, rw" ::: .{ .memory = true });
    nih_rom_set_cpu1_entry(@intFromPtr(&nih_native_cpu1_start));
}

fn timer(hart: u32) timer_group.Timer {
    return timer_group.Timer.fromGroup(0x500c2000, hart).?;
}

fn prepareTimers() void {
    // Single owner before CPU1 is released: TG0 APB on, reset the group.
    reg(0x500e601c).* |= 1 << 21;
    reg(0x500e60c4).* |= 1 << 6;
    reg(0x500e60c4).* &= ~@as(u32, 1 << 6);
    // Reset re-enables flash-boot WDT protection. Disable it explicitly.
    reg(0x500c2064).* = 0x50d83aa1;
    reg(0x500c2048).* = 0;
    reg(0x500c2064).* = 0;
    // Both TG0 channels: 40 MHz XTAL, divider 40 => 1 MHz.
    reg(0x500e6094).* = (reg(0x500e6094).* & ~@as(u32, (3 << 22) | (3 << 25))) |
        (1 << 24) | (1 << 27);
    for (0..2) |hart| {
        const channel = timer(@intCast(hart));
        channel.channel.config = 40 << 13;
        if (!channel.configureOneShot(tasks.period_us)) fail("timer configuration");
    }
    reg(0x500c2070).* = 3;
}

fn clearInterruptRoutes(hart: u32) void {
    asm volatile ("csrci mstatus, 8" ::: .{ .memory = true });
    // CLIC MMIO is hart-local. Mask all lines, use non-vectored level 1.
    for (0..48) |line| reg(0x20801000 + line * 4).* = 0;
    reg(0x20800000).* = 3 << 1; // NLBITS = 3.
    // Clear this hart's matrix, then route TG0.T[hart] to CLIC input 16.
    const matrix = 0x500d6000 + hart * 0x800;
    // 136 matches ETS_MAX_INTR_SOURCE, including rev3's sparse new inputs.
    for (0..136) |source| reg(matrix + source * 4).* = 0;
}

fn routeDisplay() void {
    const source = display_service.runtime.irqSource();
    if (source >= 136) fail("display IRQ source");
    reg(0x500d6000 + source * 4).* = 18;
    reg(0x20801048).* = (0x3f << 24) | (1 << 8);
    asm volatile ("fence iorw, iorw" ::: .{ .memory = true });
}

fn enableTimer(hart: u32) void {
    if (options.console_live and hart == 0 and display_service.runtime.active()) {
        asm volatile ("csrci mstatus, 8" ::: .{ .memory = true });
    } else clearInterruptRoutes(hart);
    const matrix = 0x500d6000 + hart * 0x800;
    reg(matrix + (46 + hart) * 4).* = 16;
    reg(0x20801040).* = (0x3f << 24) | (1 << 8);
    tasks.ipi.bell(hart).acknowledge();
    reg(matrix + (79 + hart) * 4).* = 17;
    reg(0x20801044).* = (0x3f << 24) | (1 << 8);
    if (options.console_live and hart == 0 and display_service.runtime.active()) routeDisplay();
    if (!timer(hart).configureOneShot(tasks.period_us)) fail("scheduler timer restart");
    timer(hart).start();
    if (options.boot_test == 5 and hart == 1) timer(hart).disarm();
    asm volatile ("fence rw, rw" ::: .{ .memory = true });
    asm volatile ("csrsi mstatus, 8" ::: .{ .memory = true });
}

export fn nih_native_dispatch(frame: *tasks.context.IntegerContext, cause: u32, hart: u32, status: u32) callconv(.c) *tasks.context.IntegerContext {
    if (hart >= 2) fail("invalid hart");
    if (!interruptStackValid(hart, frame)) fail("interrupt stack/MIE");
    const state = tasks.context.ReturnState{ .mstatus = status, .mcause = cause };
    if (options.display_scanout and hart == 0 and cause & 0x8000_0fff == 0x8000_0012) {
        const display = display_service.runtime;
        if (!display.active()) fail("unexpected display IRQ");
        display.onInterrupt();
        const observed = display.snapshot();
        if (observed.fault != 0) {
            logger.record("NIHOS_NATIVE_DISPLAY_IRQ_FAIL", null, .{ "frames", "fault", "event", "dsi_error0", "dsi_error1", "dma_error", "bridge_error" }, &observed);
            fail("display refresh");
        }
        if (observed.frames >= 32 and !display_refresh_reported and !options.touch_check and !options.keypad_demo and !options.card_read) {
            display_refresh_reported = true;
            if (options.console_live) @atomicStore(u32, &display_refresh_pending, 1, .release) else logger.record("NIHOS_NATIVE_DISPLAY_IRQ_PASS", null, .{ "frames", "fault", "event", "dsi_error0", "dsi_error1", "dma_error", "bridge_error" }, &observed);
        }
        nih_native_return_states[hart] = state;
        return frame;
    }
    if (options.boot_fast and cause & 0x8000_0fff == 0x8000_0011) {
        tasks.ipi.bell(hart).acknowledge();
        _ = @atomicRmw(u32, &boot_ipi[hart], .Add, 1, .release);
        if (hart == 1 and options.boot_test != 4) tasks.ipi.bell(0).raise();
        nih_native_return_states[hart] = state;
        return frame;
    }
    if (tasks.ready(hart)) {
        const selected = if (cause & 0x8000_0fff == 11)
            tasks.onCall(hart, frame, state, timer(hart))
        else if (cause & 0x8000_0fff == 0x8000_0010 and timer(hart).clearPending()) timer_path: {
            _ = @atomicRmw(u32, &ticks[hart], .Add, 1, .release);
            break :timer_path tasks.onTimer(hart, frame, state, timer(hart));
        } else if (cause & 0x8000_0fff == 0x8000_0011)
            tasks.onIpi(hart, frame, state, timer(hart))
        else
            null;
        const next = selected orelse trapFailure(frame, cause, hart, "native task dispatch");
        tasks.floating.selectBank(hart, next.floating_context);
        const next_state = if (next.floating_context == 0) next.state.integerOnly() else next.state.floatingReady();
        nih_native_return_states[hart] = next_state.returningFrom(state);
        return next.frame;
    }
    nih_native_return_states[hart] = state;
    if (hart < 2 and cause & 0x8000_0fff == 11) {
        _ = @atomicRmw(u32, &exceptions[hart], .Add, 1, .release);
        frame.mepc += 4;
        return frame;
    }
    trapFailure(frame, cause, hart, "unexpected trap");
}

fn trapFailure(frame: *const tasks.context.IntegerContext, cause: u32, hart: u32, reason: []const u8) noreturn {
    print("NIHOS_NATIVE_TRAP cause=");
    hex(cause);
    print(" pc=");
    hex(frame.mepc);
    print(" hart=");
    hex(hart);
    print(" mtval=");
    hex(asm volatile ("csrr %[value], mtval"
        : [value] "=r" (-> u32),
    ));
    fail(reason);
}

export fn nih_microphone_stage(code: u32) callconv(.c) void {
    if (options.microphone or options.devices) {
        print("NIHOS_NATIVE_MICROPHONE_STAGE code=");
        hex(code);
        print("\n");
    }
}

export fn nih_audio_stage(code: u32) callconv(.c) void {
    if (!options.audio and !options.devices) return;
    const stage = .{ .code = code };
    logger.record("NIHOS_NATIVE_AUDIO_STAGE", null, .{"code"}, &stage);
}

export fn nih_native_task_failed() callconv(.c) noreturn {
    if (options.fatfs_native) {
        print("NIHOS_NATIVE_TASK_FAILURE caller=");
        hex(@returnAddress());
        print("\n");
    }
    fail("task invariant");
}

export fn nih_native_psram_mismatch(stage: u32, address: u32, actual: u32, expected: u32) callconv(.c) noreturn {
    print("NIHOS_NATIVE_PSRAM_MISMATCH stage=");
    hex(stage);
    print(" address=");
    hex(address);
    print(" actual=");
    hex(actual);
    print(" expected=");
    hex(expected);
    print("\n");
    fail("PSRAM mapping/data invariant");
}

export fn nih_fp_native_mismatch(code: u32, actual: u32, expected: u32) callconv(.c) noreturn {
    print("NIHOS_NATIVE_FP_MISMATCH code=");
    hex(code);
    print(" actual=");
    hex(actual);
    print(" expected=");
    hex(expected);
    print("\n");
    fail("compiled FP invariant");
}

fn prepareTasks(hart: u32) void {
    const gp = asm volatile ("mv %[result], gp"
        : [result] "=r" (-> u32),
    );
    const minimum = (if (hart == 0) @intFromPtr(&__stack0_bottom) else @intFromPtr(&__stack1_bottom)) + 16;
    const maximum = if (hart == 0) @intFromPtr(&__stack0_top) else @intFromPtr(&__stack1_top);
    if (!tasks.prepare(hart, minimum, maximum, gp)) fail("task prepare");
}

fn interruptGuard(hart: u32) *volatile [4]u32 {
    return if (hart == 0) &__irq_stack0_bottom else &__irq_stack1_bottom;
}

fn interruptStackValid(hart: u32, frame: *const tasks.context.IntegerContext) bool {
    const guard = interruptGuard(hart);
    for (0..4) |word| if (guard[word] != tasks.memory.stacks.layout.irq_guard) return false;
    const sp = asm volatile ("mv %[result], sp"
        : [result] "=r" (-> u32),
    );
    const status = asm volatile ("csrr %[result], mstatus"
        : [result] "=r" (-> u32),
    );
    const top = if (hart == 0) @intFromPtr(&__irq_stack0_top) else @intFromPtr(&__irq_stack1_top);
    return status & (8 | 0x6000) == 0 and sp >= @intFromPtr(guard) + 16 and sp < top and
        tasks.memory.stacks.capture(hart, @intFromPtr(frame), frame.sp, sp);
}

fn taskReport(hart: u32) void {
    const report = tasks.report(hart);
    if (report.progress[0] == 0 or report.progress[1] == 0 or
        report.captures[0] < 4 or report.captures[1] < 4 or report.switches < 8 or
        report.calls < 12 or report.reaped != 3 or report.sleeps != 2)
        fail("task execution proof");
    const fields = .{
        .work0 = report.progress[0],
        .work1 = report.progress[1],
        .cap0 = report.captures[0],
        .cap1 = report.captures[1],
        .switches = report.switches,
        .calls = report.calls,
        .reaped = report.reaped,
        .sleeps = report.sleeps,
        .elapsed = report.ticks,
    };
    logger.record("NIHOS_NATIVE_TASKS", hart, .{ "work0", "work1", "cap0", "cap1", "switches", "calls", "reaped", "sleeps", "elapsed" }, &fields);
}

fn ipiReport(hart: u32) void {
    const report = tasks.ipi.report(hart);
    if (!report.finished or report.sent != 64 or report.received != 64 or
        report.delivered != 64 or report.woken != 64 or report.rejected != 0 or
        report.from_idle < 64 or report.entries < 64 or report.returns < 64 or
        report.pending_before_wfi != 1 or report.self_ipi != 1 or
        report.timer_start != report.timer_end or report.queued != 0)
        fail("IPI/idle proof");
    logger.record("NIHOS_NATIVE_IPI", hart, .{ "sent", "received", "ipis", "delivered", "woken", "rejected", "from_idle", "entries", "returns", "pending_before_wfi", "self_ipi", "timer_start", "timer_end", "queued" }, &report);
}

fn floatingReport(hart: u32) void {
    const report = tasks.floating.report(hart);
    if (report.confirmed != 1 or report.saves != report.restores or
        report.saves != report.timer + report.calls + report.ipi) fail("FP quiescence");
    if (tasks.floating.enabled) {
        if (report.initial != 5 or report.saves == 0 or report.checks0 < 4 or report.checks1 < 4 or
            report.checks2 < 4 or report.timer < 8 or report.calls < 12 or report.ipi < 1)
            fail("FP execution evidence");
        if (tasks.floating.compiled and report.app_timer < 4) fail("compiled FP preemption");
    } else if (report.initial != 0 or report.saves != 0 or report.restores != 0 or report.timer != 0 or report.calls != 0 or report.ipi != 0)
        fail("integer FP overhead");
    logger.record("NIHOS_NATIVE_FP", hart, .{ "checks0", "checks1", "checks2", "timer", "calls", "ipi", "saves", "restores", "initial", "app_timer", "confirmed" }, &report);
}

export fn nih_native_cpu1_main() callconv(.c) noreturn {
    nih_rom_set_cpu1_entry(0);
    if (!tasks.memory.stacks.begin(1)) fail("CPU1 stack bank begin");
    if (!options.boot_fast and !flash_records.begin(1)) fail("CPU1 Flash records begin");
    interruptGuard(1).* = @splat(tasks.memory.stacks.layout.irq_guard);
    asm volatile ("ecall" ::: .{ .memory = true });
    if (!tasks.memory.begin()) fail("CPU1 memory begin");
    if (options.high_sram) tasks.memory.high.peer();
    native_psram.memory.peer();
    if (!tasks.memory.beginExternal()) fail("CPU1 external memory begin");
    native_psram.memory.ownerReady(1);
    prepareTasks(1);
    if (options.boot_test == 2) {
        const started = ui.timer().counter() orelse fail("late CPU1 clock");
        while ((ui.timer().counter() orelse fail("late CPU1 clock")) - started < 100_000) asm volatile ("nop");
    }
    enableTimer(1);
    if (options.boot_fast) {
        if (options.boot_test != 3) @atomicStore(u32, &progress[1], 1, .release);
        while (true) tasks.idleOnce(1);
    }
    while (true) {
        _ = tasks.service(1);
        if (tasks.ipi.done()) {
            if (options.storage_service and !options.fatfs_native) runStorageTasks(1);
            tasks.floating.quiesce(1);
            if (!flash_records.finish(1)) fail("CPU1 Flash records finish");
            if (!tasks.memory.stacks.finish(1)) fail("CPU1 stack bank finish");
            if (!tasks.memory.finish()) fail("CPU1 memory finish");
            if (options.broker) {
                broker_runtime.peerQuiet();
                while (!broker_runtime.ready()) asm volatile ("nop");
                if (!tasks.startBroker(1)) fail("broker task admission");
                while (!broker_runtime.done()) {
                    _ = tasks.service(1);
                    if (tasks.calls.yieldNow() != 0) fail("broker peer yield");
                }
                if (options.fatfs_native) {
                    while (!storage_runtime.ready()) asm volatile ("nop");
                    runStorageTasks(1);
                }
            }
            while (true) asm volatile ("wfi");
        }
        _ = @atomicRmw(u32, &progress[1], .Add, 1, .release);
        tasks.idleOnce(1);
    }
}

noinline fn runStorageTasks(hart: u32) void {
    if (!tasks.startStorage(hart)) fail("storage task admission");
    const began = cycle();
    while (!storage_runtime.finished()) {
        _ = tasks.service(hart);
        storage_runtime.poll(hart);
        if (tasks.calls.yieldNow() != 0) fail("storage bootstrap yield");
        if (cycle() -% began > 1_000_000_000) fail("storage task timeout");
    }
}

noinline fn runSqlProbe() linksection(if (options.cold_flash and options.fatfs_native) ".flash.text.storage" else ".text") void {
    if (options.qualification) {
        const soak = @import("sqlite_probe.zig").soak();
        logger.record("NIHOS_NATIVE_SQLITE_SOAK", null, .{ "loops", "sessions", "queries", "heap_before", "heap_after", "max_stack", "confirmed" }, &soak);
    }
    const sql = @import("sqlite_probe.zig").run();
    logger.record("NIHOS_NATIVE_SQLITE", null, .{ "status", "owner", "sessions", "queries", "open_pc", "text_start", "text_end", "rodata_start", "rodata_end", "heap_before", "heap_after", "stack_low", "stack_high", "painted_to", "observed_used", "mie" }, &sql);
    const classes = @import("sqlite_probe.zig").classPeaks();
    logger.record("NIHOS_NATIVE_SQLITE_CLASSES", null, .{ "c8", "c16", "c32", "c64", "c128", "c256", "c512", "c1024", "c2048", "c4096" }, &classes);
}

noinline fn bootMemory() u32 {
    const external = native_psram.probe(timer(0));
    const BootCode = struct { start: u32, end: u32, probe: u32, mapping: u32, completed: u32 };
    const boot_code = BootCode{
        .start = @as(u32, @intFromPtr(&__flash_boot_start)),
        .end = @as(u32, @intFromPtr(&__flash_boot_end)),
        .probe = external.execution_pc,
        .mapping = external.mapping.execution_pc,
        .completed = @as(u32, 1),
    };
    logger.record("NIHOS_NATIVE_BOOT_CODE", null, .{ "start", "end", "probe", "mapping", "completed" }, &boot_code);
    if (!timer(0).configureOneShot(tasks.period_us)) fail("PSRAM boot timer return");
    const DiscoveryRecord = struct { status: u32, configuration: u32, identity: u32, bytes: u32, transactions: u32, mapped: u32, allocatable: u32 };
    const discovery = DiscoveryRecord{
        .status = @backingInt(external.discovery.status),
        .configuration = external.discovery.configuration,
        .identity = external.discovery.identity,
        .bytes = external.discovery.bytes,
        .transactions = external.transactions,
        .mapped = external.mapping.bytes,
        .allocatable = 0,
    };
    logger.record("NIHOS_NATIVE_PSRAM", null, .{ "status", "configuration", "identity", "bytes", "transactions", "mapped", "allocatable" }, &discovery);
    if (options.psram_200) {
        const link = .{ .core = reg(0x500e6030).*, .bus = reg(0x5008e050).*, .command = reg(0x5008f014).*, .sctrl = reg(0x5008e040).*, .cmd = reg(0x5008e044).*, .ddr = reg(0x5008e0d8).*, .dll_cache = reg(0x5008e190).*, .dll_command = reg(0x5008e180).*, .dqs0 = reg(0x500e123c).*, .dqs1 = reg(0x500e1268).* };
        logger.record("NIHOS_NATIVE_PSRAM_LINK", null, .{ "core", "bus", "command", "sctrl", "cmd", "ddr", "dll_cache", "dll_command", "dqs0", "dqs1" }, &link);
    }
    if (options.psram_200) logger.record("NIHOS_NATIVE_PSRAM_TUNING", null, .{ "status", "stage", "phase_mask", "phase", "delay_mask", "delay", "repetitions", "reads", "writes", "error_code" }, &external.tuning);
    if (options.psram_mpll) logger.record("NIHOS_NATIVE_PSRAM_MPLL", null, .{ "status", "mhz", "reused", "divider", "error_code" }, &external.mpll);
    logger.record("NIHOS_NATIVE_PSRAM_SUPPLY", null, .{ "programmed", "calibrated", "dref", "mul", "control", "analog", "settled" }, &external.supply);
    const IoRecord = struct { status: u32, mr0: u32, mr4: u32, mr8: u32, addresses: u32, passes: u32, reads: u32, writes: u32, transactions: u32 };
    const io = IoRecord{
        .status = external.io_status,
        .mr0 = external.exercise.mr0,
        .mr4 = external.exercise.mr4,
        .mr8 = external.exercise.mr8,
        .addresses = external.exercise.addresses,
        .passes = external.exercise.passes,
        .reads = external.exercise.reads,
        .writes = external.exercise.writes,
        .transactions = external.total_transactions,
    };
    logger.record("NIHOS_NATIVE_PSRAM_IO", null, .{ "status", "mr0", "mr4", "mr8", "addresses", "passes", "reads", "writes", "transactions" }, &io);
    logger.record("NIHOS_NATIVE_PSRAM_MAP", null, .{ "status", "failure", "line_bytes", "last_address", "last_actual", "last_expected", "bytes", "entries", "cpu_checks", "command_checks", "transactions", "syncs" }, &external.mapping);
    if (external.discovery.status != .absent and
        (external.discovery.status != .detected or external.io_status != 1 or external.mapping.status != 1))
        fail("PSRAM qualification");
    if (options.qualification) {
        if (external.mapping.status != 1) fail("qualification requires PSRAM");
        const sweep = native_psram.memory.fullSweep(external.mapping.bytes);
        logger.record("NIHOS_NATIVE_PSRAM_SWEEP", null, .{ "bytes", "passes", "reads", "writes", "syncs", "confirmed" }, &sweep);
    }
    if (options.storage and external.mapping.status != 1) fail("storage requires mapped PSRAM");
    return external.mapping.bytes;
}

extern var __flash_sdmmc_boot_start: u8;
extern var __flash_sdmmc_boot_end: u8;
noinline fn runIoLifetimes(expected_crc: u32) linksection(".flash.text.storage") void {
    const lifetime = @import("sdmmc_probe.zig").qualifyLifetimes(expected_crc);
    logger.record("NIHOS_NATIVE_IO_LIFETIMES", null, .{ "version", "status", "normal_reads", "cancelled", "removed", "stale_rejected", "idle_denied", "fences", "unpublished", "crc", "ctrl", "dma_mode", "dma_fsm", "irq_mask", "dma_mask", "descriptor", "descriptor_word" }, &lifetime);
    if (lifetime.status != 1) fail("SD request lifetime qualification");
    if (options.sd_removal) {
        const removal = @import("sdmmc_probe.zig").qualifyRemoval(expected_crc);
        logger.record("NIHOS_NATIVE_SD_REMOVAL", null, .{ "version", "status", "before_reads", "failed_command", "failed_interrupts", "unpublished", "fenced", "idle_denied", "stale_rejected", "reinserted", "after_reads", "crc", "generation_before", "generation_after", "ctrl", "dma_mode", "dma_fsm", "irq_mask", "dma_mask", "descriptor", "descriptor_word" }, &removal);
        if (removal.status != 1) fail("physical SD removal qualification");
    }
}

noinline fn runSdProbe(workspace: ?*[8192]u8) u32 {
    const sd = @import("sdmmc_probe.zig").run(timer(0), workspace);
    const Code = struct { start: u32, end: u32, pc: u32, completed: u32 };
    const code = Code{ .start = @intFromPtr(&__flash_sdmmc_boot_start), .end = @intFromPtr(&__flash_sdmmc_boot_end), .pc = sd.code_pc, .completed = sd.status };
    logger.record("NIHOS_NATIVE_SDMMC_CODE", null, .{ "start", "end", "pc", "completed" }, &code);
    logger.record("NIHOS_NATIVE_SDMMC", null, .{ "status", "stage", "command", "interrupts", "response", "commands", "sectors_low", "sectors_high", "reads", "crc0", "crc1", "crc_middle", "crc_last", "bus_bits", "clock_khz", "writes", "error_code", "host_status", "data_words", "dma" }, &sd);
    for (0..sd.stage_count) |phase| {
        logger.record("NIHOS_NATIVE_SDMMC_STAGE", null, .{ "index", "bus_bits", "clock_khz", "scr_widths", "host_width", "divider", "reads", "crc0", "crc1", "crc_middle", "crc_last" }, &sd.stages[phase]);
        if (sd.stages[phase].samples != 0) logger.record("NIHOS_NATIVE_SDMMC_SWEEP", null, .{ "index", "samples", "digest" }, &sd.stages[phase]);
    }
    if (options.storage and !options.fatfs_sd_direct) {
        logger.record("NIHOS_NATIVE_STORAGE", null, .{ "status", "error_code", "passes", "block_size", "block_count", "entries", "files", "directories", "directory_digest", "file_bytes", "file_crc", "file_name_digest", "reads", "denied_writes" }, &sd.storage);
        logger.record("NIHOS_NATIVE_STORAGE_STACK", null, .{ "low", "high", "painted_to", "used", "confirmed" }, &sd.storage_stack);
        logger.record("NIHOS_NATIVE_STORAGE_API", null, .{ "status", "opens", "closes", "cancelled", "rejected", "read_calls", "workspace_bytes", "used_bytes", "cleared" }, &sd.api);
        const WorkspaceRecord = struct { start: u32, bytes: u32, cleared: u32 };
        const reservation = WorkspaceRecord{ .start = @intFromPtr(workspace.?), .bytes = 8192, .cleared = sd.api.cleared };
        logger.record("NIHOS_NATIVE_STORAGE_WORKSPACE", null, .{ "start", "bytes", "cleared" }, &reservation);
        if ((sd.storage.status != 1 and sd.storage.status != 2) or sd.storage_stack.confirmed != 1 or sd.api.status != 1) fail("storage probe");
    }
    if (!timer(0).configureOneShot(tasks.period_us)) fail("SDMMC timer return");
    if (sd.status != 1) fail("SDMMC probe");
    return sd.crc0;
}

noinline fn captureBoot(snapshot: *const reset_capture.Snapshot) linksection(".flash.text.storage") void {
    if (nih_storage_clock_start() != 1) fail("boot capture clock");
    const clock = timer_group.Timer.fromGroup(0x500c3000, 0).?;
    defer clock.stop();
    const started = clock.counter() orelse fail("boot capture counter");
    var last_marker = started;
    var drained: u32 = 0;
    while (nih_boot_capture_getc() >= 0) {
        drained += 1;
        if (drained >= 1024) fail("boot capture stale input flood");
    }
    print("NIHOS_CAPTURE_WAIT\n");
    while (true) {
        if (nih_boot_capture_getc() == 'G') break;
        const now = clock.counter() orelse fail("boot capture counter");
        if (now - started >= 120_000_000) fail("boot capture timeout");
        if (now - last_marker >= 1_000_000) {
            print("NIHOS_CAPTURE_WAIT\n");
            last_marker = now;
        }
    }
    logger.record("NIHOS_NATIVE_RESET", null, .{ "cpu0", "ack", "raw_cause", "lp", "cpu1", "reset_flags", "saved_pc0", "saved_pc1", "clock_gates", "wdt_valid", "wdt0", "wdt1" }, snapshot);
}

export fn nih_native_main() callconv(.c) noreturn {
    // Sample before watchdogOff / prepareTimers alter the state. Assembly CRT
    // and the loader have already run; this does not record their entry state.
    const snapshot = if (options.cold_capture) reset_capture.sample(struct {
        pub fn read32(_: @This(), address: usize) u32 {
            return @as(*const volatile u32, @ptrFromInt(address)).*;
        }
    }{}, @intFromPtr(&nih_rom_saved_pc)) else std.mem.zeroes(reset_capture.Snapshot);
    if (options.cold_capture and snapshot.cpu0 != nih_rom_reset_reason(0)) fail("reset capture mismatch");
    watchdogOff();
    stageBegin(.crt);
    if (!tasks.memory.stacks.begin(0)) fail("CPU0 stack bank begin");
    interruptGuard(0).* = @splat(tasks.memory.stacks.layout.irq_guard);
    if (options.cold_capture) {
        // TG0 flash-boot MWDT can survive into the native entry on power-on.
        // Stop it before waiting for USB enumeration; USB reset often hides it.
        prepareTimers();
        captureBoot(&snapshot);
    }
    printBoot("\nNIHOS_NATIVE_BOOT backend=zig-sram rtos=none\n");
    print(if (tasks.floating.enabled) "NIHOS_NATIVE_MODE floating=1\n" else "NIHOS_NATIVE_MODE floating=0\n");
    print(if (tasks.floating.compiled) "NIHOS_NATIVE_COMPILER enabled=1\n" else "NIHOS_NATIVE_COMPILER enabled=0\n");
    if (options.sqlite) print("NIHOS_NATIVE_SQLITE_MODE enabled=1\n");
    if (options.qualification) print("NIHOS_NATIVE_QUALIFICATION enabled=1\n");
    if (options.boot_fast) printBoot("NIHOS_NATIVE_PROFILE normal=1 qualification=0\n");
    if (options.boot_test != 0) {
        const test_case: extern struct { case: u32 } = .{ .case = options.boot_test };
        logger.record("NIHOS_NATIVE_BOOT_TEST", null, .{"case"}, &test_case);
    }
    if (options.sdmmc) print("NIHOS_NATIVE_SDMMC_MODE enabled=1\n");
    if (options.usb) print("NIHOS_NATIVE_USB_MODE enabled=1\n");
    if (options.jpki) print("NIHOS_NATIVE_JPKI_MODE pin_input=disabled\n");
    if (progress[0] != 0 or progress[1] != 0 or
        @as(*volatile u32, &initialized).* != 0x4e494853)
        fail("CRT data/BSS");
    asm volatile ("ecall" ::: .{ .memory = true });
    if (exceptions[0] != 1) fail("CPU0 exception return");
    printBoot("NIHOS_NATIVE_CRT_PASS bss=zero data=valid ecall=returned\n");
    stageComplete(.crt);
    stageBegin(.memory);
    if (!options.boot_fast and !flash_records.begin(0)) fail("CPU0 Flash records begin");
    if (!tasks.memory.prepare() or !tasks.memory.begin()) fail("CPU0 memory prepare");
    if (!options.cold_capture) prepareTimers();
    if (options.cpu_mhz != 0 and !cpu_boot.run(timer(0), &logger)) fail("native CPU clock");
    if (!ui.initializeClock()) fail("diagnostic clock");
    boot_clock_ready = true;
    const external_bytes = bootMemory();
    if (options.broker and external_bytes != 32 * 1024 * 1024) fail("broker PSRAM geometry");
    if (options.high_sram and !tasks.memory.high.init(external_bytes)) fail("high SRAM initialization");
    stageComplete(.memory);
    if (options.console and !options.sdmmc) ui.unavailable(.storage);
    var external_heap_start = native_psram.memory.heap_start;
    var display_panel: u32 = 0;
    var external_heap_bytes = external_bytes -| native_psram.memory.reserved_bytes;
    if (options.display) {
        stageBegin(.display_prepare);
        const selected = @import("tab5_display").layout(external_bytes) orelse fail("display requires mapped PSRAM");
        const display = display_service.probe.run(timer(0), selected);
        logger.record("NIHOS_NATIVE_DISPLAY_PREP", null, .{ "status", "stage", "error_code", "panel", "transactions", "frame_start", "frame_bytes", "reserve_bytes", "checksum", "phy_trim", "phy_status", "scanout", "backlight" }, &display);
        logger.record("NIHOS_NATIVE_DISPLAY_PINS", null, .{ "initial_pins", "failed_pins", "recovery_pulses" }, &display);
        if (!timer(0).configureOneShot(tasks.period_us)) fail("display timer return");
        if (display.status != 1) fail("display preparation");
        display_panel = display.panel;
        external_heap_start = selected.heap_start;
        external_heap_bytes = selected.heap_bytes;
        stageComplete(.display_prepare);
    }
    if (options.console_live) {
        startDisplay(ui.timer(), display_panel, true);
        stageBegin(.input);
        ui.input(&logger);
        stageComplete(.input);
        ui.liveReport(&logger, false);
    }
    if (options.usb and !options.card_read) {
        const usb_probe = @import("usb_probe.zig");
        const usb_report = usb_probe.run(timer(0));
        logger.record("NIHOS_NATIVE_USB", null, .{ "status", "stage", "error_code", "core_id", "port", "speed", "vid", "pid", "config_bytes", "interfaces", "ccid", "bulk_in", "bulk_out", "interrupt_in", "max_message", "transfers", "slot_queries", "card_state", "last_irq", "last_descriptor", "dma_stopped" }, &usb_report);
        if (options.jpki) {
            const card = &usb_probe.card_report;
            logger.record("NIHOS_NATIVE_JPKI", null, .{ "status", "stage", "error_code", "power_status", "power_error", "atr_bytes", "card_state", "apdu_count", "rejected", "pin_data_sent", "auth_before", "auth_after", "last_sw", "serial_bytes", "poweroff" }, card);
            if (card.serial_bytes != 0) {
                print("NIHOS_NATIVE_JPKI_SERIAL hex=");
                const digits = "0123456789abcdef";
                for (card.serial[0..card.serial_bytes]) |byte| {
                    _ = nih_rom_putc(digits[byte >> 4]);
                    _ = nih_rom_putc(digits[byte & 15]);
                }
                print("\n");
            }
        }
        if (!timer(0).configureOneShot(tasks.period_us)) fail("USB timer return");
    }
    var sd_crc: u32 = 0;
    if (options.sdmmc) {
        stageBegin(.storage);
        sd_crc = runSdProbe(if (options.storage) @ptrFromInt(@import("psram_mapping").storage_workspace_start) else null);
        stageComplete(.storage);
    }
    if (options.network) {
        print("Wi-Fi starting (exclusive SDIO, lease maintenance enabled)\n");
        if (!network_config.enabled) print("Wi-Fi unconfigured: waiting for settings\n");
        network.begin(ui.timer(), if (!network_config.enabled) .disabled else if (network_config.saved) .saved else .{ .network = .{ .ssid = &network_config.ssid, .password = &network_config.password } }, ui.serviceBacking(network.storage_bytes));
    }
    if (options.console_live and options.boot_fast) board_devices.begin(ui.timer(), display_panel);
    stageBegin(.cores);
    if (options.console_fault) {
        print("NIHOS_NATIVE_UI_FAULT_INJECTION stage=cores\n");
        fail("injected boot failure");
    }
    if (options.storage_service and !options.fatfs_native) storage_runtime.init();
    if (options.fatfs_native) @import("sdmmc_probe.zig").runtimeEnd();
    prepareTasks(0);
    startCpu1();
    if (options.high_sram) tasks.memory.high.ownerExchange();
    const external_smp = native_psram.exchange();
    logger.record("NIHOS_NATIVE_PSRAM_SMP", null, .{ "status", "rounds", "owner_checks", "peer_checks", "command_checks", "syncs" }, &external_smp);
    if (external_smp.status == 1 and !tasks.memory.prepareExternal(
        external_heap_start,
        external_heap_bytes,
    )) fail("external memory prepare");
    if (options.console_live) {
        if (reg(0x20801040).* & (1 << 8) != 0 or reg(0x20801044).* & (1 << 8) != 0 or reg(0x20801048).* & (1 << 8) == 0) fail("display-only bootstrap routes");
        if (!tasks.memory.beginExternalWithDisplayIrq()) fail("CPU0 external memory begin");
    } else if (!tasks.memory.beginExternal()) fail("CPU0 external memory begin");
    native_psram.memory.releasePeer();
    native_psram.memory.ownerReady(0);
    enableTimer(0);
    if (options.boot_fast) normalReady();
    var previous: u32 = 0;
    var rounds: u32 = 0;
    var previous_ticks = [_]u32{ 0, 0 };
    var deadline = cycle();
    while (true) {
        flushDisplayReport();
        if (options.console_live and !ui.service(&logger)) fail("live diagnostic service");
        _ = tasks.service(0);
        _ = @atomicRmw(u32, &progress[0], .Add, 1, .release);
        // Cycle intervals are deliberately not advertised as wall time:
        // the retained bootloader owns the initial clock configuration.
        if (cycle() -% deadline < 2_000_000) continue;
        deadline = cycle();
        const peer = tasks.report(1);
        const current = @atomicLoad(u32, &progress[1], .acquire) +% peer.progress[0] +% peer.progress[1];
        if (current == previous or @atomicLoad(u32, &exceptions[1], .acquire) != 1)
            fail("CPU1 progress/exception");
        previous = current;
        rounds +%= 1;
        if (rounds != 1 and rounds % 10 != 0) continue;
        const local = tasks.report(0);
        const heartbeat = .{
            .round = rounds,
            .cpu0 = @atomicLoad(u32, &progress[0], .acquire) +% local.progress[0] +% local.progress[1],
            .cpu1 = current,
            .ticks0 = @atomicLoad(u32, &ticks[0], .acquire),
            .ticks1 = @atomicLoad(u32, &ticks[1], .acquire),
        };
        logger.record("NIHOS_NATIVE_HEARTBEAT", null, .{ "round", "cpu0", "cpu1", "ticks0", "ticks1" }, &heartbeat);
        if (rounds % 100 == 0) {
            taskReport(0);
            taskReport(1);
            for (0..2) |hart| {
                const count = @atomicLoad(u32, &ticks[hart], .acquire);
                if (count -% previous_ticks[hart] == 0 or (rounds == 300 and count < 100))
                    fail("timer progress");
                previous_ticks[hart] = count;
            }
            printBoot("NIHOS_NATIVE_SMP_PASS rounds=100 timers=both rtos=none\n");
            if (rounds == 300) {
                printBoot("NIHOS_NATIVE_SOAK_PASS rounds=300 timers=both rtos=none\n");
                tasks.ipi.request();
                while (!tasks.ipi.done()) tasks.idleOnce(0);
                if (options.storage_service and !options.fatfs_native) {
                    runStorageTasks(0);
                    const report = storage_runtime.finish();
                    logger.record("NIHOS_NATIVE_STORAGE_SERVICE", null, .{ "status", "requests", "responses", "queue_full", "rejected", "bytes", "crc", "owner", "exit_seen", "released", "stale_rejected", "owner_stack", "client_stack", "peer_polls", "elapsed_us", "clock_ok", "fs_cleared", "ipc_cleared", "forced_exit", "inflight_completed", "discarded_requests", "discarded_responses", "rebound", "replacement_owner", "old_epoch_rejected", "old_reply_rejected", "old_handle_rejected", "old_exit_rejected", "replacement_exit", "replacement_bytes", "replacement_crc" }, &report);
                }
                if (options.sqlite) runSqlProbe();
                tasks.floating.quiesce(0);
                if (!flash_records.finish(0)) fail("CPU0 Flash records finish");
                if (!tasks.memory.stacks.finish(0)) fail("CPU0 stack bank finish");
                if (!tasks.memory.finish()) fail("CPU0 memory finish");
                const started = cycle();
                while (tasks.floating.report(1).confirmed != 1 or tasks.memory.report(1).confirmed != 1) {
                    if (cycle() -% started > 100_000_000) fail("CPU1 final publication timeout");
                }
                if (options.high_sram) {
                    const high = tasks.memory.high.result();
                    logger.record("NIHOS_NATIVE_HIGH_SRAM", null, .{ "status", "bytes", "passes", "reads", "writes", "peer_reads", "peer_writes", "owner_reads", "heap_bytes", "free_bytes", "guards", "rejected", "checks0", "checks1", "checks2", "checks3", "recovered" }, &high);
                    const vm = tasks.memory.high.vmResult();
                    logger.record("NIHOS_NATIVE_PAGE_LEASE", null, .{ "status", "start", "bytes", "requested4", "charged4", "requested8", "charged8", "reads", "writes", "boundary_ok", "recovered" }, &vm);
                }
                ipiReport(0);
                ipiReport(1);
                printBoot("NIHOS_NATIVE_IPI_IDLE_PASS exchanges=64 timer_fallback=none\n");
                floatingReport(0);
                floatingReport(1);
                memoryReport(0);
                memoryReport(1);
                externalMemoryReport(0);
                externalMemoryReport(1);
                heapReport(0);
                heapReport(1);
                resourceReport(0);
                resourceReport(1);
                stackReport(0);
                stackReport(1);
                flashReport(0);
                flashReport(1);
                if (options.broker) {
                    const waited = cycle();
                    while (!broker_runtime.quiet()) {
                        if (cycle() -% waited > 1_000_000_000) fail("broker peer quiescence");
                    }
                    if (!tasks.memory.retireForBroker()) fail("broker heap retirement");
                    broker_runtime.init(sd_crc);
                    const began = cycle();
                    while (!broker_runtime.done()) {
                        _ = tasks.service(0);
                        broker_runtime.poll();
                        if (tasks.calls.yieldNow() != 0) fail("broker owner yield");
                        if (cycle() -% began > 2_000_000_000) fail("broker cleanup timeout");
                    }
                    const b = broker_runtime.finish();
                    logger.record("NIHOS_NATIVE_BROKER", null, .{ "status", "old_api_denied", "metadata", "internal_bytes", "internal_free", "external_bytes", "external_free", "internal_floor", "external_floor", "requested4", "charged4", "requested8", "charged8", "client", "replacement", "requests", "responses", "rejected", "exits", "reaped", "pin_waited", "borrow_completed", "stale_identity", "stale_lease", "guards", "recovered", "client_stack", "forced_client", "after_forced", "forced_exit", "io_issued", "io_completed", "io_bytes", "io_crc", "expected_crc", "pinned_after_kill", "completion_after_exit", "discarded_responses", "io_clock_acquired", "io_clock_released" }, &b);
                    runIoLifetimes(sd_crc);
                    if (options.fatfs_native) runFatFsTasks();
                    if (options.fatfs_sd and !options.fatfs_sd_rpc) runFatFsCard();
                }
                printBoot(if (tasks.floating.enabled) "NIHOS_NATIVE_FP_PASS floating=1\n" else "NIHOS_NATIVE_FP_PASS floating=0\n");
                stageComplete(.cores);
                if (options.card_check) {
                    // Scheduler/CPU1 are quiescent. CPU0 owns both the touch
                    // I2C bus and USB; no UI or card PIN submission is enabled.
                    reg(0x20801040).* = 0;
                    reg(0x500d6000 + 46 * 4).* = 0;
                    timer(0).stop();
                    asm volatile ("fence iorw, iorw" ::: .{ .memory = true });
                    print("NIHOS_NATIVE_CARD_CHECK_START pin_enabled=0\n");
                    const readiness = @import("card_probe.zig").run(timer(0), display_panel);
                    logger.record("NIHOS_NATIVE_CARD_CHECK", null, .{ "status", "stage", "usb", "card", "remaining", "card_fault", "poweroff", "dma_erased", "pin_data_sent", "touch", "width", "height", "slots", "samples", "fresh", "releases", "contacts", "max_contacts", "last_type", "last_flags", "last_error", "last_parameter", "last_bytes", "vbus_off" }, &readiness);
                }
                if (options.display_scanout) {
                    if (options.console_live) {
                        stageBegin(.console);
                        stageComplete(.console);
                        ui.report(&logger);
                        ui.liveReport(&logger, true);
                    } else {
                        startDisplay(timer(0), display_panel, false);
                        showDiagnosticSnapshot();
                        if (options.card_scene_exercise) @import("card_auto.zig").exercise(timer(0), display_panel, AutoLog{}) else if (options.card_auto) @import("card_auto.zig").run(timer(0), display_panel, AutoLog{}) else if (options.card_read) @import("card_read.zig").run(timer(0), display_panel, CardReadLog{});
                        if (options.touch_check) @import("touch_probe.zig").run(timer(0), display_panel, TouchLog{});
                        if (options.keypad_demo) @import("keypad_probe.zig").run(timer(0), display_panel, KeypadLog{});
                    }
                }
                if (options.graphics) {
                    const result = tasks.runGraphics(timer(0)) orelse fail("native graphics fixture");
                    if (!tasks.graphics.exchange.composer.contextAllowed()) fail("graphics report context");
                    graphicsReport(&result);
                    if (!tasks.graphics.exchange.releaseArchive()) fail("graphics archive release");
                    const queues = tasks.graphics.exchange.queue_metrics;
                    logger.record("NIHOS_NATIVE_GRAPHICS_QUEUE", null, .{ "capacity", "metadata_bytes", "payload_bytes", "binding_rejected", "full_rejected", "detached", "live_payloads", "closed_rejected", "requests_metadata", "replies_metadata", "request_payload", "reply_payload" }, &queues);
                    const archive = tasks.graphics.exchange.archive_metrics;
                    logger.record("NIHOS_NATIVE_GRAPHICS_ARCHIVE", null, .{ "logical_bytes", "charge", "live_charge", "before", "after" }, &archive);
                    tasks.graphics.stack.scratch();
                    graphicsReport(null);
                    print("NIHOS_NATIVE_GRAPHICS_PASS\n");
                }
                while (true) {
                    flushDisplayReport();
                    if (options.console_live and !ui.service(&logger)) fail("live diagnostic idle");
                    asm volatile ("wfi" ::: .{ .memory = true });
                }
            }
        }
    }
}

fn normalReady() noreturn {
    const started = ui.timer().counter() orelse fail("boot health clock");
    while (@atomicLoad(u32, &progress[1], .acquire) == 0) {
        if ((ui.timer().counter() orelse fail("boot health clock")) - started > 250_000) fail("CPU1 ready timeout");
        if (!ui.service(&logger)) fail("CPU1 ready display");
    }
    tasks.ipi.bell(1).raise();
    while (@atomicLoad(u32, &ticks[0], .acquire) == 0 or
        @atomicLoad(u32, &ticks[1], .acquire) == 0 or
        @atomicLoad(u32, &boot_ipi[0], .acquire) == 0 or
        @atomicLoad(u32, &boot_ipi[1], .acquire) == 0)
    {
        if ((ui.timer().counter() orelse fail("boot health clock")) - started > 250_000) fail("boot health timeout");
        if (!ui.service(&logger)) fail("boot health display");
    }
    if (@atomicLoad(u32, &exceptions[1], .acquire) != 1) fail("CPU1 exception return");
    const health = .{ .cpu0_ticks = @atomicLoad(u32, &ticks[0], .acquire), .cpu1_ticks = @atomicLoad(u32, &ticks[1], .acquire), .ipi0 = @atomicLoad(u32, &boot_ipi[0], .acquire), .ipi1 = @atomicLoad(u32, &boot_ipi[1], .acquire) };
    logger.record("NIHOS_NATIVE_BOOT_HEALTH", null, .{ "cpu0_ticks", "cpu1_ticks", "ipi0", "ipi1" }, &health);
    stageComplete(.cores);
    stageBegin(.console);
    stageComplete(.console);
    if (options.console_live) {
        ui.report(&logger);
        ui.liveReport(&logger, true);
        if (!ui.startSession(&logger)) fail("launcher startup");
    }
    if (options.boot_test != 0) {
        const ready = .{ .wait_us = @as(u32, @intCast((ui.timer().counter() orelse fail("ready clock")) - started)) };
        logger.record("NIHOS_NATIVE_NORMAL_READY", null, .{"wait_us"}, &ready);
    }
    if (normal_storage) normal_fs.begin(storageClient());
    var idle_checked = false;
    while (true) {
        if (options.boot_test != 0 and !idle_checked and (ui.timer().counter() orelse fail("idle clock")) - started >= 200_000) {
            for (0..2) |core| {
                const hart: u32 = @intCast(core);
                const state = tasks.report(hart);
                const idle = .{ .hart = hart, .ticks = state.ticks, .work0 = state.progress[0], .work1 = state.progress[1], .switches = state.switches, .calls = state.calls, .reaped = state.reaped, .sleeps = state.sleeps };
                logger.record("NIHOS_NATIVE_NORMAL_IDLE", null, .{ "hart", "ticks", "work0", "work1", "switches", "calls", "reaped", "sleeps" }, &idle);
            }
            printBoot("NIHOS_NATIVE_NORMAL_IDLE_PASS headless=1 evidence=emulator\n");
            idle_checked = true;
        }
        flushDisplayReport();
        serviceNetwork();
        serviceStorage();
        if (!ui.service(&logger)) fail("normal console idle");
        tasks.idleOnce(0);
    }
}

const ForegroundTimerIo = struct {
    pub fn maskInterrupts(_: @This()) u32 {
        return asm volatile ("csrrci %[value],mstatus,8"
            : [value] "=r" (-> u32),
            :
            : .{ .memory = true });
    }
    pub fn restoreInterrupts(_: @This(), previous: u32) void {
        if (previous & 8 != 0) asm volatile ("csrsi mstatus,8" ::: .{ .memory = true });
    }
    pub fn write(_: @This(), address: u32, value: u32) void {
        reg(address).* = value;
    }
    pub fn fence(_: @This()) void {
        asm volatile ("fence iorw,iorw" ::: .{ .memory = true });
    }
};

noinline fn startDisplay(clock: timer_group.Timer, display_panel: u32, early: bool) linksection(if (options.card_read) ".flash.text.card" else ".text") void {
    stageBegin(.display_scanout);
    if (!early and !options.console_live) @import("foreground_timer.zig").retire(ForegroundTimerIo{}, clock);
    const display = display_service.runtime;
    if (options.card_read) card_boot.paint() catch fail("card boot image");
    const screen = display.start(clock, display_panel, options.display_white, options.display_pattern, options.display_sram);
    if (screen.status == 1) {
        if (early) clearInterruptRoutes(0);
        routeDisplay();
        if (early) asm volatile ("csrsi mstatus, 8" ::: .{ .memory = true });
    }
    logger.record("NIHOS_NATIVE_DISPLAY_SCANOUT", null, .{ "status", "stage", "error_code", "panel", "commands", "last_command", "frames", "fault", "event", "backlight", "dpi_mhz", "lane_mbps", "cleanup", "dsi_error0", "dsi_error1", "dma_error", "bridge_error", "start_code", "prime_depth", "bl_latch", "bl_enable", "bl_level", "bl_mux", "bl_matrix", "white" }, &screen);
    logger.record("NIHOS_NATIVE_DISPLAY_SOURCE", null, .{ "sram", "source", "dma_source", "dma_control", "word" }, &screen);
    const portrait = options.display_tile or options.card_read or options.keypad_demo or options.canvas_demo;
    const composition: extern struct { logical_width: u32, logical_height: u32, rotation: u32 } = .{ .logical_width = if (portrait) @as(u32, 720) else 1280, .logical_height = if (portrait) @as(u32, 1280) else 720, .rotation = if (portrait) @as(u32, 0) else 1 };
    logger.record("NIHOS_NATIVE_DISPLAY_LAYOUT", null, .{ "logical_width", "logical_height", "rotation" }, &composition);
    if (options.canvas_demo and screen.status == 1) {
        const canvas_report = .{ .checksum = display_service.canvas_pattern.expected_checksum, .frames = screen.frames };
        logger.record("NIHOS_NATIVE_CANVAS_PATTERN", null, .{ "checksum", "frames" }, &canvas_report);
    }
    const selected = @import("tab5_panels").refreshProfile(display_panel, options.display_hz) orelse fail("display timing");
    const rates = .{ .pixel_hz = selected.dpi_mhz * 1_000_000, .refresh_millihz = @import("tab5_panels").refreshMilliHz(selected), .htotal = 720 + selected.hbp + selected.hsw + selected.hfp, .vtotal = 1280 + selected.vbp + selected.vsw + selected.vfp };
    if (options.display_sram or options.psram_200) logger.record("NIHOS_NATIVE_DISPLAY_TIMING", null, .{ "pixel_hz", "refresh_millihz", "htotal", "vtotal" }, &rates);
    logger.record("NIHOS_NATIVE_DISPLAY_LEASE", null, .{ "lease_start", "lease_bytes", "nodes" }, &screen);
    if (options.keypad_demo or options.card_read) {
        logger.record("NIHOS_NATIVE_KEYPAD_STORAGE", null, .{ "font_low", "font_low_bytes", "pixel_bytes" }, &screen);
        logger.record("NIHOS_NATIVE_DISPLAY_MEMORY", null, .{ "pool0_start", "pool0_bytes", "pool1_start", "pool1_bytes" }, &screen);
    }
    if (screen.status != 1) {
        if (options.card_auto) {
            _ = @import("card_auto.zig").emergency();
        } else if (options.card_read) @import("card_read.zig").abort();
        fail("display scanout startup");
    }
    if (options.card_read) {
        const splash = card_boot.report(1);
        @call(.always_inline, @TypeOf(logger).record, .{ &logger, "NIHOS_NATIVE_CARD_BOOT", @as(?u32, null), .{ "stage", "frames", "checked", "mismatches" }, &splash });
        if (splash.mismatches != 0) fail("card splash pixels");
        card_boot.finish(clock, display_panel) catch |err| {
            if (options.card_auto) {
                _ = @import("card_auto.zig").emergency();
            } else {
                @import("card_read.zig").abort();
                _ = display.emergency();
            }
            print("NIHOS_NATIVE_CARD_BOOT_FAIL ");
            print(@errorName(err));
            print("\n");
            fail("card boot preparation; no PIN sent");
        };
        if (options.card_photo and !options.card_auto) CardReadLog.photoPreflight();
        const ready = card_boot.report(2);
        @call(.always_inline, @TypeOf(logger).record, .{ &logger, "NIHOS_NATIVE_CARD_BOOT", @as(?u32, null), .{ "stage", "frames", "checked", "mismatches" }, &ready });
        if (ready.mismatches != 0) fail("card ready pixels");
    }
    stageComplete(.display_scanout);
}
const TouchLog = struct {
    pub fn refresh(_: TouchLog, report: *const @import("display_service").runtime.Report) void {
        if (report.frames >= 32 and !display_refresh_reported) {
            display_refresh_reported = true;
            logger.record("NIHOS_NATIVE_DISPLAY_IRQ_PASS", null, .{ "frames", "fault", "event", "dsi_error0", "dsi_error1", "dma_error", "bridge_error" }, report);
        }
    }
    pub fn start(_: TouchLog, report: *const @import("touch_probe.zig").Report) void {
        logger.record("NIHOS_NATIVE_TOUCH_START", null, .{ "pin_enabled", "width", "height", "slots", "vbus_off" }, report);
    }
    pub fn event(_: TouchLog, report: *const @import("touch_probe.zig").Event) void {
        logger.record("NIHOS_NATIVE_TOUCH_EVENT", null, .{ "contacts", "x", "y", "color", "inferred_release" }, report);
    }
    pub fn finish(_: TouchLog, report: *const @import("touch_probe.zig").Report) void {
        logger.record("NIHOS_NATIVE_TOUCH_CHECK", null, .{ "status", "pin_enabled", "width", "height", "slots", "samples", "contacts", "max_contacts", "quadrants", "explicit_releases", "inferred_releases", "updates", "errors", "vbus_off", "frames" }, report);
    }
};

const KeypadLog = struct {
    pub fn refresh(_: KeypadLog, report: *const @import("display_service").runtime.Report) void {
        TouchLog.refresh(.{}, report);
    }
    pub fn start(_: KeypadLog, report: *const @import("keypad_probe.zig").Report) void {
        logger.record("NIHOS_NATIVE_KEYPAD_START", null, .{ "pin_enabled", "vbus_off" }, report);
    }
    pub fn event(_: KeypadLog, report: *const @import("keypad_probe.zig").Event) void {
        logger.record("NIHOS_NATIVE_KEYPAD_EVENT", null, .{ "effect", "count" }, report);
    }
    pub fn finish(_: KeypadLog, report: *const @import("keypad_probe.zig").Report) void {
        logger.record("NIHOS_NATIVE_KEYPAD_CHECK", null, .{ "status", "pin_enabled", "vbus_off", "samples", "increments", "erases", "cancels", "confirms", "full", "updates", "retries", "shown_mask", "errors", "frames" }, report);
    }
};

const CardReadLog = struct {
    pub fn displayTest(_: CardReadLog, frames: u32) void {
        const report: struct { frames: u32, verifies: u32 } = .{ .frames = frames, .verifies = @import("card_read.zig").diagnostic().verifies };
        logger.record("NIHOS_NATIVE_CARD_DISPLAY_TEST", null, .{ "frames", "verifies" }, &report);
    }
    pub fn photoPreflight() void {
        logger.record("NIHOS_NATIVE_PHOTO_PREFLIGHT", null, .{ "selftest", "error_code", "stack_used", "arena_bytes", "surface_sw", "surface_counter" }, &@import("photo_runtime.zig").report);
    }
    pub fn startTouch(_: CardReadLog, report: *const @import("card_read.zig").Report) void {
        const diagnostic = @import("card_read.zig").diagnostic();
        const counters: struct { input_remaining: u32, surface_remaining: u32, verifies: u32, surface_verifies: u32 } = .{ .input_remaining = report.remaining_before, .surface_remaining = @import("photo_runtime.zig").report.surface_counter, .verifies = diagnostic.verifies, .surface_verifies = diagnostic.surface_verifies };
        logger.record("NIHOS_NATIVE_CARD_COUNTERS", null, .{ "input_remaining", "surface_remaining", "verifies", "surface_verifies" }, &counters);
        logger.record("NIHOS_NATIVE_CARD_READ_START_TOUCH", null, .{ "photo_enabled", "preflight_cut" }, report);
    }

    pub fn refresh(_: CardReadLog, report: *const @import("display_service").runtime.Report) void {
        TouchLog.refresh(.{}, report);
    }
    pub fn ready(_: CardReadLog, report: *const @import("card_read.zig").Report) void {
        logger.record("NIHOS_NATIVE_CARD_READ_READY", null, .{ "remaining_before", "verifies", "preflight_cut" }, report);
    }
    pub fn result(_: CardReadLog, report: *const @import("card_read.zig").Report) void {
        if (options.card_photo) logger.record("NIHOS_NATIVE_PHOTO_RESULT", null, .{ "photo_enabled", "surface_verifies", "photo_decoded", "photo_error" }, report);
        logger.record("NIHOS_NATIVE_CARD_READ_RESULT", null, .{ "status", "fault", "remaining_before", "remaining_after", "verifies", "cleanup", "vbus_off", "attributes", "preflight_cut" }, report);
    }
    pub fn phase(_: CardReadLog, report: *const @import("card_read.zig").Report) void {
        logger.record("NIHOS_NATIVE_CARD_READ_PHASE", null, .{ "failed_state", "card_sw", "timeout", "verifies", "surface_verifies" }, report);
    }
    pub fn finish(_: CardReadLog, report: *const @import("card_read.zig").Report) void {
        logger.record("NIHOS_NATIVE_CARD_OVERVIEW", null, .{ "shown", "truncated", "missing_glyphs", "photo_enabled", "photo_decoded" }, report);
        if (options.card_photo) logger.record("NIHOS_NATIVE_PHOTO_CLEANUP", null, .{ "decoded", "stack_used", "erased" }, &@import("photo_runtime.zig").report);
        logger.record("NIHOS_NATIVE_CARD_READ_DONE", null, .{ "status", "fault", "remaining_before", "remaining_after", "verifies", "cleanup", "vbus_off", "attributes", "preflight_cut", "shown", "missing_glyphs", "erased" }, report);
    }
};

const AutoLog = struct {
    fn notice() void {
        const report = @import("display_service").runtime.noticeSnapshot();
        logger.record("NIHOS_NATIVE_CARD_AUTO_DISPLAY", null, .{ "swaps", "panel_starts", "backlight_offs", "frames", "backlight", "fault" }, &report);
    }
    pub fn refresh(_: AutoLog, report: *const @import("display_service").runtime.Report) void {
        TouchLog.refresh(.{}, report);
    }
    pub fn boot(_: AutoLog, report: *const @import("photo_runtime.zig").Report) void {
        logger.record("NIHOS_NATIVE_CARD_AUTO_BOOT", null, .{ "selftest", "error_code", "stack_used", "erased", "crypto_selftest", "crypto_stack" }, report);
        notice();
    }
    pub fn detected(_: AutoLog, report: *const @import("card_auto.zig").Report) void {
        logger.record("NIHOS_NATIVE_CARD_AUTO_DETECTED", null, .{ "job", "kind", "pin1_verifies", "pin2_verifies", "cleanup", "erased" }, report);
        notice();
    }
    pub fn selected(_: AutoLog, report: *const @import("card_auto.zig").Report) void {
        logger.record("NIHOS_NATIVE_CARD_AUTO_SELECTED", null, .{ "job", "kind" }, report);
    }
    pub fn prompt(_: AutoLog, report: *const @import("card_auto.zig").Report) void {
        logger.record("NIHOS_NATIVE_CARD_AUTO_PROMPT", null, .{ "job", "kind", "pin_index", "pin1_remaining", "pin2_remaining", "pin1_verifies", "pin2_verifies" }, report);
        notice();
    }
    pub fn result(_: AutoLog, report: *const @import("card_auto.zig").Report) void {
        logger.record("NIHOS_NATIVE_CARD_AUTO_RESULT", null, .{ "job", "kind", "state", "fault", "sw", "pin1_verifies", "pin2_verifies", "fields", "photo_decoded", "photo_error", "shown", "missing", "truncated", "cleanup", "verification", "changes" }, report);
        notice();
    }
    pub fn scene(_: AutoLog, step: u32) void {
        logger.record("NIHOS_NATIVE_CARD_SCENE", null, .{"step"}, &.{ .step = step });
        const current = display_service.runtime.sceneSnapshot();
        logger.record("NIHOS_NATIVE_CARD_SCENE_HANDOFF", null, .{ "updates", "max_pause_us" }, &current);
        notice();
    }
    pub fn sceneFailure(_: AutoLog, step: u32, name: []const u8) void {
        const handoff = display_service.runtime.sceneSnapshot();
        logger.record("NIHOS_NATIVE_CARD_SCENE_FAILURE", null, .{ "stage", "error_code", "updates", "max_pause_us" }, &handoff);
        const status = asm volatile ("csrr %[value],mstatus"
            : [value] "=r" (-> u32),
        );
        logger.record("NIHOS_NATIVE_CARD_SCENE_CONTEXT", null, .{ "step", "irq_enabled" }, &.{ .step = step, .irq_enabled = (status & 8) >> 3 });
        const scanout = display_service.runtime.snapshot();
        logger.record("NIHOS_NATIVE_CARD_SCENE_SCANOUT", null, .{ "frames", "fault", "event", "dsi_error0", "dsi_error1", "dma_error", "bridge_error" }, &scanout);
        notice();
        print("NIHOS_NATIVE_FAIL scene exercise ");
        print(name);
        print("\n");
    }
    pub fn sceneReady(_: AutoLog) void {
        const ready = struct { manual: u32 }{ .manual = 1 };
        logger.record("NIHOS_NATIVE_CARD_SCENE_READY", null, .{"manual"}, &ready);
        notice();
    }
    pub fn scenePixels(_: AutoLog, step: u32, mismatches: u32) void {
        logger.record("NIHOS_NATIVE_CARD_SCENE_PIXELS", null, .{ "step", "mismatches" }, &.{ .step = step, .mismatches = mismatches });
    }
    pub fn finish(_: AutoLog, report: *const @import("card_auto.zig").Report) void {
        logger.record("NIHOS_NATIVE_CARD_AUTO_DONE", null, .{ "job", "kind", "fault", "pin1_verifies", "pin2_verifies", "fields", "photo_decoded", "shown", "missing", "truncated", "cleanup", "erased", "verification", "changes" }, report);
    }
    pub fn abort(_: AutoLog, report: *const @import("card_auto.zig").Report) void {
        logger.record("NIHOS_NATIVE_CARD_AUTO_ABORT", null, .{ "job", "kind", "state", "fault", "pin1_verifies", "pin2_verifies" }, report);
    }
    pub fn removed(_: AutoLog, job: u32) void {
        const report: struct { job: u32 } = .{ .job = job };
        logger.record("NIHOS_NATIVE_CARD_AUTO_REMOVED", null, .{"job"}, &report);
        notice();
    }
};

var time_report_at: u64 = 0;
noinline fn serviceTime() linksection(".flash.text.time") void {
    if (network.takeTime()) |sample| board_devices.applyNetworkTime(sample.unix_us, sample.received);
    const now = ui.timer().counter() orelse return;
    if (now < time_report_at) return;
    time_report_at = now + 5_000_000;
    const ntp = network.timeSnapshot();
    logger.record("NIHOS_NATIVE_NTP", null, .{ "phase", "attempts", "replies", "rejected", "failures", "server", "stratum", "rtt_us", "unix_high", "unix_low" }, &ntp);
    const clock = board_devices.timeSnapshot();
    logger.record("NIHOS_NATIVE_RTC_SYNC", null, .{ "applied", "failures", "error_code", "unix_high", "unix_low" }, &clock);
}

// Only immutable completed qualification records are emitted here. The SRAM
// caller gates CPU0 bootstrap/MIE; task reaping and archive retirement stay SRAM.
noinline fn graphicsReport(result: ?*const tasks.graphics.Report) linksection(".flash.text.render") void {
    const completed = result orelse {
        const stack_loan = tasks.graphics.stack.metrics;
        logger.record("NIHOS_NATIVE_GRAPHICS_STACK_LOAN", null, .{ "bytes", "loans", "guards", "busy", "stale", "premature", "returned", "before_hash", "after_hash", "paint_pc", "start", "end" }, &stack_loan);
        return;
    };
    logger.record("NIHOS_NATIVE_GRAPHICS", null, .{ "status", "owner", "runs", "library_pc", "heap_before", "heap_after", "raw_peak", "retained", "stack_low", "stack_high", "observed_used", "captures", "render_captures", "bootstrap_progress", "record_peak", "controller_bytes", "allocations", "releases", "foreign_rejected", "irq_rejected", "forged_rejected" }, completed);
    logger.record("NIHOS_NATIVE_GRAPHICS_CLIENTS", null, .{ "client_cycles", "idle_retained", "idle_captures", "idle_progress" }, completed);
    const exchange = tasks.graphics.exchange.report();
    logger.record("NIHOS_NATIVE_GRAPHICS_EXCHANGE", null, .{ "sent", "received", "replies", "waits", "blocked_ticks", "idle_runtime", "stop_ack", "terminal_gap", "copied_inputs", "text_success", "text_failed", "copied_outputs", "queue_bytes" }, &exchange);
    const raster = tasks.graphics.exchange.raster.metrics;
    logger.record("NIHOS_NATIVE_GRAPHICS_RASTER", null, .{ "created", "discarded", "published", "reclaimed", "live_charge", "peak_charge", "held_ticks", "stale_rejected", "foreign_rejected" }, &raster);
    const placement = tasks.graphics.exchange.composer.placement;
    logger.record("NIHOS_NATIVE_GRAPHICS_PLACEMENT", null, .{ "paint_pc", "draw_pc", "frames", "draws", "context_checks", "irq_rejected", "active_ticks", "flash_ticks", "trap_pc" }, &placement);
    const composition = tasks.graphics.exchange.composer.metrics;
    logger.record("NIHOS_NATIVE_GRAPHICS_SURFACE", null, .{ "frames", "blits", "clipped", "guards", "rejected", "peak_charge", "live_charge" }, &composition);
    const wrapped = tasks.graphics.exchange.composer.wrap_metrics;
    logger.record("NIHOS_NATIVE_GRAPHICS_WRAP", null, .{ "frames", "clusters", "lines", "wrapped_runs", "transitions", "clipped" }, &wrapped);
    const policy_result = tasks.graphics.exchange.composer.policy_metrics;
    logger.record("NIHOS_NATIVE_GRAPHICS_KINSOKU", null, .{ "frames", "spans", "joined", "lines", "transitions", "clipped" }, &policy_result);
    const source_result = tasks.graphics.exchange.composer.source_metrics;
    logger.record("NIHOS_NATIVE_GRAPHICS_SOURCE", null, .{ "input_pc", "prepare_pc", "verify_pc", "staged", "maps", "rejected", "edited", "poisoned", "echoed", "stale", "content", "annotations", "map_mutations", "wrong_reply" }, &source_result);
    const ruby_result = tasks.graphics.exchange.composer.ruby_metrics;
    logger.record("NIHOS_NATIVE_GRAPHICS_RUBY", null, .{ "frames", "groups", "moved", "wide", "units", "joins", "lines", "clipped", "plan_bytes", "scratch_bytes" }, &ruby_result);
    for (tasks.graphics.exchange.textResults()) |*reply| {
        const text_result = .{ .id = reply.id, .runs = reply.runs, .hash = reply.hashes[0], .outcome = @as(u32, @backingInt(reply.outcome)), .glyph_count = reply.output.count, .pixel_bytes = reply.output.raster_bytes, .pixel_hash = reply.pixel_hash, .source_hash = reply.source_hash, .surface_hash = reply.composition.surface_hash, .wrap_hash = reply.composition.wrap_hash, .policy_hash = reply.composition.policy_hash, .ruby_hash = reply.composition.ruby_hash };
        logger.record("NIHOS_NATIVE_GRAPHICS_TEXT", null, .{ "id", "runs", "hash", "outcome", "glyph_count", "pixel_bytes", "pixel_hash", "source_hash", "surface_hash", "wrap_hash", "policy_hash", "ruby_hash" }, &text_result);
        for (reply.output.glyphs[0..reply.output.count], 0..) |g, index| {
            const glyph = .{ .request = reply.id, .index = @as(u32, @intCast(index)), .glyph_id = g.id, .cluster = g.cluster, .run = g.run, .pixels = g.pixels, .x_advance = @as(u32, @bitCast(g.x_advance)), .y_advance = @as(u32, @bitCast(g.y_advance)), .x_offset = @as(u32, @bitCast(g.x_offset)), .y_offset = @as(u32, @bitCast(g.y_offset)), .left = @as(u32, @bitCast(g.left)), .top = @as(u32, @bitCast(g.top)), .width = g.width, .height = g.height, .pixel_offset = g.pixel_offset };
            logger.record("NIHOS_NATIVE_GRAPHICS_GLYPH", null, .{ "request", "index", "glyph_id", "cluster", "run", "pixels", "x_advance", "y_advance", "x_offset", "y_offset", "left", "top", "width", "height", "pixel_offset" }, &glyph);
        }
    }
    const hashes = tasks.graphics.hashes();
    for (hashes, 0..) |hash, index| {
        const item = .{ .index = @as(u32, @intCast(index)), .hash = hash };
        logger.record("NIHOS_NATIVE_GRAPHICS_HASH", null, .{ "index", "hash" }, &item);
    }
}

noinline fn runFatFsTasks() linksection(".flash.text.storage") void {
    if (options.fatfs_sd_rpc) print("NIHOS_FATFS_SD_READY\n");
    storage_runtime.init();
    runStorageTasks(0);
    const report = storage_runtime.finish();
    logger.record("NIHOS_NATIVE_FATFS_RPC", null, @import("fatfs_service_abi.zig").fields, &report);
    if (options.fatfs_sd_rpc) {
        const card = @import("fatfs_card_abi.zig");
        var result = card.Report{};
        card.nih_fatfs_card_rpc_report(&result);
        logger.record("NIHOS_NATIVE_FATFS_CARD", null, card.fields, &result);
        const Stack = struct { used: u32, preserved: u32 };
        const stack = Stack{ .used = @max(report.owner_stack, report.client_stack), .preserved = 1 };
        logger.record("NIHOS_NATIVE_FATFS_CARD_STACK", null, .{ "used", "preserved" }, &stack);
    }
}
noinline fn runFatFsCard() linksection(".flash.text.storage") void {
    const card = @import("fatfs_card_abi.zig");
    if (!options.fatfs_sd_direct) {
        const began = timer(0).counter() orelse fail("card wait clock");
        var drained: u32 = 0;
        while (nih_boot_capture_getc() >= 0) {
            drained += 1;
            if (drained >= 1024) fail("card stale input flood");
        }
        print("NIHOS_FATFS_SD_READY\n");
        while (nih_boot_capture_getc() != 'S') {
            const now = timer(0).counter() orelse fail("card wait clock");
            if (now - began > 300_000_000) fail("FAT/exFAT card swap timeout");
        }
    } else print("NIHOS_FATFS_SD_READY\n");
    var report = card.Report{};
    const guard: *volatile [4]u32 = @ptrCast(@alignCast(&__stack0_bottom));
    var saved: [4]u32 = undefined;
    for (0..4) |i| saved[i] = guard[i];
    const low = @intFromPtr(&__stack0_bottom) + 16;
    const painted = nih_sqlite_stack_paint(low);
    if (card.nih_fatfs_card_attempt(&report) != 1) fail("FAT/exFAT card read");
    for (0..4) |i| if (saved[i] != guard[i]) fail("card stack guard");
    var first = low;
    while (first < painted and @as(*volatile u32, @ptrFromInt(first)).* == 0x5a7ec319) : (first += 4) {}
    if (first <= low + 160 or first > painted) fail("card stack margin");
    const Stack = struct { used: u32, preserved: u32 };
    const stack = Stack{ .used = @intFromPtr(&__stack0_top) - first, .preserved = 1 };
    logger.record("NIHOS_NATIVE_FATFS_CARD", null, card.fields, &report);
    logger.record("NIHOS_NATIVE_FATFS_CARD_STACK", null, .{ "used", "preserved" }, &stack);
}

fn memoryReport(hart: u32) void {
    const report = tasks.memory.report(hart);
    if (report.confirmed != 1) fail("memory publication");
    logger.record("NIHOS_NATIVE_MEMORY", hart, .{ "start", "end", "capacity", "used", "free", "checks0", "checks1", "rejected", "confirmed" }, &report);
}

fn externalMemoryReport(hart: u32) void {
    const report = tasks.memory.externalReport(hart);
    logger.record("NIHOS_NATIVE_EXTERNAL", hart, .{ "start", "end", "capacity", "used", "free", "checks0", "checks1", "rejected", "confirmed" }, &report);
}

fn heapReport(hart: u32) void {
    const report = tasks.memory.reusable.report(hart);
    logger.record("NIHOS_NATIVE_HEAP", hart, .{ "start", "end", "metadata", "capacity", "free", "live", "allocations", "frees", "rejected", "checks0", "checks1", "levels", "max_steps", "confirmed" }, &report);
}

noinline fn resourceReport(hart: u32) linksection(if (options.card_read) ".flash.text.card" else if (options.cold_flash and options.fatfs_native) ".flash.text.storage" else ".text") void {
    const report = tasks.memory.reusable.resourceReport(hart);
    logger.record("NIHOS_NATIVE_RESOURCES", hart, .{ "opened", "closed", "completed", "reclaimed", "reuses", "owned", "pending", "stale", "full", "forced", "pool_objects", "pool_rejected", "slab_objects", "slab_frees", "slab_rejected", "object_moves", "object_inplace", "object_rejected", "object_copy_bytes", "c_probes" }, &report);
}

fn flashReport(hart: u32) void {
    const report = flash_records.report(hart);
    if (report.confirmed != 1) fail("Flash record publication");
    logger.record("NIHOS_NATIVE_FLASH", hart, .{ "start", "end", "bytes", "initial", "final", "checks", "confirmed" }, &report);
}

noinline fn stackReport(hart: u32) linksection(if (options.card_read) ".flash.text.card" else ".text") void {
    const report = tasks.memory.stacks.report(hart) orelse fail("stack bank publication");
    logger.record("NIHOS_NATIVE_STACKS", hart, .{ "start", "end", "boot_start", "boot_end", "irq_start", "irq_end", "task_start", "task_end", "boot_frame", "irq_sp", "task0_frame", "task1_frame", "task2_frame", "frames", "zeroed", "confirmed" }, &report);
}
