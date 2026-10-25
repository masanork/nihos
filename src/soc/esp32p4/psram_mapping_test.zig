//! Distinct physical memory and CPU cache views; ROM operations are modeled.
const std = @import("std");
const mapping = @import("psram_mapping.zig");

const Model = struct {
    registers: [256]u32 = @splat(0),
    table: [1024]u32 = @splat(0),
    memory: [64]Cell = @splat(.{}),
    cached: [32]Cached = @splat(.{}),
    index: u32 = 0,
    cache_line: u32 = 64,
    cache_enabled: bool = false,
    cache_calls: u32 = 0,
    register_writes: u32 = 0,
    drop_entry: ?u32 = null,
    reject_sync: bool = false,
    ignore_writeback: bool = false,
    ignore_invalidate: bool = false,
    identity_cpu: bool = false,
    command_fault: bool = false,

    const Cell = struct { address: u32 = 0, value: u32 = 0, occupied: bool = false };
    const Cached = struct { address: u32 = 0, value: u32 = 0, occupied: bool = false, valid: bool = false, dirty: bool = false };

    pub fn read(self: *Model, address: u32) u32 {
        std.debug.assert(address >= mapping.mspi and address < mapping.mspi + 1024);
        if (address == mapping.mspi + 0x37c) return self.table[self.index];
        return self.registers[(address - mapping.mspi) / 4];
    }
    pub fn write(self: *Model, address: u32, value: u32) void {
        std.debug.assert(address >= mapping.mspi and address < mapping.mspi + 1024);
        self.register_writes += 1;
        if (address == mapping.mspi + 0x380) {
            self.index = value;
        } else if (address == mapping.mspi + 0x37c) {
            if (self.drop_entry == null or self.drop_entry.? != self.index) self.table[self.index] = value;
        } else self.registers[(address - mapping.mspi) / 4] = value;
    }
    pub fn lineSize(self: *Model) u32 {
        return self.cache_line;
    }
    pub fn enableCache(self: *Model) void {
        self.cache_enabled = true;
    }
    pub fn sync(self: *Model, operation: mapping.Operation, address: u32, length: u32) bool {
        std.debug.assert(self.cache_enabled and mapping.validSyncRange(address, length));
        self.cache_calls += 1;
        if (self.reject_sync) return false;
        for (&self.cached) |*entry| {
            if (!entry.occupied or entry.address < address or entry.address - address >= length) continue;
            switch (operation) {
                .writeback => if (entry.valid and entry.dirty and !self.ignore_writeback) {
                    self.cell(self.physical(entry.address)).value = entry.value;
                    entry.dirty = false;
                },
                .invalidate => if (!self.ignore_invalidate) {
                    entry.valid = false;
                    entry.dirty = false;
                },
            }
        }
        return true;
    }
    fn cell(self: *Model, address: u32) *Cell {
        for (&self.memory) |*entry| if (entry.occupied and entry.address == address) return entry;
        for (&self.memory) |*entry| if (!entry.occupied) {
            entry.* = .{ .address = address, .occupied = true };
            return entry;
        };
        unreachable;
    }
    fn physical(self: *Model, address: u32) u32 {
        const relative = address - mapping.virtual_base;
        const index = relative / mapping.page_bytes;
        std.debug.assert(self.table[index] & 0xc00 == 0xc00);
        const page = if (self.identity_cpu) index else self.table[index] & 1023;
        return page * mapping.page_bytes + relative % mapping.page_bytes;
    }
    fn cachedCell(self: *Model, address: u32) *Cached {
        std.debug.assert(self.registers[0x3c / 4] & 0x80000001 == 1);
        for (&self.cached) |*entry| if (entry.occupied and entry.address == address) return entry;
        for (&self.cached) |*entry| if (!entry.occupied) {
            entry.* = .{ .address = address, .occupied = true };
            return entry;
        };
        unreachable;
    }
};

const CPU = struct {
    owner: *Model,
    pub fn write(self: CPU, address: u32, value: u32) void {
        const entry = self.owner.cachedCell(address);
        entry.value = value;
        entry.valid = true;
        entry.dirty = true;
    }
    pub fn read(self: CPU, address: u32) u32 {
        const entry = self.owner.cachedCell(address);
        if (!entry.valid) {
            entry.value = self.owner.cell(self.owner.physical(address)).value;
            entry.valid = true;
        }
        return entry.value;
    }
    pub fn fence(_: CPU) void {}
};

const Commands = struct {
    owner: *Model,
    capacity: u32 = 32 * 1024 * 1024,
    transactions: u32 = 0,
    pub fn writeWord(self: *Commands, address: u32, value: u32) !void {
        if (self.owner.command_fault) return error.Injected;
        self.owner.cell(address).value = value;
        self.transactions += 1;
    }
    pub fn readWord(self: *Commands, address: u32) !u32 {
        if (self.owner.command_fault) return error.Injected;
        self.transactions += 1;
        return self.owner.cell(address).value;
    }
};

