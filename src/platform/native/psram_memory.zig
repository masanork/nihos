//! Reserved CPU test windows, shared-cache handoff and command-side checks.
//! General external allocation is intentionally not exposed by this fixture.
const mapping = @import("psram_mapping");

extern fn nih_native_psram_mismatch(u32, u32, u32, u32) callconv(.c) noreturn;
extern fn nih_native_task_failed() callconv(.c) noreturn;
extern fn nih_rom_l2_line_size() callconv(.c) u32;
extern fn nih_rom_l2_enable(u32) callconv(.c) void;
extern fn nih_rom_cache_invalidate(u32, u32, u32) callconv(.c) i32;
extern fn nih_rom_cache_writeback(u32, u32, u32) callconv(.c) i32;

const IO = struct {
    pub fn lineSize(_: IO) u32 {
        return nih_rom_l2_line_size();
    }
    pub fn enableCache(_: IO) void {
        nih_rom_l2_enable(0);
        ioFence();
    }
    pub fn sync(_: IO, operation: mapping.Operation, address: u32, length: u32) bool {
        ioFence();
        // The physical rev1.3 bridge failed with L2 alone: dirty CPU writes
        // to the nonidentity windows were not visible through MSPI3. Include
        // the shared L1 data cache in the ROM's ordered data-cache operation.
        const result = switch (operation) {
            .invalidate => nih_rom_cache_invalidate((1 << 4) | (1 << 5), address, length),
            .writeback => nih_rom_cache_writeback((1 << 4) | (1 << 5), address, length),
        };
        ioFence();
        return result == 0;
    }
    pub fn read(_: IO, address: u32) u32 {
        return @as(*volatile u32, @ptrFromInt(address)).*;
    }
    pub fn write(_: IO, address: u32, value: u32) void {
        @as(*volatile u32, @ptrFromInt(address)).* = value;
        ioFence();
    }
};

const CPU = struct {
    pub fn read(_: CPU, address: u32) u32 {
        return @as(*volatile u32, @ptrFromInt(address)).*;
    }
    pub fn write(_: CPU, address: u32, value: u32) void {
        @as(*volatile u32, @ptrFromInt(address)).* = value;
    }
    pub fn fence(_: CPU) void {
        asm volatile ("fence rw, rw" ::: .{ .memory = true });
    }
};

var mapper = mapping.Mapper(IO){ .io = .{}, .fast200 = @import("native_options").psram_200 };
var enabled: u32 = 0;
var request: u32 = 0;
var acknowledgement: u32 = 0;
var peer_done: u32 = 0;
var peer_checks: u32 = 0;
var peer_released: u32 = 0;
var owners_ready: u32 = 0;

pub const heap_start = mapping.virtual_base + mapping.reserved_bytes;
pub const reserved_bytes = mapping.reserved_bytes;

pub const SweepReport = struct { bytes: u32, passes: u32, reads: u32, writes: u32, syncs: u32, confirmed: u32 };

/// Opt-in destructive boot test, before CPU1 release or external allocation.
/// Every mapped CPU word is written and checked through both polarities.
pub fn fullSweep(capacity: u32) SweepReport {
    if (capacity < 4 << 20 or capacity > 64 << 20 or capacity & (capacity - 1) != 0)
        nih_native_task_failed();
    const words: [*]volatile u32 = @ptrFromInt(mapping.virtual_base);
    const count = capacity / 4;
    for (0..2) |pass| {
        for (0..count) |index| {
            const value = 0xa55a_7e31 ^ (mapping.virtual_base + @as(u32, @intCast(index * 4)));
            words[index] = if (pass == 0) value else ~value;
        }
        if (!IO.sync(.{}, .writeback, mapping.virtual_base, capacity) or
            !IO.sync(.{}, .invalidate, mapping.virtual_base, capacity)) nih_native_task_failed();
        for (0..count) |index| {
            const value = 0xa55a_7e31 ^ (mapping.virtual_base + @as(u32, @intCast(index * 4)));
            const expected = if (pass == 0) value else ~value;
            const actual = words[index];
            if (actual != expected) nih_native_psram_mismatch(6, mapping.virtual_base + @as(u32, @intCast(index * 4)), actual, expected);
        }
    }
    return .{ .bytes = capacity, .passes = 2, .reads = count * 2, .writes = count * 2, .syncs = 4, .confirmed = 1 };
}

/// Only CPU0, after command checks and external arena registration.
pub fn releasePeer() void {
    @atomicStore(u32, &peer_released, 1, .release);
}

/// Metadata initialization is linear at boot. Neither timer may begin while
/// its peer is still initializing a potentially large external heap.
pub fn ownerReady(core: u32) void {
    if (@atomicLoad(u32, &enabled, .acquire) != 1) return;
    _ = @atomicRmw(u32, &owners_ready, .Or, @as(u32, 1) << @as(u5, @intCast(core)), .release);
    const start = cycle();
    while (@atomicLoad(u32, &owners_ready, .acquire) != 3) {
        if (cycle() -% start > 1_000_000_000) nih_native_task_failed();
    }
}

pub const Report = struct {
    execution_pc: u32 = 0,
    status: u32 = 0,
    failure: u32 = 0,
    line_bytes: u32 = 0,
    last_address: u32 = 0,
    last_actual: u32 = 0,
    last_expected: u32 = 0,
    bytes: u32 = 0,
    entries: u32 = 0,
    cpu_checks: u32 = 0,
    command_checks: u32 = 0,
    transactions: u32 = 0,
    syncs: u32 = 0,
};

