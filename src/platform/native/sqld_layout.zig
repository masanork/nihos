//! Boot-owned PSRAM reservation, excluded from both general owner heaps.
pub const base: u32 = 0x48200000;
pub const bytes: u32 = 2 * 1024 * 1024;
pub const client_request: u32 = base + 0x4000;
pub const client_response: u32 = base + 0x5000;
// Experimental CPU0 network state; never part of sqld's allocator or buffers.
pub const network_experiment: u32 = base + 0x6000;
pub const network_experiment_bytes: u32 = 0xa000;
pub const store: u32 = base + 0x10000;
pub const store_bytes: u32 = 65536;
pub const service: u32 = base + 0x20000;
pub const service_bytes: u32 = 16384;
pub const eval_stack: u32 = base + 0x30000;
pub const eval_stack_bytes: u32 = 65536;
pub const heap: u32 = base + 0x40000;
pub const heap_bytes: u32 = 1024 * 1024;
pub const cache: u32 = base + 0x140000;
pub const cache_bytes: u32 = 512 * 1024;
pub const stack: u32 = base + 0x1c0000;
pub const stack_bytes: u32 = 65536;
pub const stack_top: u32 = stack + stack_bytes;
// Experimental CPU0 SSH state, separate from the sqld stack and owner heaps.
pub const ssh_experiment: u32 = base + 0x1d0000;
pub const ssh_experiment_bytes: u32 = 0x20000;
pub const ssh_owner_bytes: u32 = 0x16000;
pub const ssh_ui_experiment: u32 = ssh_experiment + ssh_owner_bytes;
pub const ssh_ui_experiment_bytes: u32 = ssh_experiment_bytes - ssh_owner_bytes;
pub const ssh_foreground: u32 = ssh_experiment + ssh_experiment_bytes;
pub const ssh_foreground_bytes: u32 = 0x1000;
// Separately bounded objects; the remaining half is reserved for future use.
pub const ssh_foreground_runtime_bytes: u32 = 0x400;
pub const ssh_entropy: u32 = ssh_foreground + ssh_foreground_runtime_bytes;
pub const ssh_entropy_bytes: u32 = 0x400;
// The counter is initialized once per boot, never per visit. It is not yet wired.
pub const ssh_entropy_state_bytes: u32 = 0x3f0;
pub const ssh_entropy_prepared_bytes: u32 = 0x3c0;
pub const ssh_entropy_tick_timer: u32 = ssh_entropy + ssh_entropy_prepared_bytes;
pub const ssh_entropy_tick_timer_bytes: u32 = 0x20;
// Boot-cleared, CPU0-only one-shot marker; never reset between visits.
pub const ssh_entropy_claim: u32 = ssh_entropy_tick_timer + ssh_entropy_tick_timer_bytes;
pub const ssh_entropy_claim_bytes: u32 = 4;
pub const ssh_entropy_generations: u32 = ssh_entropy + ssh_entropy_state_bytes;
pub const ssh_entropy_generations_bytes: u32 = 8;
// Exclusive CPU0 SSH stack, distinct from the Scheme and render stacks.
pub const ssh_stack: u32 = ssh_foreground + ssh_foreground_bytes;
pub const ssh_stack_bytes: u32 = 0xf000;
pub const guard: u32 = 0xa5a5a5a5;
pub const first_sector: u32 = 2048;
pub const sector_count: u32 = 8192;

/// Boot-only initialization, before any entropy owner can use this region.
/// This clears the CPU-visible state and initializes the boot-epoch counter;
/// it does not establish physical zeroization or cache-writeback guarantees.
pub fn initializeSshEntropyBoot(state: []volatile u8, generations: *volatile u64) bool {
    if (state.len != ssh_entropy_state_bytes) return false;
    for (state) |*byte| byte.* = 0;
    generations.* = 0;
    return true;
}

