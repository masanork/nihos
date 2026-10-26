//! CPU0-only supply, command-data and full-capacity CPU mapping startup.
const psram = @import("psram");
const supply = @import("psram_supply");
const timer_group = @import("timer_group");
pub const memory = @import("psram_memory.zig");

fn reg(address: usize) *volatile u32 {
    return @ptrFromInt(address);
}

const Bus = struct {
    pub fn read(_: Bus, offset: usize) u32 {
        return reg(0x5008f000 + offset).*;
    }
    pub fn write(_: Bus, offset: usize, value: u32) void {
        reg(0x5008f000 + offset).* = value;
        asm volatile ("fence iorw, iorw" ::: .{ .memory = true });
    }
};
var controller = psram.Controller(Bus){ .io = .{}, .poll_limit = 100_000 };

pub const Report = struct {
    discovery: psram.Discovery,
    transactions: u32 = 0,
    total_transactions: u32 = 0,
    supply: SupplyReport = .{},
    io_status: u32 = 0,
    exercise: psram.Exercise = .{},
    mapping: memory.Report = .{},
};

pub const SupplyReport = struct {
    programmed: u32 = 0,
    calibrated: u32 = 0,
    dref: u32 = 0,
    mul: u32 = 0,
    control: u32 = 0,
    analog: u32 = 0,
    settled: u32 = 0,
};

const SupplyBus = struct {
    pub fn read(_: SupplyBus, offset: usize) u32 {
        return reg(0x50115000 + offset).*;
    }
    pub fn write(_: SupplyBus, offset: usize, value: u32) void {
        reg(0x50115000 + offset).* = value;
        asm volatile ("fence iorw, iorw" ::: .{ .memory = true });
    }
};

fn settle(clock: timer_group.Timer) bool {
    clock.start();
    clock.disarm();
    defer clock.stop();
    const start = clock.counter() orelse return false;
    for (0..100_000) |_| {
        const now = clock.counter() orelse return false;
        if (now - start >= 1000) return true;
    }
    return false;
}

/// Temporarily leases the stopped CPU0 1 MHz timer. Caller reconfigures it
/// before scheduler startup. The 1 ms wait is a boot policy, not power-good.
pub noinline fn probe(clock: timer_group.Timer) Report {
    @branchHint(.cold);
    var report = Report{ .discovery = .{ .status = .timeout } };
    const selected = supply.setting(reg(0x5012d04c).*, reg(0x5012d050).*);
    report.supply.calibrated = @intFromBool(selected.calibrated);
    report.supply.dref = selected.dref;
    report.supply.mul = selected.mul;
    report.supply.programmed = @intFromBool(supply.program(SupplyBus{}, selected));
    report.supply.control = SupplyBus.read(.{}, supply.control_offset) & supply.control_mask;
    report.supply.analog = SupplyBus.read(.{}, supply.analog_offset) & supply.analog_mask;
    if (report.supply.programmed != 1) return report;
    report.supply.settled = @intFromBool(settle(clock));
    if (report.supply.settled != 1) return report;
    // All native code/data is in internal SRAM. No peer or cache user may
    // access PSRAM during this one-time controller reset and setup.
    reg(0x500e6014).* |= 1 << 31; // PSRAM system clock.
    // Independent PSRAM clock tree: XTAL, core divider 1, clock gates on.
    // Deliberately no MPLL retuning/high-speed timing calibration here.
    reg(0x500e6030).* = (reg(0x500e6030).* & ~@as(u32, (3 << 12) | (255 << 16))) | (3 << 14);
    reg(0x500e60c0).* |= (1 << 23) | (1 << 25);
    reg(0x500e60c0).* &= ~@as(u32, 1 << 25);
    reg(0x500e60c0).* &= ~@as(u32, 1 << 23);
    // Dedicated PSRAM pads, drive level 2; DQS inputs powered up.
    for ([_]usize{ 0x1c, 0x20, 0x24, 0x28, 0x2c, 0x30, 0x34, 0x38, 0x40, 0x44, 0x48, 0x4c, 0x50, 0x54, 0x58, 0x5c, 0x60, 0x64 }) |offset| {
        reg(0x500e1200 + offset).* = (reg(0x500e1200 + offset).* & ~@as(u32, 3 << 12)) | (2 << 12);
    }
    for ([_]usize{ 0x3c, 0x68 }) |offset| {
        reg(0x500e1200 + offset).* = (reg(0x500e1200 + offset).* & ~@as(u32, 3 << 15)) | (2 << 15) | 1;
    }
    // Shared MSPI2/3 CS setup/hold=4 clocks, hold delay=3 core clocks.
    const mask: u32 = 3 | (31 << 2) | (31 << 7) | (63 << 25);
    reg(0x5008e1a0).* = (reg(0x5008e1a0).* & ~mask) | 3 | (3 << 2) | (3 << 7) | (2 << 25);
    reg(0x5008f014).* = (1 << 16) | 1; // XTAL / 2, nominally 20 MHz.
    asm volatile ("fence iorw, iorw" ::: .{ .memory = true });
    controller = .{ .io = .{}, .poll_limit = 100_000 };
    const result = controller.discover();
    report.discovery = result;
    report.transactions = controller.transactions;
    if (result.status == .detected) {
        report.io_status = 2;
        report.exercise = controller.exercise(result) catch {
            report.total_transactions = controller.transactions;
            return report;
        };
        report.io_status = 1;
    }
    report.total_transactions = controller.transactions;
    if (report.io_status == 1) report.mapping = memory.prepare(&controller);
    return report;
}

pub fn exchange() memory.SmpReport {
    return memory.exchange(&controller);
}
