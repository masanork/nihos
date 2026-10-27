//! Native Tab5 boot preparation, without ESP-IDF/FreeRTOS or storage I/O.
//! Register facts and sequencing: official Tab5 NoGLIB BSP 1.3.2 (Apache-2.0).
const std = @import("std");
pub const Panel = enum(u32) { ili9881c = 1, st7123 = 2, st7121 = 3 };
pub const Error = error{ UnsupportedPanel, ExpanderIdentity, Readback };
pub const expander_address: u8 = 0x43;
pub const frame_bytes: u32 = 720 * 1280 * 2;
pub const reserve_bytes: u32 = 29 * 65536;
pub const framebuffer: u32 = 0x4803_0000;

pub const Layout = struct { frame_start: u32, frame_bytes: u32, reserve_end: u32, heap_start: u32, heap_bytes: u32 };

/// The first three PSRAM pages are existing nonidentity test windows. The
/// next 29 pages avoid all remapped pages even on the smallest 4 MiB chip.
/// Never reserve the tail: that page intentionally maps to physical page 2.
pub fn layout(capacity: u32) ?Layout {
    if (capacity < 4 * 1024 * 1024 or capacity > 64 * 1024 * 1024 or capacity & (capacity - 1) != 0) return null;
    return .{ .frame_start = framebuffer, .frame_bytes = frame_bytes, .reserve_end = framebuffer + reserve_bytes, .heap_start = framebuffer + reserve_bytes, .heap_bytes = capacity - 3 * 65536 - reserve_bytes };
}

pub fn panelFromFirmware(version: u8) Error!Panel {
    return switch (version) {
        1 => .st7121,
        3 => .st7123,
        else => error.UnsupportedPanel,
    };
}

fn read(bus: anytype, register: u8) !u8 {
    var value: [1]u8 = .{0};
    try bus.transfer(expander_address, &.{register}, &value);
    return value[0];
}

/// Masked read-modify-write; preserve camera, speaker and unrelated power bits.
fn update(bus: anytype, register: u8, mask: u8, bits: u8) !void {
    const previous = try read(bus, register);
    const next = (previous & ~mask) | bits;
    try bus.transfer(expander_address, &.{ register, next }, &.{});
    if (try read(bus, register) != next) return error.Readback;
}

pub fn prepareBoard(bus: anytype) !void {
    // PI4IOE5V6408 vendor ID bits; do not reset this shared expander.
    if (try read(bus, 0x01) & 0xfc != 0xa0) return error.ExpanderIdentity;
    // LCD_EN is expander pin 4: pull-up + released input, as in the BSP.
    try update(bus, 0x0d, 0x10, 0x10);
    try update(bus, 0x0b, 0x10, 0x10);
    try update(bus, 0x03, 0x10, 0);
    try update(bus, 0x07, 0x10, 0x10);
    // TOUCH_EN pin 5 is push-pull high; set its latch before enabling output.
    try update(bus, 0x05, 0x20, 0x20);
    try update(bus, 0x07, 0x20, 0);
    try update(bus, 0x03, 0x20, 0x20);
}

/// Identify only once the touch controller returns a supported firmware ID.
pub fn identify(bus: anytype) !Panel {
    var version: [1]u8 = .{0};
    bus.transfer(0x55, &.{ 0, 0 }, &version) catch |err| {
        // Only an absent-address NACK can select the older GT911 variant.
        // Timeouts, bad firmware IDs and broken buses must not select a panel.
        if (err != error.AddressNack) return err;
        var product: [4]u8 = @splat(0);
        try bus.transfer(0x5d, &.{ 0x40, 0x81 }, &product);
        if (!std.mem.eql(u8, &product, "911\x00")) return error.UnsupportedPanel;
        return .ili9881c;
    };
    return panelFromFirmware(version[0]);
}

/// Normal boot polls readiness within the former 500 ms fixed wait budget.
/// A supported ID permits early completion; an unavailable/busy controller
/// never silently selects a different panel. Electrical bus faults fail early.
pub fn identifyReady(bus: anytype, pins: anytype) !Panel {
    for (0..51) |attempt| {
        return identify(bus) catch |err| switch (err) {
            error.AddressNack, error.ReadAddressNack, error.Nack, error.UnsupportedPanel => {
                if (attempt == 50) return err;
                if (!pins.delay(10_000)) return error.Timer;
                continue;
            },
            else => return err,
        };
    }
    unreachable;
}