pub const SmpReport = struct {
    status: u32 = 0,
    rounds: u32 = 0,
    owner_checks: u32 = 0,
    peer_checks: u32 = 0,
    command_checks: u32 = 0,
    syncs: u32 = 0,
};

fn fence() void {
    asm volatile ("fence rw, rw" ::: .{ .memory = true });
}

fn ioFence() void {
    asm volatile ("fence iorw, iorw" ::: .{ .memory = true });
}

fn pointer(window: u32, offset: u32) *volatile u32 {
    return @ptrFromInt(mapping.virtual_base + window * mapping.page_bytes + offset);
}

pub noinline fn prepare(controller: anytype) linksection(".flash.text.boot") Report {
    @branchHint(.cold);
    var report = Report{ .status = 2 };
    report.execution_pc = asm volatile ("auipc %[pc], 0"
        : [pc] "=r" (-> u32),
    );
    if (mapping.encrypted(IO.read(.{}, 0x5012d034))) {
        report.failure = 12;
        return report;
    }
    report.line_bytes = IO.lineSize(.{});
    mapper.map(controller.capacity) catch |err| {
        report.entries = mapper.entries_checked;
        report.last_address = mapper.last_address;
        report.last_actual = mapper.last_actual;
        report.last_expected = mapper.last_expected;
        report.failure = switch (err) {
            error.InvalidCapacity => 1,
            error.CacheMode => 2,
            error.Readback => 3,
            error.CacheOperation => 4,
            error.Faulted => 6,
            error.InvalidRange => 7,
            error.NotReady => 8,
            error.DataMismatch => 9,
            error.CommandError => 10,
            error.AlreadyMapped => 13,
        };
        return report;
    };
    report.entries = mapper.entries_checked;
    const result = mapper.exercise(controller, CPU{}) catch |err| {
        report.failure = switch (err) {
            error.DataMismatch => 9,
            error.CommandError => 10,
            else => 11,
        };
        report.last_address = mapper.last_address;
        report.last_actual = mapper.last_actual;
        report.last_expected = mapper.last_expected;
        return report;
    };
    report.status = 1;
    report.bytes = mapper.bytes;
    report.cpu_checks = result.cpu_checks;
    report.command_checks = result.command_checks;
    report.transactions = result.transactions;
    report.syncs = mapper.syncs;
    @atomicStore(u32, &enabled, 1, .release);
    return report;
}

fn waitFor(word: *const u32, value: u32, budget: u32) void {
    const start = cycle();
    while (@atomicLoad(u32, word, .acquire) != value) {
        if (cycle() -% start > budget) nih_native_task_failed();
    }
}

fn cycle() u32 {
    return asm volatile ("csrr %[result], mcycle"
        : [result] "=r" (-> u32),
    );
}

fn message(round: u32, window: u32, index: u32) u32 {
    return 0x5c30_0000 ^ (round << 12) ^ (window << 8) ^ index;
}

pub fn peer() void {
    if (@atomicLoad(u32, &enabled, .acquire) != 1) return;
    for (1..65) |round| {
        waitFor(&request, @intCast(round), 100_000_000);
        for (0..mapping.window_count) |window| {
            for (0..16) |index| {
                const expected = message(@intCast(round), @intCast(window), @intCast(index));
                const location = pointer(@intCast(window), 0x100 + @as(u32, @intCast(index)) * 4);
                if (location.* != expected) nih_native_psram_mismatch(3, @intFromPtr(location), location.*, expected);
                location.* = ~expected;
                peer_checks += 1;
            }
        }
        fence();
        @atomicStore(u32, &acknowledgement, @intCast(round), .release);
    }
    @atomicStore(u32, &peer_done, 1, .release);
    // The arena guards/metadata must be ready before any worker can allocate.
    waitFor(&peer_released, 1, 1_000_000_000);
}

pub fn exchange(controller: anytype) SmpReport {
    if (@atomicLoad(u32, &enabled, .acquire) != 1) return .{};
    var report = SmpReport{ .status = 1 };
    for (1..65) |round| {
        for (0..mapping.window_count) |window| {
            for (0..16) |index| pointer(@intCast(window), 0x100 + @as(u32, @intCast(index)) * 4).* =
                message(@intCast(round), @intCast(window), @intCast(index));
        }
        fence();
        @atomicStore(u32, &request, @intCast(round), .release);
        waitFor(&acknowledgement, @intCast(round), 100_000_000);
        for (0..mapping.window_count) |window| {
            for (0..16) |index| {
                const expected = ~message(@intCast(round), @intCast(window), @intCast(index));
                const location = pointer(@intCast(window), 0x100 + @as(u32, @intCast(index)) * 4);
                if (location.* != expected) nih_native_psram_mismatch(4, @intFromPtr(location), location.*, expected);
                report.owner_checks += 1;
            }
        }
        report.rounds += 1;
    }
    waitFor(&peer_done, 1, 100_000_000);
    report.peer_checks = peer_checks;
    const sync_before = mapper.syncs;
    mapper.sync(.writeback, mapping.virtual_base, mapping.reserved_bytes) catch nih_native_task_failed();
    for (0..mapping.window_count) |window| {
        const physical = mapping.physicalPage(controller.capacity, @intCast(window)).? * mapping.page_bytes;
        for (0..16) |index| {
            const expected = ~message(64, @intCast(window), @intCast(index));
            const address = physical + 0x100 + @as(u32, @intCast(index)) * 4;
            const actual = controller.readWord(address) catch nih_native_task_failed();
            if (actual != expected) nih_native_psram_mismatch(5, address, actual, expected);
            report.command_checks += 1;
        }
    }
    report.syncs = mapper.syncs - sync_before;
    return report;
}
