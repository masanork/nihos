//! Independent native boot experiment: no IDF application or FreeRTOS link.
const std = @import("std");
const options = @import("native_options");
const timer_group = @import("timer_group");
const tasks = @import("native_tasks");
const native_psram = @import("psram.zig");
const record_log = @import("record_log");
const flash_records = @import("flash_records.zig");
pub const panic = std.debug.no_panic;

comptime {
    if (@sizeOf(tasks.context.IntegerContext) != tasks.memory.stacks.layout.frame_bytes)
        @compileError("stack observations must use the native integer frame ABI");
}

extern fn nih_rom_putc(u8) callconv(.c) i32;
extern fn nih_rom_set_cpu1_entry(u32) callconv(.c) void;
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
var exceptions = [_]u32{ 0, 0 };
var ticks = [_]u32{ 0, 0 };
var display_refresh_reported = false;
var initialized: u32 = 0x4e494853;

fn reg(address: usize) *volatile u32 {
    return @ptrFromInt(address);
}

noinline fn print(message: []const u8) void {
    for (message) |byte| {
        if (byte == '\n') _ = nih_rom_putc('\r');
        _ = nih_rom_putc(byte);
    }
}

const Console = struct {
    pub fn write(_: Console, message: []const u8) void {
        print(message);
    }
};
var logger = record_log.PlacedWriter(Console, ".flash.rodata.records"){ .sink = .{} };

noinline fn hex(value: u32) void {
    const digits = "0123456789abcdef";
    var shift: u5 = 28;
    while (true) {
        _ = nih_rom_putc(digits[@as(u4, @truncate(value >> shift))]);
        if (shift == 0) break;
        shift -= 4;
    }
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
    }
    print("NIHOS_NATIVE_FAIL ");
    print(reason);
    print("\n");
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

fn enableTimer(hart: u32) void {
    // CLIC MMIO is hart-local. Mask all lines, use non-vectored level 1.
    for (0..48) |line| reg(0x20801000 + line * 4).* = 0;
    reg(0x20800000).* = 3 << 1; // NLBITS = 3.
    // Clear this hart's matrix, then route TG0.T[hart] to CLIC input 16.
    const matrix = 0x500d6000 + hart * 0x800;
    // 136 matches ETS_MAX_INTR_SOURCE, including rev3's sparse new inputs.
    for (0..136) |source| reg(matrix + source * 4).* = 0;
    reg(matrix + (46 + hart) * 4).* = 16;
    reg(0x20801040).* = (0x3f << 24) | (1 << 8);
    tasks.ipi.bell(hart).acknowledge();
    reg(matrix + (79 + hart) * 4).* = 17;
    reg(0x20801044).* = (0x3f << 24) | (1 << 8);
    timer(hart).start();
    asm volatile ("fence rw, rw" ::: .{ .memory = true });
    asm volatile ("csrsi mstatus, 8" ::: .{ .memory = true });
}