const BoardModel = struct {
    registers: [20]u8 = @splat(0x69),
    drop: bool = false,
    version: u8 = 3,
    pending_reads: u8 = 0,
    absent: bool = false,
    timeout: bool = false,
    command_nack: bool = false,
    read_address_nack: bool = false,
    fallback_reads: u32 = 0,
    pub fn transfer(self: *@This(), address: u8, write: []const u8, output: []u8) error{ AddressNack, ReadAddressNack, Nack, ClockTimeout }!void {
        if (address == expander_address) {
            if (write.len == 2 and !self.drop) self.registers[write[0]] = write[1];
            if (output.len == 1) output[0] = self.registers[write[0]];
        } else if (address == 0x55) {
            if (self.timeout) return error.ClockTimeout;
            if (self.absent) return error.AddressNack;
            if (self.command_nack) return error.Nack;
            if (self.read_address_nack) return error.ReadAddressNack;
            if (self.pending_reads != 0) {
                self.pending_reads -= 1;
                output[0] = 0;
            } else output[0] = self.version;
        } else if (address == 0x5d) {
            self.fallback_reads += 1;
            @memcpy(output, "911\x00");
        } else return error.AddressNack;
    }
};

test "LCD/touch power preparation preserves every unrelated expander bit" {
    var model = BoardModel{};
    model.registers[1] = 0xa1;
    const before = model.registers;
    try prepareBoard(&model);
    for (model.registers, before, 0..) |after, previous, index| {
        const mask: u8 = switch (index) {
            3, 7 => 0x30,
            5 => 0x20,
            11, 13 => 0x10,
            else => 0,
        };
        try std.testing.expectEqual(previous & ~mask, after & ~mask);
    }
    try std.testing.expectEqual(@as(u8, 0x20), model.registers[3] & 0x30);
    try std.testing.expectEqual(@as(u8, 0x10), model.registers[7] & 0x30);
    var dropped = BoardModel{ .drop = true };
    dropped.registers[1] = 0xa1;
    try std.testing.expectError(error.Readback, prepareBoard(&dropped));
}

test "unknown firmware or a timeout cannot fall back to another panel" {
    var model = BoardModel{};
    try std.testing.expectEqual(Panel.st7123, try identify(&model));
    model.version = 1;
    try std.testing.expectEqual(Panel.st7121, try identify(&model));
    model.version = 0xff;
    try std.testing.expectError(error.UnsupportedPanel, identify(&model));
    model.timeout = true;
    try std.testing.expectError(error.ClockTimeout, identify(&model));
    model.timeout = false;
    model.command_nack = true;
    try std.testing.expectError(error.Nack, identify(&model));
    model.command_nack = false;
    model.read_address_nack = true;
    try std.testing.expectError(error.ReadAddressNack, identify(&model));
    try std.testing.expectEqual(@as(u32, 0), model.fallback_reads);
    model.command_nack = false;
    model.read_address_nack = false;
    model.absent = true;
    try std.testing.expectEqual(Panel.ili9881c, try identify(&model));
}

test "scanout reservation leaves the nonidentity windows and owner heaps disjoint" {
    for ([_]u32{ 4, 8, 16, 32, 64 }) |mib| {
        const capacity = mib * 1024 * 1024;
        const selected = layout(capacity).?;
        try std.testing.expectEqual(@as(u32, 0x4803_0000), selected.frame_start);
        try std.testing.expect(selected.frame_start + selected.frame_bytes <= selected.reserve_end);
        try std.testing.expectEqual(selected.reserve_end, selected.heap_start);
        try std.testing.expectEqual(@as(u32, 0x4800_0000) + capacity, selected.heap_start + selected.heap_bytes);
        try std.testing.expect(selected.heap_bytes >= 2 * 1024 * 1024);
        try std.testing.expect(selected.reserve_end <= @as(u32, 0x4800_0000) + capacity / 2);
    }
    for ([_]u32{ 0, 2 * 1024 * 1024, 5 * 1024 * 1024, 128 * 1024 * 1024 }) |capacity|
        try std.testing.expect(layout(capacity) == null);
}

test "panel readiness completes early, retries startup IDs and bounds failure" {
    const Pins = struct {
        elapsed: u32 = 0,
        fail: bool = false,
        pub fn delay(self: *@This(), us: u32) bool {
            self.elapsed += us;
            return !self.fail;
        }
    };
    var pins = Pins{};
    var ready = BoardModel{ .version = 1 };
    try std.testing.expectEqual(Panel.st7121, try identifyReady(&ready, &pins));
    try std.testing.expectEqual(@as(u32, 0), pins.elapsed);
    var starting = BoardModel{ .version = 1, .pending_reads = 2 };
    try std.testing.expectEqual(Panel.st7121, try identifyReady(&starting, &pins));
    try std.testing.expectEqual(@as(u32, 20_000), pins.elapsed);
    pins = .{};
    var unsupported = BoardModel{ .version = 0 };
    try std.testing.expectError(error.UnsupportedPanel, identifyReady(&unsupported, &pins));
    try std.testing.expectEqual(@as(u32, 500_000), pins.elapsed);
    pins = .{};
    var broken = BoardModel{ .timeout = true };
    try std.testing.expectError(error.ClockTimeout, identifyReady(&broken, &pins));
    try std.testing.expectEqual(@as(u32, 0), pins.elapsed);
    pins = .{ .fail = true };
    try std.testing.expectError(error.Timer, identifyReady(&unsupported, &pins));
}
