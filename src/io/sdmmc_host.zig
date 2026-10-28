//! One foreground owner for the command engine/IDMAC shared by SD and C6.
//! Slot clocks/widths are private views; reset and DMA fencing are global.
const std = @import("std");
pub const Slot = enum(u32) { card = 0, c6 = 1 };
pub const Lease = extern struct { serial: u32 = 0, generation: u32 = 0, slot: Slot = .card };
pub const Error = error{ Busy, NotReady, Quarantined, Exhausted, StaleLease, Hardware };

pub fn portMask(slot: Slot, register: usize) ?u32 {
    const n = @backingInt(slot);
    return switch (register) {
        0x08 => @as(u32, 0xff) << @as(u5, @intCast(8 * n)),
        0x0c => @as(u32, 3) << @as(u5, @intCast(2 * n)),
        0x10, 0x18 => @as(u32, 0x10001) << @as(u5, @intCast(n)),
        else => null,
    };
}

pub fn Host(comptime IO: type) type {
    return struct {
        io: IO,
        generation: u32 = 0,
        serial: u32 = 0,
        active: ?Lease = null,
        quarantined: bool = false,
        invalid_write: bool = false,
        denied: u32 = 0,
        contexts: [2]struct { timeout: u32 = 0, threshold: u32 = 0 } = .{ .{}, .{} },
        const Self = @This();

        fn matches(self: *const Self, lease: Lease) bool {
            const held = self.active orelse return false;
            return held.serial == lease.serial and held.generation == lease.generation and held.slot == lease.slot;
        }
        pub fn owns(self: *const Self, lease: Lease) bool {
            return !self.quarantined and lease.generation == self.generation and self.matches(lease);
        }
        /// No live owner may be reset. All device sessions compare generation
        /// before serving cached filesystem/network state after a reset.
        pub fn initialize(self: *Self) Error!void {
            if (self.active != null) return error.Busy;
            if (self.quarantined) return error.Quarantined;
            if (self.generation != 0) return;
            self.generation = 1;
            if (!self.io.reset()) {
                self.quarantined = true;
                return error.Hardware;
            }
            self.resetContexts();
        }
        fn resetContexts(self: *Self) void {
            for (&self.contexts) |*context| context.* = .{ .timeout = self.io.read(0x14), .threshold = self.io.read(0x4c) };
        }
        pub fn acquire(self: *Self, slot: Slot) Error!Lease {
            if (self.quarantined) return error.Quarantined;
            if (self.active != null) return error.Busy;
            if (self.generation == 0) return error.NotReady;
            if (self.serial == std.math.maxInt(u32)) return error.Exhausted;
            if (!self.io.idle()) {
                self.quarantined = true;
                return error.Hardware;
            }
            self.serial += 1;
            const lease = Lease{ .serial = self.serial, .generation = self.generation, .slot = slot };
            self.active = lease;
            self.invalid_write = false;
            const context = self.contexts[@backingInt(slot)];
            self.io.write(0x14, context.timeout);
            self.io.write(0x4c, context.threshold);
            return lease;
        }
        /// Actual hardware/cache proof, including on command/transfer failure.
        /// A failed fence retains the owner and blocks BOTH slots.
        pub fn release(self: *Self, lease: Lease) Error!void {
            if (!self.matches(lease) or lease.generation != self.generation) return error.StaleLease;
            if (self.quarantined) return error.Quarantined;
            if (!self.io.fence(lease.slot) or !self.io.idle() or self.invalid_write) {
                self.quarantined = true;
                return error.Hardware;
            }
            self.active = null;
        }
        /// Only the quarantined owner may request destructive recovery. Its
        /// DMA backing stays reserved until this succeeds. Failed recovery
        /// still invalidates both session generations and keeps the lease.
        pub fn recover(self: *Self, lease: Lease) Error!void {
            if (!self.matches(lease)) return error.StaleLease;
            if (!self.quarantined) return error.Busy;
            if (self.generation == std.math.maxInt(u32)) return error.Exhausted;
            self.generation += 1;
            if (!self.io.reset() or !self.io.fence(lease.slot) or !self.io.idle()) return error.Hardware;
            self.active = null;
            self.quarantined = false;
            self.invalid_write = false;
            self.resetContexts();
        }
        pub fn read(self: *Self, lease: Lease, register: usize) u32 {
            if (!self.owns(lease)) {
                self.denied +|= 1;
                return 0xffffffff;
            }
            const value = self.io.read(register);
            return if (portMask(lease.slot, register)) |mask| value & mask else value;
        }
        pub fn write(self: *Self, lease: Lease, register: usize, value: u32) void {
            if (!self.owns(lease)) {
                self.denied +|= 1;
                return;
            }
            // Only initialize/recover can reset the controller. A per-slot
            // driver's legacy prepare() must not silently reset its peer.
            if (register == 0 and value & 1 != 0) {
                self.denied +|= 1;
                self.invalid_write = true;
                return;
            }
            const merged = if (portMask(lease.slot, register)) |mask|
                (self.io.read(register) & ~mask) | (value & mask)
            else
                value;
            switch (register) {
                0x14 => self.contexts[@backingInt(lease.slot)].timeout = value,
                0x4c => self.contexts[@backingInt(lease.slot)].threshold = value,
                else => {},
            }
            self.io.write(register, merged);
        }
    };
}