export fn nih_native_dispatch(frame: *tasks.context.IntegerContext, cause: u32, hart: u32, status: u32) callconv(.c) *tasks.context.IntegerContext {
    if (hart >= 2) fail("invalid hart");
    if (!interruptStackValid(hart, frame)) fail("interrupt stack/MIE");
    const state = tasks.context.ReturnState{ .mstatus = status, .mcause = cause };
    if (options.display_scanout and hart == 0 and cause & 0x8000_0fff == 0x8000_0012) {
        const display = @import("display_runtime.zig");
        if (!display.active()) fail("unexpected display IRQ");
        display.onInterrupt();
        const observed = display.snapshot();
        if (observed.fault != 0) {
            logger.record("NIHOS_NATIVE_DISPLAY_IRQ_FAIL", null, .{ "frames", "fault", "event", "dsi_error0", "dsi_error1", "dma_error", "bridge_error" }, &observed);
            fail("display refresh");
        }
        if (observed.frames >= 32 and !display_refresh_reported and !options.touch_check and !options.keypad_demo and !options.card_read) {
            display_refresh_reported = true;
            logger.record("NIHOS_NATIVE_DISPLAY_IRQ_PASS", null, .{ "frames", "fault", "event", "dsi_error0", "dsi_error1", "dma_error", "bridge_error" }, &observed);
        }
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
    fail(reason);
}

export fn nih_native_task_failed() callconv(.c) noreturn {
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
    if (!flash_records.begin(1)) fail("CPU1 Flash records begin");
    interruptGuard(1).* = @splat(tasks.memory.stacks.layout.irq_guard);
    asm volatile ("ecall" ::: .{ .memory = true });
    if (!tasks.memory.begin()) fail("CPU1 memory begin");
    native_psram.memory.peer();
    if (!tasks.memory.beginExternal()) fail("CPU1 external memory begin");
    native_psram.memory.ownerReady(1);
    prepareTasks(1);
    enableTimer(1);
    while (true) {
        _ = tasks.service(1);
        if (tasks.ipi.done()) {
            tasks.floating.quiesce(1);
            if (!flash_records.finish(1)) fail("CPU1 Flash records finish");
            if (!tasks.memory.stacks.finish(1)) fail("CPU1 stack bank finish");
            if (!tasks.memory.finish()) fail("CPU1 memory finish");
            while (true) asm volatile ("wfi");
        }
        _ = @atomicRmw(u32, &progress[1], .Add, 1, .release);
        tasks.idleOnce(1);
    }
}

export fn nih_native_main() callconv(.c) noreturn {
    watchdogOff();
    if (!tasks.memory.stacks.begin(0)) fail("CPU0 stack bank begin");
    interruptGuard(0).* = @splat(tasks.memory.stacks.layout.irq_guard);
    print("\nNIHOS_NATIVE_BOOT backend=zig-sram rtos=none\n");
    print(if (tasks.floating.enabled) "NIHOS_NATIVE_MODE floating=1\n" else "NIHOS_NATIVE_MODE floating=0\n");
    print(if (tasks.floating.compiled) "NIHOS_NATIVE_COMPILER enabled=1\n" else "NIHOS_NATIVE_COMPILER enabled=0\n");
    if (options.sqlite) print("NIHOS_NATIVE_SQLITE_MODE enabled=1\n");
    if (options.qualification) print("NIHOS_NATIVE_QUALIFICATION enabled=1\n");
    if (options.sdmmc) print("NIHOS_NATIVE_SDMMC_MODE enabled=1\n");
    if (options.usb) print("NIHOS_NATIVE_USB_MODE enabled=1\n");
    if (options.jpki) print("NIHOS_NATIVE_JPKI_MODE pin_input=disabled\n");
    if (progress[0] != 0 or progress[1] != 0 or
        @as(*volatile u32, &initialized).* != 0x4e494853)
        fail("CRT data/BSS");
    asm volatile ("ecall" ::: .{ .memory = true });
    if (exceptions[0] != 1) fail("CPU0 exception return");
    print("NIHOS_NATIVE_CRT_PASS bss=zero data=valid ecall=returned\n");
    if (!flash_records.begin(0)) fail("CPU0 Flash records begin");
    if (!tasks.memory.prepare() or !tasks.memory.begin()) fail("CPU0 memory prepare");
    prepareTimers();
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
    if (options.sdmmc) {
        const sd = @import("sdmmc_probe.zig").run(timer(0));
        logger.record("NIHOS_NATIVE_SDMMC", null, .{ "status", "stage", "command", "interrupts", "response", "commands", "sectors_low", "sectors_high", "reads", "crc0", "crc1", "crc_middle", "crc_last", "bus_bits", "clock_khz", "writes", "error_code", "host_status", "data_words", "dma" }, &sd);
        for (0..sd.stage_count) |phase| {
            logger.record("NIHOS_NATIVE_SDMMC_STAGE", null, .{ "index", "bus_bits", "clock_khz", "scr_widths", "host_width", "divider", "reads", "crc0", "crc1", "crc_middle", "crc_last" }, &sd.stages[phase]);
            if (sd.stages[phase].samples != 0) logger.record("NIHOS_NATIVE_SDMMC_SWEEP", null, .{ "index", "samples", "digest" }, &sd.stages[phase]);
        }
        if (options.storage) {
            logger.record("NIHOS_NATIVE_STORAGE", null, .{ "status", "error_code", "passes", "block_size", "block_count", "entries", "files", "directories", "directory_digest", "file_bytes", "file_crc", "file_name_digest", "reads", "denied_writes" }, &sd.storage);
            logger.record("NIHOS_NATIVE_STORAGE_STACK", null, .{ "low", "high", "painted_to", "used", "confirmed" }, &sd.storage_stack);
            if ((sd.storage.status != 1 and sd.storage.status != 2) or sd.storage_stack.confirmed != 1) fail("storage probe");
        }
        if (!timer(0).configureOneShot(tasks.period_us)) fail("SDMMC timer return");
        if (sd.status != 1) fail("SDMMC probe");
    }
    var external_heap_start = native_psram.memory.heap_start;
    var display_panel: u32 = 0;
    var external_heap_bytes = external.mapping.bytes -| native_psram.memory.reserved_bytes;
    if (options.display) {
        const selected = @import("tab5_display").layout(external.mapping.bytes) orelse fail("display requires mapped PSRAM");
        const display = @import("display_probe.zig").run(timer(0), selected);
        logger.record("NIHOS_NATIVE_DISPLAY_PREP", null, .{ "status", "stage", "error_code", "panel", "transactions", "frame_start", "frame_bytes", "reserve_bytes", "checksum", "phy_trim", "phy_status", "scanout", "backlight" }, &display);
        if (!timer(0).configureOneShot(tasks.period_us)) fail("display timer return");
        if (display.status != 1) fail("display preparation");
        display_panel = display.panel;
        external_heap_start = selected.heap_start;
        external_heap_bytes = selected.heap_bytes;
    }
    prepareTasks(0);
    startCpu1();
    const external_smp = native_psram.exchange();
    logger.record("NIHOS_NATIVE_PSRAM_SMP", null, .{ "status", "rounds", "owner_checks", "peer_checks", "command_checks", "syncs" }, &external_smp);
    if (external_smp.status == 1 and !tasks.memory.prepareExternal(
        external_heap_start,
        external_heap_bytes,
    )) fail("external memory prepare");
    if (!tasks.memory.beginExternal()) fail("CPU0 external memory begin");
    native_psram.memory.releasePeer();
    native_psram.memory.ownerReady(0);
    enableTimer(0);
    var previous: u32 = 0;
    var rounds: u32 = 0;
    var previous_ticks = [_]u32{ 0, 0 };
    var deadline = cycle();
    while (true) {
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
            print("NIHOS_NATIVE_SMP_PASS rounds=100 timers=both rtos=none\n");
            if (rounds == 300) {
                print("NIHOS_NATIVE_SOAK_PASS rounds=300 timers=both rtos=none\n");
                tasks.ipi.request();
                while (!tasks.ipi.done()) tasks.idleOnce(0);
                if (options.sqlite) {
                    if (options.qualification) {
                        const soak = @import("sqlite_probe.zig").soak();
                        logger.record("NIHOS_NATIVE_SQLITE_SOAK", null, .{ "loops", "sessions", "queries", "heap_before", "heap_after", "max_stack", "confirmed" }, &soak);
                    }
                    const sql = @import("sqlite_probe.zig").run();
                    logger.record("NIHOS_NATIVE_SQLITE", null, .{ "status", "owner", "sessions", "queries", "open_pc", "text_start", "text_end", "rodata_start", "rodata_end", "heap_before", "heap_after", "stack_low", "stack_high", "painted_to", "observed_used", "mie" }, &sql);
                    const classes = @import("sqlite_probe.zig").classPeaks();
                    logger.record("NIHOS_NATIVE_SQLITE_CLASSES", null, .{ "c8", "c16", "c32", "c64", "c128", "c256", "c512", "c1024", "c2048", "c4096" }, &classes);
                }
                tasks.floating.quiesce(0);
                if (!flash_records.finish(0)) fail("CPU0 Flash records finish");
                if (!tasks.memory.stacks.finish(0)) fail("CPU0 stack bank finish");
                if (!tasks.memory.finish()) fail("CPU0 memory finish");
                const started = cycle();
                while (tasks.floating.report(1).confirmed != 1 or tasks.memory.report(1).confirmed != 1) {
                    if (cycle() -% started > 100_000_000) fail("CPU1 final publication timeout");
                }
                ipiReport(0);
                ipiReport(1);
                print("NIHOS_NATIVE_IPI_IDLE_PASS exchanges=64 timer_fallback=none\n");
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
                print(if (tasks.floating.enabled) "NIHOS_NATIVE_FP_PASS floating=1\n" else "NIHOS_NATIVE_FP_PASS floating=0\n");
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
                    const display = @import("display_runtime.zig");
                    // Scheduler qualification has finished. Retire its CPU0
                    // timer route before borrowing the counter for DCS waits.
                    reg(0x20801040).* = 0;
                    reg(0x500d6000 + 46 * 4).* = 0;
                    timer(0).stop();
                    asm volatile ("fence iorw, iorw" ::: .{ .memory = true });
                    if (options.card_auto) @import("card_auto.zig").prepare(timer(0), display_panel) catch {
                        fail("automatic card preparation; no PIN sent");
                    } else if (options.card_read) @import("card_read.zig").prepare(timer(0), display_panel) catch |err| {
                        if (options.card_photo and !options.card_auto) CardReadLog.photoPreflight();
                        print("NIHOS_NATIVE_CARD_READ_PREP_FAIL ");
                        print(@errorName(err));
                        print("\n");
                        fail("card read preparation; no PIN sent");
                    };
                    if (options.card_photo and !options.card_auto) CardReadLog.photoPreflight();
                    const screen = display.start(timer(0), display_panel, options.display_white, options.display_pattern, options.display_sram);
                    if (screen.status == 1) {
                        const source = display.irqSource();
                        if (source >= 136) fail("display IRQ source");
                        // Dedicated input 18, beside native timer 16 and IPI 17.
                        reg(0x500d6000 + source * 4).* = 18;
                        reg(0x20801048).* = (0x3f << 24) | (1 << 8);
                        asm volatile ("fence iorw, iorw" ::: .{ .memory = true });
                    }
                    logger.record("NIHOS_NATIVE_DISPLAY_SCANOUT", null, .{ "status", "stage", "error_code", "panel", "commands", "last_command", "frames", "fault", "event", "backlight", "dpi_mhz", "lane_mbps", "cleanup", "dsi_error0", "dsi_error1", "dma_error", "bridge_error", "start_code", "prime_depth", "bl_latch", "bl_enable", "bl_level", "bl_mux", "bl_matrix", "white" }, &screen);
                    logger.record("NIHOS_NATIVE_DISPLAY_SOURCE", null, .{ "sram", "source", "dma_source", "dma_control", "word" }, &screen);
                    logger.record("NIHOS_NATIVE_DISPLAY_LEASE", null, .{ "lease_start", "lease_bytes", "nodes" }, &screen);
                    if (options.keypad_demo or options.card_read) logger.record("NIHOS_NATIVE_KEYPAD_STORAGE", null, .{ "font_low", "font_low_bytes", "pixel_bytes" }, &screen);
                    if (screen.status != 1) {
                        if (options.card_auto) {
                            _ = @import("card_auto.zig").emergency();
                        } else if (options.card_read) @import("card_read.zig").abort();
                        fail("display scanout startup");
                    }
                    if (options.card_auto) @import("card_auto.zig").run(timer(0), display_panel, AutoLog{}) else if (options.card_read) @import("card_read.zig").run(timer(0), display_panel, CardReadLog{});
                    if (options.touch_check) @import("touch_probe.zig").run(timer(0), display_panel, TouchLog{});
                    if (options.keypad_demo) @import("keypad_probe.zig").run(timer(0), display_panel, KeypadLog{});
                }
                while (true) asm volatile ("wfi");
            }
        }
    }
}

