//! Rev1/2 CPLL360 divider startup, ESP-IDF v5.4.4 ordering (Apache-2.0).
//! Boot-only, IRQs masked, CPU1 held. No PLL retuning or voltage changes.
const std = @import("std");
pub const root = 0x500e6004;
pub const mem_sys = 0x500e6008;
pub const apb = 0x500e600c;
pub const source = 0x50111040;
pub const analog = 0x50124000;
pub const revision = 0x5012d04c;
pub fn supportedRevision(value: u32) bool {
    const major = ((value >> 23 & 1) << 2) | (value >> 4 & 3);
    return major >= 1 and major <= 2;
}
const busy: u32 = 1 << 25;
const update: u32 = 1 << 4;
const cpu_fields: u32 = 0x1fffffe0;
pub const Error = error{ InvalidBudget, UnsupportedSource, UnsupportedPll, UnsupportedDividers, Busy, Timeout, Readback };
pub const Result = struct { cpll_mhz: u32, before_mhz: u32, cpu_mhz: u32 = 360, mem_mhz: u32 = 180, apb_mhz: u32 = 90, ctrl0: u32, ctrl1: u32, ctrl2: u32 };

inline fn wait(io: anytype, address: usize, mask: u32, limit: u32) Error!void {
    for (0..limit) |_| if (io.read(address) & mask == 0) return;
    return error.Timeout;
}
inline fn readPll(io: anytype, register: u8, limit: u32) Error!u8 {
    if (io.read(analog) & busy != 0) return error.Busy;
    const conf1 = io.read(analog + 0x1c);
    const conf2 = io.read(analog + 0x20);
    io.write(analog + 0x1c, 0);
    io.write(analog + 0x20, 1 << 11); // CPLL0x67, master0
    defer {
        io.write(analog + 0x1c, conf1);
        io.write(analog + 0x20, conf2);
    }
    io.write(analog, 0x67 | (@as(u32, register) << 8)); // read only
    try wait(io, analog, busy, limit);
    return @truncate(io.read(analog) >> 16);
}
inline fn set(io: anytype, address: usize, mask: u32, bits: u32, limit: u32) Error!void {
    io.write(address, (io.read(address) & ~mask) | bits);
    io.write(root, io.read(root) | update);
    try wait(io, root, update, limit);
    if (io.read(address) & mask != bits) return error.Readback;
}
/// Accept only the retained, calibrated360MHz CPLL and supported integer
/// divider states. Unknown clock owners are rejected before divider writes.
pub inline fn initialize(io: anytype, limit: u32) Error!Result {
    if (limit == 0 or limit > 1_000_000) return error.InvalidBudget;
    if (io.read(source) & 3 != 1) return error.UnsupportedSource;
    const c0 = io.read(root);
    const c1 = io.read(mem_sys);
    const c2 = io.read(apb);
    const divider = (c0 >> 5 & 255) + 1;
    if (c0 & update != 0 or c0 & 0x1fffe000 != 0 or c1 & 0x00ffff00 != 0 or c2 & 0x0000ffff != 0 or
        (divider != 1 and divider != 2 and divider != 4)) return error.UnsupportedDividers;
    const m = (c1 & 255) + 1;
    const s = (c1 >> 24) + 1;
    const a = (c2 >> 16 & 255) + 1;
    if (s != 1 or m != (if (divider == 1) @as(u32, 2) else 1) or a != (if (divider == 4) @as(u32, 1) else 2)) return error.UnsupportedDividers;
    // Analog master clock is already established by the native loader.
    // Read only the CPLL parameters; MPLL/PSRAM and SPLL/Flash are untouched.
    const ref = try readPll(io, 2, limit);
    const div = try readPll(io, 3, limit);
    const mhz = 40 * @as(u32, div) / (@as(u32, ref & 15) + 1); // rev1.3 formula
    if (mhz != 360) return error.UnsupportedPll;
    // Upscaling: APB -> SYS -> MEM -> CPU, committing after each write.
    // Intermediate MEM<=180, APB<=90; never exceed supported bus clocks.
    try set(io, apb, 0xff0000, 1 << 16, limit);
    try set(io, mem_sys, 0xff000000, 0, limit);
    try set(io, mem_sys, 255, 1, limit);
    try set(io, root, cpu_fields, 0, limit);
    return .{ .cpll_mhz = mhz, .before_mhz = mhz / divider, .ctrl0 = io.read(root), .ctrl1 = io.read(mem_sys), .ctrl2 = io.read(apb) };
}