/// Bind the fixed reservation without writing to it. Boot must initialize the
/// region once before use; the CPU0 owner must keep it stable and must not
/// reinitialize a live preparation, timer, or boot generation counter.
/// Binding alone neither acquires hardware nor qualifies entropy or time.
pub fn SshEntropySlots(comptime Prepared: type, comptime Timer: type, comptime Generations: type) type {
    comptime {
        if (ssh_entropy_prepared_bytes > ssh_entropy_tick_timer - ssh_entropy or
            ssh_entropy_tick_timer + ssh_entropy_tick_timer_bytes > ssh_entropy_claim or
            ssh_entropy_claim + ssh_entropy_claim_bytes > ssh_entropy_generations or
            ssh_entropy_generations + ssh_entropy_generations_bytes > ssh_entropy + ssh_entropy_bytes)
            @compileError("entropy PSRAM slots overlap or exceed their reservation");
        if (@sizeOf(Prepared) > ssh_entropy_prepared_bytes or @alignOf(Prepared) > 16 or
            ssh_entropy % @alignOf(Prepared) != 0)
            @compileError("prepared entropy does not fit its PSRAM slot");
        if (@sizeOf(Timer) > ssh_entropy_tick_timer_bytes or @alignOf(Timer) > 16 or
            ssh_entropy_tick_timer % @alignOf(Timer) != 0)
            @compileError("entropy timer does not fit its PSRAM slot");
        if (@sizeOf(Generations) != ssh_entropy_generations_bytes or @alignOf(Generations) > 16 or
            ssh_entropy_generations % @alignOf(Generations) != 0 or @offsetOf(Generations, "last") != 0 or
            @FieldType(Generations, "last") != u64)
            @compileError("entropy generations do not fit their PSRAM slot");
    }
    return struct {
        prepared: *Prepared,
        timer: *Timer,
        generations: *Generations,
        claim: *u32,

        pub fn bind(region: *align(16) [ssh_entropy_bytes]u8) @This() {
            return .{
                .prepared = @ptrCast(region),
                .timer = @ptrCast(@alignCast(&region[ssh_entropy_prepared_bytes])),
                .generations = @ptrCast(@alignCast(&region[ssh_entropy_state_bytes])),
                .claim = @ptrCast(@alignCast(&region[ssh_entropy_claim - ssh_entropy])),
            };
        }

        /// CPU0 only, after boot cleared the reservation and before use. A
        /// successful or attempted initialization consumes this boot's slot;
        /// failure stays closed and never permits overwriting live cleanup.
        pub fn prepareOnce(self: @This(), gate: anytype, resources: anytype, access: anytype, receipt: anytype) !void {
            if (self.claim.* != 0) return error.AlreadyPrepared;
            if (receipt == null) return error.MissingClockReceipt;
            self.claim.* = 1;
            self.timer.* = .{};
            try self.prepared.initInPlace(gate, resources, access, self.timer, self.generations, receipt);
        }
    };
}

pub fn admitted(capacity: u32, start: u32, length: u32) bool {
    return capacity >= 8 * 1024 * 1024 and start == base and length >= bytes and
        base + bytes <= 0x48000000 + capacity;
}
test "sqld boot region is disjoint from display, heaps and its own parts" {
    const std = @import("std");
    try std.testing.expect(admitted(32 * 1024 * 1024, base, 30 * 1024 * 1024));
    try std.testing.expect(!admitted(4 * 1024 * 1024, base, 2 * 1024 * 1024));
    try std.testing.expect(store + store_bytes <= service);
    try std.testing.expect(client_request + 604 <= client_response);
    try std.testing.expect(client_response + 1048 <= store);
    try std.testing.expect(client_response + 1048 <= network_experiment);
    try std.testing.expect(network_experiment + network_experiment_bytes <= store);
    try std.testing.expect(service + service_bytes <= eval_stack);
    try std.testing.expect(eval_stack + eval_stack_bytes <= heap);
    try std.testing.expect(heap + heap_bytes <= cache);
    try std.testing.expect(cache + cache_bytes <= stack);
    try std.testing.expect(stack_top <= ssh_experiment);
    try std.testing.expect(ssh_experiment + ssh_owner_bytes <= ssh_ui_experiment);
    try std.testing.expect(ssh_ui_experiment + ssh_ui_experiment_bytes <= ssh_foreground);
    try std.testing.expect(ssh_foreground + ssh_foreground_runtime_bytes <= ssh_entropy);
    try std.testing.expect(ssh_entropy + ssh_entropy_bytes <= ssh_foreground + ssh_foreground_bytes);
    try std.testing.expect(ssh_entropy + ssh_entropy_prepared_bytes <= ssh_entropy_tick_timer);
    try std.testing.expect(ssh_entropy_tick_timer + ssh_entropy_tick_timer_bytes <= ssh_entropy_generations);
    try std.testing.expect(ssh_entropy_claim % @alignOf(u32) == 0);
    try std.testing.expect(ssh_entropy_claim + ssh_entropy_claim_bytes <= ssh_entropy_generations);
    try std.testing.expect(ssh_entropy_tick_timer % 8 == 0);
    try std.testing.expect(ssh_entropy + ssh_entropy_state_bytes <= ssh_entropy_generations);
    try std.testing.expect(ssh_entropy_generations + ssh_entropy_generations_bytes <= ssh_entropy + ssh_entropy_bytes);
    try std.testing.expect(ssh_entropy_generations % 8 == 0);
    try std.testing.expect(ssh_foreground % 16 == 0 and ssh_entropy % 16 == 0);
    try std.testing.expect(ssh_foreground + ssh_foreground_bytes <= ssh_stack);
    try std.testing.expect(ssh_stack + ssh_stack_bytes <= base + bytes);
}

