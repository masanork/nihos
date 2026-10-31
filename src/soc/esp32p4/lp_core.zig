//! ESP32-P4 LP Core (Low-Power 32-bit RISC-V coprocessor) controller.
//! Hardware reference: ESP-IDF v5.4.4 soc/esp32p4/register/hw_ver1/soc/
//! (lp_system_reg.h, lpperi_reg.h, soc.h).
const std = @import("std");

pub const lp_ram_base: usize = 0x5010_8000;
pub const lp_ram_size: usize = 32 * 1024; // 32 KiB LP SRAM

pub const lpperi_clk_en_reg: usize = 0x5012_0000;
pub const lpperi_reset_en_reg: usize = 0x5012_0008;
pub const lp_sys_ctrl_reg: usize = 0x5011_0008;
pub const lp_sys_boot_addr_reg: usize = 0x5011_0018;

pub const clk_en_lp_core_bit: u32 = 1 << 31;
pub const rst_en_lp_core_bit: u32 = 1 << 31;
pub const lp_core_disable_bit: u32 = 1 << 0;

/// Minimal RV32I standby monitor stub:
/// Writes incremental heartbeat counter to shared LP mailbox at offset 0x7ff0,
/// then waits for interrupt (WFI).
///
/// Assembly:
///   lui   a0, 0x50110       # a0 = 0x50110000 (shared mail/status)
///   addi  a0, a0, -16       # a0 = 0x5010fff0 (last word in 32KB LP RAM)
/// .Lloop:
///   lw    t0, 0(a0)
///   addi  t0, t0, 1
///   sw    t0, 0(a0)
///   wfi
///   j     .Lloop
pub const default_standby_stub = [_]u32{
    0x50110537, // lui   a0, 0x50110
    0xff050513, // addi  a0, a0, -16
    0x00052283, // lw    t0, 0(a0)
    0x00128293, // addi  t0, t0, 1
    0x00552023, // sw    t0, 0(a0)
    0x10500073, // wfi
    0xff1ff06f, // j     .Lloop (-16 bytes)
};

pub const Status = struct {
    clock_enabled: bool,
    in_reset: bool,
    core_enabled: bool,
    boot_address: u32,
    heartbeat: u32,
};

/// Hardware MMIO accessor for target environment.
pub const NativeMmio = struct {
    pub inline fn read32(_: @This(), address: usize) u32 {
        const ptr: *volatile u32 = @ptrFromInt(address);
        return ptr.*;
    }
    pub inline fn write32(_: @This(), address: usize, value: u32) void {
        const ptr: *volatile u32 = @ptrFromInt(address);
        ptr.* = value;
    }
};

/// Set entry point / boot address for LP Core.
pub inline fn setBootAddress(io: anytype, address: u32) void {
    io.write32(lp_sys_boot_addr_reg, address);
}

/// Enable or disable bus clock to LP Core.
pub inline fn enableClock(io: anytype, enable: bool) void {
    const current = io.read32(lpperi_clk_en_reg);
    io.write32(lpperi_clk_en_reg, if (enable) current | clk_en_lp_core_bit else current & ~clk_en_lp_core_bit);
}

/// Assert and release LP Core reset.
pub inline fn reset(io: anytype) void {
    const current = io.read32(lpperi_reset_en_reg);
    io.write32(lpperi_reset_en_reg, current | rst_en_lp_core_bit);
    io.write32(lpperi_reset_en_reg, current & ~rst_en_lp_core_bit);
}

/// Enable or disable LP Core execution (clears / sets disable bit).
pub inline fn enableCore(io: anytype, enable: bool) void {
    const current = io.read32(lp_sys_ctrl_reg);
    io.write32(lp_sys_ctrl_reg, if (enable) current & ~lp_core_disable_bit else current | lp_core_disable_bit);
}

/// Load code words into LP SRAM at given byte offset.
pub fn loadCode(io: anytype, offset: usize, words: []const u32) bool {
    if (offset + words.len * 4 > lp_ram_size) return false;
    for (words, 0..) |word, index| {
        io.write32(lp_ram_base + offset + index * 4, word);
    }
    return true;
}

