//! Native task calls: scalar arguments, generation-checked handles, and no
//! user pointers. Architecture code advances mepc and selects a saved frame.

const std = @import("std");

pub const Number = enum(u32) {
    yield_now = 0x4e49_0000,
    sleep = 0x4e49_0001,
    wake = 0x4e49_0002,
    exit = 0x4e49_0003,
    current = 0x4e49_0004,
    ticks = 0x4e49_0005,
    block = 0x4e49_0006,
    wait_events = 0x4e49_0007,
    notify = 0x4e49_0008,

    pub fn decode(raw: u32) ?Number {
        return std.enums.fromInt(Number, raw);
    }
};

pub const Status = struct {
    pub const ok: i32 = 0;
    pub const invalid_call: i32 = -1;
    pub const invalid_argument: i32 = -2;
    pub const not_found: i32 = -3;
    pub const invalid_state: i32 = -4;
    pub const not_supported: i32 = -5;
};

pub const Options = struct { sleep_enabled: bool = true };

pub const Handle = struct { slot: u16, generation: u16 };

pub fn encodeHandle(handle: anytype) u32 {
    return (@as(u32, handle.generation) << 16) | handle.slot;
}

pub fn decodeHandle(raw: u32) ?Handle {
    const slot: u16 = @truncate(raw);
    const generation: u16 = @intCast(raw >> 16);
    if (generation == 0 or slot == std.math.maxInt(u16)) return null;
    return .{ .slot = slot, .generation = generation };
}

pub const Reply = struct {
    low: u32,
    high: u32 = 0,
    reschedule: bool = false,

    pub fn status(code: i32) Reply {
        return .{ .low = @bitCast(code), .high = if (code < 0) std.math.maxInt(u32) else 0 };
    }

    pub fn statusCode(self: Reply) i32 {
        return @bitCast(self.low);
    }
};

/// Called only by the serialized kernel/trap tail. It mutates policy but
/// does not switch stacks, allocate, log, or dereference a task-supplied pointer.
pub fn dispatch(policy: anytype, raw_number: u32, argument: u32) Reply {
    return dispatchWithPayload(policy, raw_number, argument, 0);
}

pub fn dispatchWithPayload(policy: anytype, raw_number: u32, argument: u32, payload: u32) Reply {
    return dispatchWithOptions(policy, raw_number, argument, payload, .{});
}

pub fn dispatchWithOptions(policy: anytype, raw_number: u32, argument: u32, payload: u32, options: Options) Reply {
    const number = Number.decode(raw_number) orelse return .status(Status.invalid_call);
    const current = policy.current() orelse return .status(Status.invalid_state);
    if (number != .notify and payload != 0) return .status(Status.invalid_argument);
    switch (number) {
        .yield_now => {
            if (argument != 0) return .status(Status.invalid_argument);
            return .{ .low = 0, .reschedule = true };
        },
        .sleep => {
            if (!options.sleep_enabled) return .status(Status.not_supported);
            if (!policy.sleep(current, argument)) return .status(Status.invalid_argument);
            return .{ .low = 0, .reschedule = true };
        },
        .block => {
            if (argument != 0) return .status(Status.invalid_argument);
            if (!policy.block(current)) return .status(Status.invalid_state);
            return .{ .low = 0, .reschedule = true };
        },
        .wake => {
            const handle = decodeHandle(argument) orelse return .status(Status.invalid_argument);
            const target: @TypeOf(current) = .{ .slot = handle.slot, .generation = handle.generation };
            if (policy.snapshot(target) == null) return .status(Status.not_found);
            if (!policy.wake(target)) return .status(Status.invalid_state);
            return .{ .low = 0, .reschedule = true };
        },
        .exit => {
            _ = policy.exitCurrent(@bitCast(argument)) orelse return .status(Status.invalid_state);
            return .{ .low = 0, .reschedule = true };
        },
        .current => {
            if (argument != 0) return .status(Status.invalid_argument);
            return .{ .low = encodeHandle(current) };
        },
        .ticks => {
            if (argument != 0) return .status(Status.invalid_argument);
            const now = policy.now();
            return .{ .low = @truncate(now), .high = @intCast(now >> 32) };
        },
        .wait_events => {
            if (argument == 0) return .status(Status.invalid_argument);
            const result = policy.waitEvents(current, argument) orelse return .status(Status.invalid_state);
            return switch (result) {
                .received => |bits| .{ .low = bits },
                .blocked => .{ .low = 0, .reschedule = true },
            };
        },
        .notify => {
            if (payload == 0) return .status(Status.invalid_argument);
            const handle = decodeHandle(argument) orelse return .status(Status.invalid_argument);
            const target: @TypeOf(current) = .{ .slot = handle.slot, .generation = handle.generation };
            if (policy.snapshot(target) == null) return .status(Status.not_found);
            const woken = policy.notify(target, payload) orelse return .status(Status.invalid_state);
            return .{ .low = 0, .reschedule = woken };
        },
    }
}

comptime {
    const asm_numbers = @embedFile("task_call_numbers.inc");
    const mapping = .{
        .{ "YIELD", Number.yield_now }, .{ "SLEEP", Number.sleep },
        .{ "WAKE", Number.wake },       .{ "EXIT", Number.exit },
        .{ "CURRENT", Number.current }, .{ "TICKS", Number.ticks },
        .{ "BLOCK", Number.block },     .{ "WAIT_EVENTS", Number.wait_events },
        .{ "NOTIFY", Number.notify },
    };
    for (mapping) |entry| {
        const expected = std.fmt.comptimePrint(".equ NIH_TASK_{s}, 0x{x}", .{ entry[0], @backingInt(entry[1]) });
        if (std.mem.indexOf(u8, asm_numbers, expected) == null)
            @compileError("native task-call assembly numbers diverged");
    }
}