const TouchLog = struct {
    pub fn refresh(_: TouchLog, report: *const @import("display_runtime.zig").Report) void {
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
    pub fn refresh(_: KeypadLog, report: *const @import("display_runtime.zig").Report) void {
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

fn resourceReport(hart: u32) void {
    const report = tasks.memory.reusable.resourceReport(hart);
    logger.record("NIHOS_NATIVE_RESOURCES", hart, .{ "opened", "closed", "completed", "reclaimed", "reuses", "owned", "pending", "stale", "full", "forced", "pool_objects", "pool_rejected", "slab_objects", "slab_frees", "slab_rejected", "object_moves", "object_inplace", "object_rejected", "object_copy_bytes", "c_probes" }, &report);
}

fn flashReport(hart: u32) void {
    const report = flash_records.report(hart);
    if (report.confirmed != 1) fail("Flash record publication");
    logger.record("NIHOS_NATIVE_FLASH", hart, .{ "start", "end", "bytes", "initial", "final", "checks", "confirmed" }, &report);
}

fn stackReport(hart: u32) void {
    const report = tasks.memory.stacks.report(hart) orelse fail("stack bank publication");
    logger.record("NIHOS_NATIVE_STACKS", hart, .{ "start", "end", "boot_start", "boot_end", "irq_start", "irq_end", "task_start", "task_end", "boot_frame", "irq_sp", "task0_frame", "task1_frame", "task2_frame", "frames", "zeroed", "confirmed" }, &report);
}

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

    pub fn refresh(_: CardReadLog, report: *const @import("display_runtime.zig").Report) void {
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
        const report = @import("display_runtime.zig").noticeSnapshot();
        logger.record("NIHOS_NATIVE_CARD_AUTO_DISPLAY", null, .{ "swaps", "panel_starts", "backlight_offs", "frames", "backlight", "fault" }, &report);
    }
    pub fn refresh(_: AutoLog, report: *const @import("display_runtime.zig").Report) void {
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
    }
    pub fn result(_: AutoLog, report: *const @import("card_auto.zig").Report) void {
        logger.record("NIHOS_NATIVE_CARD_AUTO_RESULT", null, .{ "job", "kind", "state", "fault", "sw", "pin1_verifies", "pin2_verifies", "fields", "photo_decoded", "photo_error", "shown", "missing", "truncated", "cleanup", "verification", "changes" }, report);
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