test "only MMU1 is changed and nonidentity pages survive both cache directions" {
    var model = Model{ .table = @splat(0xdeadbeef) };
    var mapper = mapping.Mapper(*Model){ .io = &model };
    var commands = Commands{ .owner = &model };
    try mapper.map(commands.capacity);
    try std.testing.expectEqualSlices(u32, &.{ 0xc00, 0xd00, 0xdff }, model.table[0..3]);
    for (model.table[3..]) |entry| try std.testing.expectEqual(@as(u32, 0), entry);
    try std.testing.expectEqual(@as(u32, 1024), mapper.entries_checked);
    const result = try mapper.exercise(&commands, CPU{ .owner = &model });
    try std.testing.expectEqualDeep(mapping.Exercise{ .cpu_checks = 36, .command_checks = 36, .transactions = 72 }, result);
    try std.testing.expectEqual(@as(u32, 5), mapper.syncs);
    try std.testing.expect(mapper.ready);
    const before = model.register_writes;
    try std.testing.expectError(error.AlreadyMapped, mapper.map(commands.capacity));
    try std.testing.expectEqual(before, model.register_writes);
}

test "omitting writeback or invalidation cannot qualify the CPU command bridge" {
    for ([_]bool{ false, true }) |omit_invalidation| {
        var model = Model{ .ignore_writeback = !omit_invalidation, .ignore_invalidate = omit_invalidation };
        var mapper = mapping.Mapper(*Model){ .io = &model };
        var commands = Commands{ .owner = &model };
        try mapper.map(commands.capacity);
        try std.testing.expectError(error.DataMismatch, mapper.exercise(&commands, CPU{ .owner = &model }));
        try std.testing.expect(mapper.faulted and !mapper.ready);
        try std.testing.expect(model.registers[0x3c / 4] & 0x80000001 == 0x80000000);
    }
}

test "flat RAM backing that ignores the MMU cannot substitute for translation" {
    var model = Model{ .identity_cpu = true };
    var mapper = mapping.Mapper(*Model){ .io = &model };
    var commands = Commands{ .owner = &model };
    try mapper.map(commands.capacity);
    try std.testing.expectError(error.DataMismatch, mapper.exercise(&commands, CPU{ .owner = &model }));
    try std.testing.expectEqual(@as(u32, 16 * 1024 * 1024), mapper.last_address);
}

test "dropped PTE write closes the AXI port and poisons reuse" {
    var model = Model{ .drop_entry = 2 };
    var mapper = mapping.Mapper(*Model){ .io = &model };
    try std.testing.expectError(error.Readback, mapper.map(32 * 1024 * 1024));
    try std.testing.expectEqual(mapping.mspi + 0x37c, mapper.last_address);
    try std.testing.expectEqual(@as(u32, 0xdff), mapper.last_expected);
    for (model.table) |entry| try std.testing.expectEqual(@as(u32, 0), entry);
    try std.testing.expect(model.registers[0x3c / 4] & 0x80000001 == 0x80000000);
    try std.testing.expectError(error.Faulted, mapper.map(32 * 1024 * 1024));
}

test "ROM operation rejection revokes mapping instead of exposing a partial span" {
    var model = Model{ .reject_sync = true };
    var mapper = mapping.Mapper(*Model){ .io = &model };
    try std.testing.expectError(error.CacheOperation, mapper.map(32 * 1024 * 1024));
    try std.testing.expect(!mapper.ready and mapper.faulted);
    for (model.table) |entry| try std.testing.expectEqual(@as(u32, 0), entry);
}

test "invalid geometry capacity or cache range cannot issue unintended operations" {
    var model = Model{ .cache_line = 128 };
    var mapper = mapping.Mapper(*Model){ .io = &model };
    try std.testing.expectError(error.CacheMode, mapper.map(32 * 1024 * 1024));
    try std.testing.expectError(error.InvalidCapacity, mapper.map(0));
    try std.testing.expectError(error.InvalidRange, mapper.sync(.writeback, 0x40000000, 64));
    try std.testing.expectEqual(@as(u32, 0), model.register_writes);
    try std.testing.expectEqual(@as(u32, 0), model.cache_calls);
}

test "failed physical command revokes the mapped test windows" {
    var model = Model{ .command_fault = true };
    var mapper = mapping.Mapper(*Model){ .io = &model };
    var commands = Commands{ .owner = &model };
    try mapper.map(commands.capacity);
    try std.testing.expectError(error.CommandError, mapper.exercise(&commands, CPU{ .owner = &model }));
    try std.testing.expect(mapper.faulted and !mapper.ready);
}
