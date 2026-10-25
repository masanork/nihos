//! Independent native boot experiment: no IDF application or FreeRTOS link.
const std = @import("std");
const timer_group = @import("timer_group");
pub const panic = std.debug.no_panic;

extern fn nih_rom_putc(u8) callconv(.c) i32;
extern fn nih_rom_set_cpu1_entry(u32) callconv(.c) void;
extern fn nih_native_cpu1_start() callconv(.c) void;

var progress = [_]u32{ 0, 0 };
var exceptions = [_]u32{ 0, 0 };
var ticks = [_]u32{ 0, 0 };
var initialized: u32 = 0x4e494853;

fn reg(address: usize) *volatile u32 {
    return @ptrFromInt(address);
}

fn print(message: []const u8) void {
    for (message) |byte| {
        if (byte == '\n') _ = nih_rom_putc('\r');
        _ = nih_rom_putc(byte);
    }
}

fn hex(value: u32) void {
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
        if (!channel.configure(10_000)) fail("timer configuration");
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
    timer(hart).start();
    asm volatile ("fence rw, rw" ::: .{ .memory = true });
    asm volatile ("csrsi mstatus, 8" ::: .{ .memory = true });
}

export fn nih_native_dispatch(cause: u32, pc: u32, hart: u32) callconv(.c) u32 {
    if (hart < 2 and cause & 0x8000_0fff == 11) {
        _ = @atomicRmw(u32, &exceptions[hart], .Add, 1, .release);
        return pc + 4;
    }
    if (hart < 2 and cause & 0x8000_0fff == 0x8000_0010 and timer(hart).acknowledge()) {
        _ = @atomicRmw(u32, &ticks[hart], .Add, 1, .release);
        return pc;
    }
    print("NIHOS_NATIVE_TRAP cause=");
    hex(cause);
    print(" pc=");
    hex(pc);
    print(" hart=");
    hex(hart);
    fail("unexpected trap");
}

export fn nih_native_cpu1_main() callconv(.c) noreturn {
    nih_rom_set_cpu1_entry(0);
    asm volatile ("ecall" ::: .{ .memory = true });
    enableTimer(1);
    while (true) {
        _ = @atomicRmw(u32, &progress[1], .Add, 1, .release);
    }
}

export fn nih_native_main() callconv(.c) noreturn {
    watchdogOff();
    print("\nNIHOS_NATIVE_BOOT backend=zig-sram rtos=none\n");
    if (progress[0] != 0 or progress[1] != 0 or
        @as(*volatile u32, &initialized).* != 0x4e494853)
        fail("CRT data/BSS");
    asm volatile ("ecall" ::: .{ .memory = true });
    if (exceptions[0] != 1) fail("CPU0 exception return");
    print("NIHOS_NATIVE_CRT_PASS bss=zero data=valid ecall=returned\n");
    prepareTimers();
    startCpu1();
    enableTimer(0);
    var previous: u32 = 0;
    var rounds: u32 = 0;
    var previous_ticks = [_]u32{ 0, 0 };
    var deadline = cycle();
    while (true) {
        _ = @atomicRmw(u32, &progress[0], .Add, 1, .release);
        // Cycle intervals are deliberately not advertised as wall time:
        // the retained bootloader owns the initial clock configuration.
        if (cycle() -% deadline < 4_000_000) continue;
        deadline = cycle();
        const current = @atomicLoad(u32, &progress[1], .acquire);
        if (current == previous or @atomicLoad(u32, &exceptions[1], .acquire) != 1)
            fail("CPU1 progress/exception");
        previous = current;
        rounds +%= 1;
        if (rounds != 1 and rounds % 10 != 0) continue;
        print("NIHOS_NATIVE_HEARTBEAT round=");
        hex(rounds);
        print(" cpu0=");
        hex(@atomicLoad(u32, &progress[0], .acquire));
        print(" cpu1=");
        hex(current);
        print(" ticks0=");
        hex(@atomicLoad(u32, &ticks[0], .acquire));
        print(" ticks1=");
        hex(@atomicLoad(u32, &ticks[1], .acquire));
        print("\n");
        if (rounds % 100 == 0) {
            for (0..2) |hart| {
                const count = @atomicLoad(u32, &ticks[hart], .acquire);
                if (count -% previous_ticks[hart] == 0 or (rounds == 300 and count < 100))
                    fail("timer progress");
                previous_ticks[hart] = count;
            }
            print("NIHOS_NATIVE_SMP_PASS rounds=100 timers=both rtos=none\n");
            if (rounds == 300) print("NIHOS_NATIVE_SOAK_PASS rounds=300 timers=both rtos=none\n");
        }
    }
}