const Model = struct {
    c0: u32 = 3 << 5,
    c1: u32 = 0,
    c2: u32 = 0,
    src: u32 = 0x10000001,
    conf1: u32 = 0xabcd,
    conf2: u32 = 0x1234,
    ctrl: u32 = 0,
    pll_div: u8 = 9,
    stuck: bool = false,
    commits: u32 = 0,
    changed: bool = false,
    pub fn read(self: *@This(), address: usize) u32 {
        return switch (address) {
            root => self.c0,
            mem_sys => self.c1,
            apb => self.c2,
            source => self.src,
            analog => self.ctrl,
            analog + 0x1c => self.conf1,
            analog + 0x20 => self.conf2,
            else => unreachable,
        };
    }
    pub fn write(self: *@This(), address: usize, value: u32) void {
        switch (address) {
            root => {
                self.c0 = value;
                if (value & update != 0) {
                    self.commits += 1;
                    const cpu = 360 / ((value >> 5 & 255) + 1);
                    const memory = cpu / ((self.c1 & 255) + 1);
                    const peripheral = memory / ((self.c1 >> 24) + 1) / ((self.c2 >> 16 & 255) + 1);
                    std.debug.assert(memory <= 180 and peripheral <= 90);
                    if (!self.stuck) self.c0 &= ~update;
                }
            },
            mem_sys => self.c1 = value,
            apb => self.c2 = value,
            analog + 0x1c => self.conf1 = value,
            analog + 0x20 => self.conf2 = value,
            analog => {
                std.debug.assert(value & 255 == 0x67 and value & (1 << 24) == 0);
                self.ctrl = @as(u32, if (value >> 8 & 255 == 3) self.pll_div else @as(u8, 0)) << 16;
            },
            else => unreachable,
        }
    }
};
test "CPU360 upscales in safe bus order and preserves analog selectors" {
    var io = Model{};
    const result = try initialize(&io, 100);
    try std.testing.expectEqual(@as(u32, 90), result.before_mhz);
    try std.testing.expectEqual(@as(u32, 360), result.cpu_mhz);
    try std.testing.expectEqual(@as(u32, 4), io.commits);
    try std.testing.expectEqual(@as(u32, 0xabcd), io.conf1);
    try std.testing.expectEqual(@as(u32, 0x1234), io.conf2);
    try std.testing.expectEqual(@as(u32, 0x10000001), io.src);
    try std.testing.expectEqual(@as(u32, 360), (try initialize(&io, 100)).before_mhz);
}
test "unknown PLL source or fraction is rejected without changing CPU dividers" {
    var unknown = Model{ .pll_div = 10 };
    try std.testing.expectError(error.UnsupportedPll, initialize(&unknown, 100));
    try std.testing.expectEqual(@as(u32, 0), unknown.commits);
    var xtal = Model{ .src = 0 };
    try std.testing.expectError(error.UnsupportedSource, initialize(&xtal, 100));
    var fraction = Model{ .c0 = (3 << 5) | (1 << 13) };
    try std.testing.expectError(error.UnsupportedDividers, initialize(&fraction, 100));
}
test "clock handshake timeout is bounded and never reported as successful" {
    var io = Model{ .stuck = true };
    try std.testing.expectError(error.Timeout, initialize(&io, 5));
    try std.testing.expectEqual(@as(u32, 1), io.commits);
    try std.testing.expectError(error.InvalidBudget, initialize(&io, 0));
}
test "CPU profile rejects newer silicon and pre-rev1 frequency formulas" {
    try std.testing.expect(supportedRevision(0x13));
    try std.testing.expect(supportedRevision(0x20));
    try std.testing.expect(!supportedRevision(1));
    try std.testing.expect(!supportedRevision(0x32));
    try std.testing.expect(!supportedRevision((1 << 23) | 0x13));
}