const Model = struct {
    words: [40]u32 = @splat(0),
    writes: u32 = 0,
    resets: u32 = 0,
    fences: [2]u32 = .{ 0, 0 },
    clean: bool = true,
    cache: bool = true,
    resetting: bool = true,
    pub fn reset(self: *@This()) bool {
        self.resets += 1;
        if (!self.resetting) return false;
        self.words = @splat(0);
        self.clean = true;
        return true;
    }
    pub fn idle(self: *@This()) bool {
        return self.clean;
    }
    pub fn fence(self: *@This(), slot: Slot) bool {
        self.fences[@backingInt(slot)] += 1;
        return self.clean and self.cache;
    }
    pub fn read(self: *@This(), register: usize) u32 {
        return self.words[register / 4];
    }
    pub fn write(self: *@This(), register: usize, value: u32) void {
        self.writes += 1;
        self.words[register / 4] = value;
    }
};

test "slot views preserve the peer clocks dividers source and width" {
    var model = Model{};
    var host = Host(*Model){ .io = &model };
    try host.initialize();
    const c6 = try host.acquire(.c6);
    host.write(c6, 0x08, 50 << 8);
    host.write(c6, 0x0c, 4);
    host.write(c6, 0x10, 2);
    host.write(c6, 0x18, 2);
    try std.testing.expectError(error.Busy, host.acquire(.card));
    try std.testing.expectError(error.Busy, host.initialize());
    try host.release(c6);
    const card = try host.acquire(.card);
    host.write(card, 0x08, 1);
    host.write(card, 0x0c, 0);
    host.write(card, 0x10, 1);
    host.write(card, 0x18, 1);
    host.write(card, 0x4c, 0x200f0007);
    try std.testing.expectEqual(@as(u32, 0x3201), model.words[2]);
    try std.testing.expectEqual(@as(u32, 4), model.words[3]);
    try std.testing.expectEqual(@as(u32, 3), model.words[4]);
    try std.testing.expectEqual(@as(u32, 3), model.words[6]);
    try std.testing.expectEqual(@as(u32, 1), host.read(card, 0x10));
    const writes = model.writes;
    host.write(c6, 0x28, 99); // old lease cannot change the new command.
    try std.testing.expectEqual(writes, model.writes);
    try std.testing.expectError(error.StaleLease, host.release(c6));
    try host.release(card);
    const peer = try host.acquire(.c6);
    try std.testing.expectEqual(@as(u32, 0), host.read(peer, 0x4c));
    try host.release(peer);
    const back = try host.acquire(.card);
    try std.testing.expectEqual(@as(u32, 0x200f0007), host.read(back, 0x4c));
    try host.release(back);
}

test "failed DMA cache handback quarantines both slots until owner recovery" {
    var model = Model{};
    var host = Host(*Model){ .io = &model };
    try host.initialize();
    const card = try host.acquire(.card);
    const generation = host.generation;
    model.cache = false;
    try std.testing.expectError(error.Hardware, host.release(card));
    try std.testing.expect(host.active != null);
    try std.testing.expectError(error.Quarantined, host.acquire(.c6));
    try std.testing.expectError(error.Hardware, host.recover(card));
    try std.testing.expect(host.generation != generation);
    model.cache = true;
    try host.recover(card);
    const c6 = try host.acquire(.c6);
    try std.testing.expect(c6.generation != generation);
    try std.testing.expectError(error.StaleLease, host.release(card));
    try host.release(c6);
}

test "slot drivers cannot reset a live peer behind the owner" {
    var model = Model{};
    var host = Host(*Model){ .io = &model };
    try host.initialize();
    const c6 = try host.acquire(.c6);
    const writes = model.writes;
    host.write(c6, 0, 7);
    try std.testing.expectEqual(writes, model.writes);
    try std.testing.expectError(error.Hardware, host.release(c6));
    try std.testing.expectEqual(@as(u32, 1), model.resets);
    try host.recover(c6);
    try std.testing.expectEqual(@as(u32, 2), model.resets);
}

test "leases and generations fail closed on exhaustion" {
    var model = Model{};
    var host = Host(*Model){ .io = &model };
    try host.initialize();
    host.serial = std.math.maxInt(u32);
    try std.testing.expectError(error.Exhausted, host.acquire(.card));
    host.serial = 0;
    const card = try host.acquire(.card);
    model.clean = false;
    try std.testing.expectError(error.Hardware, host.release(card));
    host.generation = std.math.maxInt(u32);
    try std.testing.expectError(error.Exhausted, host.recover(card));
    try std.testing.expect(host.active != null);
}