/// Boot the LP Core with firmware words loaded at offset 0.
pub fn boot(io: anytype, firmware: []const u32) bool {
    // 1. Disable core during load
    enableCore(io, false);
    // 2. Load firmware to LP SRAM
    if (!loadCode(io, 0, firmware)) return false;
    // 3. Clear mailbox word (offset 0x7ff0)
    io.write32(lp_ram_base + 0x7ff0, 0);
    // 4. Set boot address to LP RAM start
    setBootAddress(io, @intCast(lp_ram_base));
    // 5. Provide clock
    enableClock(io, true);
    // 6. Pulse reset
    reset(io);
    // 7. Enable execution
    enableCore(io, true);
    return true;
}

/// Read current controller status.
pub fn status(io: anytype) Status {
    const clk = io.read32(lpperi_clk_en_reg);
    const rst = io.read32(lpperi_reset_en_reg);
    const ctrl = io.read32(lp_sys_ctrl_reg);
    const boot_addr = io.read32(lp_sys_boot_addr_reg);
    const mb = io.read32(lp_ram_base + 0x7ff0);
    return .{
        .clock_enabled = (clk & clk_en_lp_core_bit) != 0,
        .in_reset = (rst & rst_en_lp_core_bit) != 0,
        .core_enabled = (ctrl & lp_core_disable_bit) == 0,
        .boot_address = boot_addr,
        .heartbeat = mb,
    };
}

// --- Unit tests ---

const MockIo = struct {
    ram: [lp_ram_size / 4]u32 = @splat(0),
    clk_reg: u32 = 0,
    rst_reg: u32 = 0,
    ctrl_reg: u32 = lp_core_disable_bit, // initially disabled
    boot_reg: u32 = 0,

    pub fn read32(self: *MockIo, addr: usize) u32 {
        if (addr >= lp_ram_base and addr < lp_ram_base + lp_ram_size) {
            return self.ram[(addr - lp_ram_base) / 4];
        }
        return switch (addr) {
            lpperi_clk_en_reg => self.clk_reg,
            lpperi_reset_en_reg => self.rst_reg,
            lp_sys_ctrl_reg => self.ctrl_reg,
            lp_sys_boot_addr_reg => self.boot_reg,
            else => 0,
        };
    }

    pub fn write32(self: *MockIo, addr: usize, val: u32) void {
        if (addr >= lp_ram_base and addr < lp_ram_base + lp_ram_size) {
            self.ram[(addr - lp_ram_base) / 4] = val;
            return;
        }
        switch (addr) {
            lpperi_clk_en_reg => self.clk_reg = val,
            lpperi_reset_en_reg => self.rst_reg = val,
            lp_sys_ctrl_reg => self.ctrl_reg = val,
            lp_sys_boot_addr_reg => self.boot_reg = val,
            else => {},
        }
    }
};

test "LP Core boot sequence configures memory, clock, reset and boot address" {
    var io = MockIo{};
    try std.testing.expect(boot(&io, &default_standby_stub));

    // Verify firmware written to start of LP RAM
    for (default_standby_stub, 0..) |word, i| {
        try std.testing.expectEqual(word, io.ram[i]);
    }

    // Verify mailbox cleared
    try std.testing.expectEqual(@as(u32, 0), io.ram[0x7ff0 / 4]);

    // Verify boot address set
    try std.testing.expectEqual(@as(u32, lp_ram_base), io.boot_reg);

    // Verify status
    const st = status(&io);
    try std.testing.expect(st.clock_enabled);
    try std.testing.expect(!st.in_reset);
    try std.testing.expect(st.core_enabled);
    try std.testing.expectEqual(@as(u32, lp_ram_base), st.boot_address);
}

test "loadCode rejects payload exceeding 32KB LP RAM boundary" {
    var io = MockIo{};
    var large: [lp_ram_size / 4 + 1]u32 = @splat(0);
    try std.testing.expect(!loadCode(&io, 0, &large));
    try std.testing.expect(!loadCode(&io, lp_ram_size - 4, &.{ 1, 2 }));
}
