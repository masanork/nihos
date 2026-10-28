//! Both real controller implementations share the same modeled MMIO/IDMAC.
const std = @import("std");
const shared = @import("sdmmc_host.zig");
const card = @import("../soc/esp32p4/sdmmc.zig");
const c6 = @import("../soc/esp32p4/sdio.zig");
const Registers = struct {
    words: [128]u32 = @splat(0),
    cccr: [512]u8 = @splat(0),
    writes: u32 = 0,
    resets: u32 = 0,
    staged: u32 = 0,
    cache_ok: bool = true,
    pub fn reset(self: *@This()) bool {
        self.words = @splat(0);
        self.resets += 1;
        return true;
    }
    pub fn idle(self: *@This()) bool {
        return self.words[0] == 0 and self.words[0x80 / 4] == 0 and self.words[0x88 / 4] == 0;
    }
    pub fn fence(self: *@This(), _: shared.Slot) bool {
        if (!self.cache_ok) return false;
        self.words[0] = 0;
        self.words[0x80 / 4] = 0;
        self.words[0x88 / 4] = 0;
        return true;
    }
    pub fn read(self: *@This(), register: usize) u32 {
        return switch (register) {
            0, 0x80 => 0,
            else => self.words[register / 4],
        };
    }
    pub fn write(self: *@This(), register: usize, value: u32) void {
        self.writes += 1;
        if (register == 0x44 or register == 0x8c) {
            self.words[register / 4] &= ~value;
            return;
        }
        self.words[register / 4] = value;
        if (register == 0 or register == 0x80) self.words[register / 4] = 0;
        if (register != 0x2c) return;
        self.words[register / 4] = 0;
        if (value & (1 << 21) != 0) return; // Clock update, no card command.
        const command = value & 63;
        const argument = self.words[0x28 / 4];
        self.words[0x44 / 4] = (1 << 2) | (if (command == 17 or command == 53) @as(u32, 1 << 3) else 0);
        self.words[0x30 / 4] = switch (command) {
            3 => 1 << 16,
            13 => 0x900,
            5 => 0x90ff8000,
            8 => 0x1aa,
            41 => 0xc0ff8000,
            55 => 1 << 5,
            else => 0,
        };
        if (command == 9) self.words[0x3c / 4] = 1 << 30;
        if (command == 52) {
            const address = (argument >> 9) & 0x1ffff;
            if (address >= self.cccr.len) return;
            if (argument >> 31 != 0) self.cccr[address] = @truncate(argument);
            self.words[0x30 / 4] = if (address == 3) 2 else self.cccr[address];
        }
    }
};
const Host = shared.Host(*Registers);
const View = struct {
    host: *Host,
    lease: shared.Lease,
    fn read(self: @This(), register: usize) u32 {
        return self.host.read(self.lease, register);
    }
    fn write(self: @This(), register: usize, value: u32) void {
        self.host.write(self.lease, register, value);
    }
    fn owns(self: @This(), slot: u32) bool {
        return @backingInt(self.lease.slot) == slot and self.host.owns(self.lease);
    }
};
const CardBus = struct {
    pub const shared_host = true;
    view: View,
    pub fn ownsSlot(self: @This(), slot: u32) bool {
        return self.view.owns(slot);
    }
    pub fn read(self: @This(), register: usize) u32 {
        return self.view.read(register);
    }
    pub fn write(self: @This(), register: usize, value: u32) void {
        self.view.write(register, value);
    }
    pub fn delay(_: @This(), _: u32) void {}
    pub fn prepareDma(self: @This(), _: u32) ?u32 {
        self.view.host.io.staged += 1;
        return 0x4ff41000;
    }
    pub fn finishDma(_: @This(), destination: *[512]u8, _: u32) bool {
        @memset(destination, 0x3a);
        return true;
    }
    pub fn releaseDma(_: @This()) bool {
        return true;
    }
};
const C6Bus = struct {
    pub const shared_host = true;
    view: View,
    pub fn ownsSlot(self: @This(), slot: u32) bool {
        return self.view.owns(slot);
    }
    pub fn read(self: @This(), register: usize) u32 {
        return self.view.read(register);
    }
    pub fn write(self: @This(), register: usize, value: u32) void {
        self.view.write(register, value);
    }
    pub fn delay(_: @This(), _: u32) void {}
    pub fn fourBitPins(_: @This()) void {}
    pub fn prepareDma(self: @This(), _: bool, _: []const u8, _: usize) ?u32 {
        self.view.host.io.staged += 1;
        return 0x4ff42000;
    }
    pub fn finishDma(_: @This(), _: bool, destination: []u8) bool {
        @memset(destination, 0xa5);
        return true;
    }
};

test "real SD and C6 controllers enumerate and alternate DMA without resetting their peer" {
    var registers = Registers{};
    var host = Host{ .io = &registers };
    try host.initialize();
    const first = try host.acquire(.c6);
    var network = c6.Controller(C6Bus){ .io = .{ .view = .{ .host = &host, .lease = first } } };
    try std.testing.expectError(error.NoOwnership, network.prepare(true));
    try network.prepareShared();
    try network.identify();
    try network.enableFunction();
    var packet: [512]u8 = undefined;
    try network.readBytes(0x1000, &packet);
    try std.testing.expectEqual(@as(u8, 0xa5), packet[511]);
    try host.release(first);
    const second = try host.acquire(.card);
    var storage = card.Controller(CardBus){ .io = .{ .view = .{ .host = &host, .lease = second } } };
    try std.testing.expectError(error.NoOwnership, storage.prepare());
    try storage.prepareShared();
    try storage.identify();
    var sector: [512]u8 = undefined;
    try storage.readSector(1, &sector);
    try std.testing.expectEqual(@as(u8, 0x3a), sector[511]);
    try std.testing.expectEqual(@as(u32, 3), registers.words[0x10 / 4]);
    try std.testing.expectEqual(@as(u32, 2), registers.words[0x18 / 4]);
    try std.testing.expectEqual(@as(u32, 1), registers.resets);
    try host.release(second);
    const third = try host.acquire(.c6);
    network.io.view.lease = third;
    try network.writeBytes(0x1000, &packet);
    try host.release(third);
    const writes = registers.writes;
    try std.testing.expectError(error.NoOwnership, storage.readSector(2, &sector));
    try std.testing.expectEqual(writes, registers.writes);
    try std.testing.expectEqual(@as(u32, 3), registers.staged);
}

test "a failed C6 fence prevents SD register access and recovery revokes old C6 DMA" {
    var registers = Registers{};
    var host = Host{ .io = &registers };
    try host.initialize();
    const lease = try host.acquire(.c6);
    var network = c6.Controller(C6Bus){ .io = .{ .view = .{ .host = &host, .lease = lease } } };
    try network.prepareShared();
    try network.identify();
    try network.enableFunction();
    registers.cache_ok = false;
    try std.testing.expectError(error.Hardware, host.release(lease));
    try std.testing.expectError(error.Quarantined, host.acquire(.card));
    registers.cache_ok = true;
    try host.recover(lease);
    const replacement = try host.acquire(.c6);
    var packet: [512]u8 = undefined;
    const staged = registers.staged;
    try std.testing.expectError(error.NoOwnership, network.readBytes(0x1000, &packet));
    try std.testing.expectEqual(staged, registers.staged);
    try host.release(replacement);
}