test "SSH entropy preparation is once per boot and preserves live state" {
    const std = @import("std");
    const Timer = struct { last: u64 = 0 };
    const Generations = struct { last: u64 = 0 };
    const Prepared = struct {
        attempts: u32,
        pub fn initInPlace(self: *@This(), _: *u8, _: *u8, _: *u8, _: *Timer, _: *Generations, receipt: ?u8) !void {
            if (receipt == null) return error.MissingClockReceipt;
            if (receipt.? == 8) return error.InitFailed;
            self.attempts = 1;
        }
    };
    var region: [ssh_entropy_bytes]u8 align(16) = @splat(0);
    const slots = SshEntropySlots(Prepared, Timer, Generations).bind(&region);
    var dummy: u8 = 0;
    try std.testing.expectError(error.MissingClockReceipt, slots.prepareOnce(&dummy, &dummy, &dummy, @as(?u8, null)));
    try std.testing.expectEqual(@as(u32, 0), slots.claim.*);
    try slots.prepareOnce(&dummy, &dummy, &dummy, @as(?u8, 7));
    slots.prepared.attempts = 9;
    slots.timer.last = 13;
    slots.generations.last = 17;
    const again = SshEntropySlots(Prepared, Timer, Generations).bind(&region);
    try std.testing.expectError(error.AlreadyPrepared, again.prepareOnce(&dummy, &dummy, &dummy, @as(?u8, 7)));
    try std.testing.expectEqual(@as(u32, 9), slots.prepared.attempts);
    try std.testing.expectEqual(@as(u64, 13), slots.timer.last);
    try std.testing.expectEqual(@as(u64, 17), slots.generations.last);
    var failed_region: [ssh_entropy_bytes]u8 align(16) = @splat(0);
    const failed = SshEntropySlots(Prepared, Timer, Generations).bind(&failed_region);
    try std.testing.expectError(error.InitFailed, failed.prepareOnce(&dummy, &dummy, &dummy, @as(?u8, 8)));
    try std.testing.expectError(error.AlreadyPrepared, failed.prepareOnce(&dummy, &dummy, &dummy, @as(?u8, 7)));
}

test "SSH entropy boot initialization is bounded and leaves adjacent bytes alone" {
    const std = @import("std");
    var bytes_: [ssh_entropy_state_bytes + 2]u8 = @splat(0xa5);
    var generations: u64 = 17;
    try std.testing.expect(!initializeSshEntropyBoot(bytes_[1..ssh_entropy_state_bytes], &generations));
    try std.testing.expectEqual(@as(u64, 17), generations);
    try std.testing.expect(std.mem.allEqual(u8, &bytes_, 0xa5));
    try std.testing.expect(initializeSshEntropyBoot(bytes_[1 .. 1 + ssh_entropy_state_bytes], &generations));
    try std.testing.expectEqual(@as(u64, 0), generations);
    try std.testing.expectEqual(@as(u8, 0xa5), bytes_[0]);
    try std.testing.expectEqual(@as(u8, 0xa5), bytes_[bytes_.len - 1]);
    try std.testing.expect(std.mem.allEqual(u8, bytes_[1 .. 1 + ssh_entropy_state_bytes], 0));
}

test "SSH entropy slots bind disjoint storage without changing its contents" {
    const std = @import("std");
    const Prepared = struct { bytes_: [512]u8 };
    const Timer = struct { last: u64, valid: bool };
    const Generations = struct { last: u64 };
    var region: [ssh_entropy_bytes]u8 align(16) = @splat(0xa5);
    const slots = SshEntropySlots(Prepared, Timer, Generations).bind(&region);
    try std.testing.expectEqual(@intFromPtr(&region), @intFromPtr(slots.prepared));
    try std.testing.expectEqual(@intFromPtr(&region) + ssh_entropy_prepared_bytes, @intFromPtr(slots.timer));
    try std.testing.expectEqual(@intFromPtr(&region) + ssh_entropy_state_bytes, @intFromPtr(slots.generations));
    try std.testing.expect(std.mem.allEqual(u8, &region, 0xa5));
    slots.generations.last = 42;
    const rebound = SshEntropySlots(Prepared, Timer, Generations).bind(&region);
    try std.testing.expectEqual(@as(u64, 42), rebound.generations.last);
}
