//! CPU0-only command discovery. No MMU mappings or external allocations.
const psram = @import("psram");

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

pub const Report = struct {
    discovery: psram.Discovery,
    transactions: u32,
};

pub fn discover() Report {
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
    var controller = psram.Controller(Bus){ .io = .{}, .poll_limit = 100_000 };
    const result = controller.discover();
    return .{ .discovery = result, .transactions = controller.transactions };
}
