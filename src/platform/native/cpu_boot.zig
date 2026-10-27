//! Explicit native boot clock startup, before PSRAM mapping and CPU1 release.
const clock = @import("cpu_clock");
const timers = @import("timer_group");
extern fn nih_rom_set_cpu_ticks(u32) callconv(.c) void;
extern fn nih_rom_get_cpu_ticks() callconv(.c) u32;
fn reg(address: usize) *volatile u32 {
    return @ptrFromInt(address);
}
const IO = struct {
    pub inline fn read(_: @This(), address: usize) u32 {
        return reg(address).*;
    }
    pub inline fn write(_: @This(), address: usize, value: u32) void {
        reg(address).* = value;
        asm volatile ("fence iorw,iorw" ::: .{ .memory = true });
    }
};
pub const Report = extern struct {
    status: u32 = 0,
    error_code: u32 = 0,
    pc: u32 = 0,
    source: u32 = 0,
    cpll_mhz: u32 = 0,
    before_mhz: u32 = 0,
    after_mhz: u32 = 0,
    mem_mhz: u32 = 0,
    apb_mhz: u32 = 0,
    ctrl0: u32 = 0,
    ctrl1: u32 = 0,
    ctrl2: u32 = 0,
    rom_mhz: u32 = 0,
};
inline fn measure(timer: timers.Timer) ?u32 {
    const start = timer.counter() orelse return null;
    const first = asm volatile ("csrr %[v],mcycle"
        : [v] "=r" (-> u32),
    );
    for (0..1_000_000) |_| {
        const now = timer.counter() orelse return null;
        if (now - start >= 1000) {
            const last = asm volatile ("csrr %[v],mcycle"
                : [v] "=r" (-> u32),
            );
            return (last -% first) / @as(u32, @intCast(now - start));
        }
    }
    return null;
}
pub noinline fn run(timer: timers.Timer, log: anytype) linksection(".flash.text.boot") bool {
    var result = Report{};
    defer log.record("NIHOS_NATIVE_CPU_CLOCK", null, .{ "status", "error_code", "pc", "source", "cpll_mhz", "before_mhz", "after_mhz", "mem_mhz", "apb_mhz", "ctrl0", "ctrl1", "ctrl2", "rom_mhz" }, &result);
    result.pc = asm volatile ("auipc %[pc],0"
        : [pc] "=r" (-> u32),
    );
    const hart = asm volatile ("csrr %[v],mhartid"
        : [v] "=r" (-> u32),
    );
    const status = asm volatile ("csrr %[v],mstatus"
        : [v] "=r" (-> u32),
    );
    if (hart != 0 or status & 8 != 0) {
        result.error_code = 1;
        return false;
    }
    if (!clock.supportedRevision(reg(clock.revision).*)) {
        result.error_code = 6;
        return false;
    }
    timer.start();
    timer.disarm();
    defer timer.stop();
    result.before_mhz = measure(timer) orelse {
        result.error_code = 2;
        return false;
    };
    const setup = clock.initialize(IO{}, 100_000) catch {
        result.error_code = 3;
        return false;
    };
    nih_rom_set_cpu_ticks(360);
    result.rom_mhz = nih_rom_get_cpu_ticks();
    result.after_mhz = measure(timer) orelse {
        result.error_code = 4;
        return false;
    };
    result.source = reg(clock.source).* & 3;
    result.cpll_mhz = setup.cpll_mhz;
    result.mem_mhz = setup.mem_mhz;
    result.apb_mhz = setup.apb_mhz;
    result.ctrl0 = setup.ctrl0;
    result.ctrl1 = setup.ctrl1;
    result.ctrl2 = setup.ctrl2;
    if (result.after_mhz < 358 or result.after_mhz > 362) {
        result.error_code = 5;
        return false;
    }
    result.status = 1;
    return true;
}
