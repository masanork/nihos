//! Post-fixture ownership transfer and real EXIT/reap qualification.
const std = @import("std");
const dev = @import("development_memory");
const api = dev.api;
const calls = @import("task_calls");
const ring = @import("spsc_ring");
const abi = @import("broker_abi.zig");
pub const panic = std.debug.no_panic;
const A = std.atomic.Value(u32);
extern fn nih_native_task_failed() callconv(.c) noreturn;
extern fn nih_rom_putc(u8) callconv(.c) i32;
extern fn nih_broker_sd_read(*[512]u8) callconv(.c) i32;
var peer_quiet = A.init(0);
var enabled = A.init(0);
var identity = A.init(0);
var iteration = A.init(0);
var exited = A.init(0);
var flags = A.init(0);
var cleanup = A.init(0);
var reaped = A.init(0);
var io_armed = A.init(0);
var cancel_requested = A.init(0);
var io_after_exit = A.init(0);
var stack_low: u32 = 0;
var stack_high: u32 = 0;
const Request = struct { sequence: u32, identity: u32, operation: u32, length: u32 = 0, token: u32 = 0 };
const Response = struct { sequence: u32, status: i32 = 0, address: u32 = 0, length: u32 = 0, charged: u32 = 0, token: u32 = 0 };
const State = struct {
    requests: ring.SpscRing(Request, 2) = .init(),
    responses: ring.SpscRing(Response, 2) = .init(),
    report: abi.Report = .{},
    owner: ?api.Owner = null,
    control: ?api.Lease = null,
    network_owner: ?api.Owner = null,
    network_lease: ?api.Lease = null,
    lease: ?api.Lease = null,
    borrow: ?api.Borrow = null,
    bound_identity: u32 = 0,
    next_sequence: u32 = 1,
    client_sequence: u32 = 1,
    next_token: u32 = 1,
    current_token: u32 = 0,
    closed: bool = false,
    waited: bool = false,
    painted: u32 = 0,
};
pub export const nih_broker_config: [14]u32 = .{ 2, 0x4ff73000, 16384, 0x4ff1c000, 0x4ff28000, 0x4ff77000, 0x4ff9f000, 0x48200000, 0x4a000000, 65536, 8912896, 0x48008000, 32768, @sizeOf(dev.Manager) };
comptime {
    if (@sizeOf(State) > 32768 or @sizeOf(dev.Manager) > 16384) @compileError("broker reservation exceeded");
}
fn state() *State {
    return @ptrFromInt(0x48008000);
}
fn manager() *dev.Manager {
    return @ptrFromInt(0x4ff73000);
}
fn fail(step: u8) noreturn {
    for ("NIHOS_BROKER_DETAIL ") |byte| _ = nih_rom_putc(byte);
    _ = nih_rom_putc('0' + step / 10);
    _ = nih_rom_putc('0' + step % 10);
    _ = nih_rom_putc('\n');
    nih_native_task_failed();
}
fn check(ok: bool, step: u8) void {
    if (!ok) fail(step);
}
fn bytes(start: u32, length: u32) []u8 {
    return @as([*]u8, @ptrFromInt(start))[0..length];
}
const guards = [_][2]u32{ .{ 0x4ff5e000, 8192 }, .{ 0x4ff72000, 4096 }, .{ 0x4ff9f000, 4096 } };

// IRQ-side hooks: resident metadata only, no PSRAM or broker operations.
pub export fn nih_broker_peer_quiet() linksection(".iram1.broker_hooks") callconv(.c) void {
    peer_quiet.store(1, .release);
}
pub export fn nih_broker_quiet() linksection(".iram1.broker_hooks") callconv(.c) u32 {
    return peer_quiet.load(.acquire);
}
pub export fn nih_broker_ready() linksection(".iram1.broker_hooks") callconv(.c) u32 {
    return enabled.load(.acquire);
}
pub export fn nih_broker_register(handle: u32, low: u32, high: u32) linksection(".iram1.broker_hooks") callconv(.c) void {
    stack_low = low;
    stack_high = high;
    exited.store(0, .release);
    cleanup.store(0, .release);
    cancel_requested.store(0, .release);
    _ = iteration.fetchAdd(1, .release);
    identity.store(handle, .release);
}
pub export fn nih_broker_task_exited(handle: u32) linksection(".iram1.broker_hooks") callconv(.c) void {
    if (identity.load(.acquire) == handle) exited.store(handle, .release);
}
pub export fn nih_broker_pending() linksection(".iram1.broker_hooks") callconv(.c) u32 {
    return flags.swap(0, .acq_rel);
}
pub export fn nih_broker_cleanup_ready() linksection(".iram1.broker_hooks") callconv(.c) u32 {
    return cleanup.load(.acquire);
}
pub export fn nih_broker_round() linksection(".iram1.broker_hooks") callconv(.c) u32 {
    return iteration.load(.acquire);
}
pub export fn nih_broker_reaped() linksection(".iram1.broker_hooks") callconv(.c) void {
    _ = reaped.fetchAdd(1, .release);
}
pub export fn nih_broker_cancel_requested() linksection(".iram1.broker_hooks") callconv(.c) u32 {
    return cancel_requested.load(.acquire);
}
/// Ordinary CPU0 driver context, with interrupts enabled. No PSRAM access.
/// The native Bus invokes this only after the actual CMD17 register write.
pub export fn nih_broker_io_issued() linksection(".iram1.broker_hooks") callconv(.c) void {
    if (io_armed.cmpxchgStrong(1, 2, .acq_rel, .acquire) != null) return;
    cancel_requested.store(1, .release);
    const target = identity.load(.acquire);
    const began = asm volatile ("csrr %[value], mcycle"
        : [value] "=r" (-> u32),
    );
    while (exited.load(.acquire) != target) {
        const now = asm volatile ("csrr %[value], mcycle"
            : [value] "=r" (-> u32),
        );
        if (now -% began > 1_000_000_000) nih_native_task_failed();
    }
    io_after_exit.store(1, .release);
}

pub export fn nih_broker_runtime_init(old_api_denied: u32, expected_crc: u32) callconv(.c) void {
    check(peer_quiet.load(.acquire) == 1 and old_api_denied == 4, 1);
    state().* = .{};
    for (guards) |g| @memset(bytes(g[0], g[1]), 0x96);
    manager().* = .{};
    check(manager().init(&.{ .{ .memory = bytes(0x4ff1c000, 49152) }, .{ .memory = bytes(0x4ff77000, 163840) } }, &.{.{ .memory = bytes(0x48200000, 30 * 1024 * 1024) }}, dev.policy), 2);
    state().report.old_api_denied = old_api_denied;
    state().report.expected_crc = expected_crc;
    const network = manager().open(.network, .{ .internal = 65536 }) catch fail(38);
    const staging = manager().alloc(network, .internal, 65536, 64) catch fail(38);
    check(@intFromPtr(staging.bytes.ptr) == 0x4ff77000, 38);
    @memset(staging.bytes, 0x59);
    state().network_owner = network;
    state().network_lease = staging;
    const vm = manager().open(.vm, .{ .external = 8 * 1024 * 1024 }) catch fail(3);
    for ([_]u32{ 4 * 1024 * 1024, 8 * 1024 * 1024 }, 0..) |length, pass| {
        const lease = manager().alloc(vm, .external, length, 64) catch fail(4);
        check(lease.charged == length, 5);
        const payload: [*]volatile u32 = @ptrCast(@alignCast(lease.bytes.ptr));
        for (0..length / 4) |i| {
            check(payload[i] == 0, 6);
            payload[i] = @as(u32, @intCast(i)) ^ 0x51ac39d7;
        }
        for (0..length / 4) |i| check(payload[i] == (@as(u32, @intCast(i)) ^ 0x51ac39d7), 7);
        if (pass == 0) {
            state().report.requested4 = length;
            state().report.charged4 = lease.charged;
        } else {
            state().report.requested8 = length;
            state().report.charged8 = lease.charged;
        }
        manager().free(vm, lease) catch fail(8);
    }
    manager().beginClose(vm) catch fail(9);
    check((manager().reclaimOne(vm) catch fail(9)) == .complete, 9);
    enabled.store(1, .release);
}

fn dispatch(request: Request) ?Response {
    const s = state();
    var response = Response{ .sequence = request.sequence };
    s.report.requests += 1;
    if (request.sequence != s.next_sequence or request.sequence == 0) {
        response.status = -22;
        s.report.rejected += 1;
        return response;
    }
    s.next_sequence += 1;
    if (request.identity != s.bound_identity) {
        response.status = -13;
        s.report.stale_identity += 1;
        s.report.rejected += 1;
        return response;
    }
    const owner = s.owner orelse fail(10);
    switch (request.operation) {
        1 => {
            check(s.lease == null, 11);
            const lease = manager().alloc(owner, .external, request.length, 64) catch fail(12);
            s.lease = lease;
            s.current_token = s.next_token;
            s.next_token += 1;
            response.address = @intCast(@intFromPtr(lease.bytes.ptr));
            response.length = @intCast(lease.bytes.len);
            response.charged = lease.charged;
            response.token = s.current_token;
        },
        2, 3 => {
            if (s.lease == null or request.token != s.current_token) {
                response.status = -9;
                s.report.stale_lease += 1;
                s.report.rejected += 1;
                return response;
            }
            if (request.operation == 2) {
                check(s.borrow == null, 13);
                s.borrow = manager().pin(owner, s.lease.?) catch fail(14);
            } else {
                if (manager().free(owner, s.lease.?)) |_| fail(15) else |err| check(err == error.Busy, 15);
                response.status = -16;
                s.report.rejected += 1;
            }
        },
        4 => {
            check(iteration.load(.acquire) == 3 and s.lease != null and s.borrow == null and
                request.token == s.current_token and s.lease.?.bytes.len == 4096 and request.length == 512, 42);
            s.borrow = manager().pin(owner, s.lease.?) catch fail(42);
            io_armed.store(1, .release);
            // No reply is published. The gate kills the blocked client after
            // CMD17 launch; the driver must finish copying before we unpin.
            check(nih_broker_sd_read(@ptrCast(s.borrow.?.bytes.ptr)) == 0, 43);
            check(io_armed.load(.acquire) == 2 and io_after_exit.load(.acquire) == 1 and
                exited.load(.acquire) == s.bound_identity, 44);
            if (manager().free(owner, s.lease.?)) |_| fail(45) else |err| check(err == error.Busy, 45);
            s.report.io_crc = std.hash.Crc32.hash(s.borrow.?.bytes[0..512]);
            check(s.report.io_crc == s.report.expected_crc, 46);
            s.report.io_issued = 1;
            s.report.io_completed = 1;
            s.report.io_bytes = 512;
            s.report.pinned_after_kill = 1;
            s.report.completion_after_exit = 1;
            s.report.forced_exit = 1;
            s.report.discarded_responses = 1;
            io_armed.store(0, .release);
            return null;
        },
        else => {
            response.status = -22;
            s.report.rejected += 1;
        },
    }
    return response;
}
pub export fn nih_broker_runtime_poll() callconv(.c) void {
    const s = state();
    const current = identity.load(.acquire);
    if (current != 0 and current != s.bound_identity) {
        check(s.owner == null and s.lease == null and s.borrow == null, 16);
        s.owner = manager().open(.ime, .{ .internal = 8192, .external = 2097152 }) catch fail(17);
        const control = manager().alloc(s.owner.?, .internal, 8192, 64) catch fail(39);
        check(@intFromPtr(control.bytes.ptr) == 0x4ff1c000, 39);
        for (control.bytes) |byte| check(byte == 0, 39);
        @memset(control.bytes, 0xa7);
        s.control = control;
        s.bound_identity = current;
        s.closed = false;
        s.waited = false;
        switch (iteration.load(.acquire)) {
            1 => s.report.client = current,
            2 => s.report.replacement = current,
            3 => s.report.forced_client = current,
            4 => s.report.after_forced = current,
            else => fail(47),
        }
    }
    if (current == 0) return;
    if (s.owner == null) return;
    if (exited.load(.acquire) == current) {
        if (!s.closed) {
            // The task is stopped and cannot modify its stack. Measure before
            // publishing cleanup, which permits the scheduler to reuse it.
            var low = stack_low;
            const painted_bytes: [*]volatile u8 = @ptrFromInt(low);
            while (low < s.painted and painted_bytes[low - stack_low] == 0x73) : (low += 1) {}
            s.report.client_stack = @max(s.report.client_stack, stack_high - low);
            for (s.control.?.bytes) |byte| check(byte == 0xa7, 40);
            manager().free(s.owner.?, s.control.?) catch fail(40);
            s.control = null;
            manager().beginClose(s.owner.?) catch fail(18);
            s.closed = true;
            s.report.exits += 1;
        }
        const result = manager().reclaimOne(s.owner.?) catch fail(19);
        switch (result) {
            .waiting => {
                check(!s.waited and s.borrow != null, 20);
                s.waited = true;
                s.report.pin_waited += 1;
                const data: [*]volatile u8 = s.borrow.?.bytes.ptr;
                const start: usize = if (iteration.load(.acquire) == 3) 512 else 0;
                for (start..s.borrow.?.bytes.len) |i| check(data[i] == 0x31 + iteration.load(.acquire), 21);
                if (start == 512) check(std.hash.Crc32.hash(s.borrow.?.bytes[0..512]) == s.report.expected_crc, 46);
                manager().unpin(s.borrow.?.token) catch fail(22);
                s.borrow = null;
                s.report.borrow_completed += 1;
            },
            .released => s.lease = null,
            .complete => {
                s.owner = null;
                cleanup.store(iteration.load(.acquire), .release);
            },
        }
        return;
    }
    if (s.requests.tryPop()) |request| {
        const response = dispatch(request) orelse return;
        check(s.responses.tryPush(response), 23);
        flags.store(1, .release);
    }
}

fn exchange(operation: u32, length: u32, token: u32, actor: u32) Response {
    const s = state();
    const sequence = s.client_sequence;
    s.client_sequence += 1;
    check(s.requests.tryPush(.{ .sequence = sequence, .identity = actor, .operation = operation, .length = length, .token = token }), 24);
    while (true) {
        if (s.responses.tryPop()) |response| {
            check(response.sequence == sequence, 25);
            s.report.responses += 1;
            return response;
        }
        switch (calls.waitEvents(1)) {
            .received => {},
            .failed => fail(26),
        }
    }
}
pub export fn nih_broker_task_entry(hart: u32) callconv(.c) i32 {
    check(hart == 1, 27);
    const round = iteration.load(.acquire);
    const painted = asm volatile ("mv %[value], sp"
        : [value] "=r" (-> u32),
    );
    check(painted > stack_low and painted < stack_high, 28);
    const paint: [*]volatile u8 = @ptrFromInt(stack_low);
    for (0..painted - stack_low) |i| paint[i] = 0x73;
    state().painted = painted;
    const current = identity.load(.acquire);
    if (round == 2) {
        check(exchange(3, 0, 1, state().report.client).status == -13, 29);
        check(exchange(3, 0, 1, current).status == -9, 30);
    }
    if (round == 4) {
        check(exchange(3, 0, 3, state().report.forced_client).status == -13, 48);
        check(exchange(3, 0, 3, current).status == -9, 49);
    }
    const length: u32 = switch (round) {
        1 => 8192,
        2 => 2097152,
        else => 4096,
    };
    const grant = exchange(1, length, 0, current);
    check(grant.status == 0 and grant.length == length and grant.charged == length and grant.address >= 0x48200000 and grant.address <= 0x4a000000 - length, 31);
    const data: [*]volatile u8 = @ptrFromInt(grant.address);
    for (0..length) |i| data[i] = @intCast(0x31 + round);
    if (round == 3) {
        _ = exchange(4, 512, grant.token, current);
        fail(50); // A forced-exit task must never receive or resume.
    }
    check(exchange(2, 0, grant.token, current).status == 0, 32);
    check(exchange(3, 0, grant.token, current).status == -16, 33);
    if (round == 1) check(exchange(3, 0, grant.token, current ^ 0x10000).status == -13, 34);
    return @intCast(400 + round);
}
pub export fn nih_broker_runtime_done() callconv(.c) u32 {
    return @intFromBool(reaped.load(.acquire) == 4);
}
pub export fn nih_broker_runtime_finish(out: *abi.Report) callconv(.c) void {
    const s = state();
    check(reaped.load(.acquire) == 4 and s.owner == null and s.lease == null and s.borrow == null and s.requests.countApprox() == 0 and s.responses.countApprox() == 0, 35);
    for (s.network_lease.?.bytes) |byte| check(byte == 0x59, 41);
    manager().beginClose(s.network_owner.?) catch fail(41);
    check((manager().reclaimOne(s.network_owner.?) catch fail(41)) == .released, 41);
    check((manager().reclaimOne(s.network_owner.?) catch fail(41)) == .complete, 41);
    s.network_owner = null;
    s.network_lease = null;
    const local = manager().stats(.internal);
    const remote = manager().stats(.external);
    check(local.free == dev.internal_bytes and remote.free == dev.external_bytes, 36);
    for (guards) |g| for (bytes(g[0], g[1])) |byte| check(byte == 0x96, 37);
    s.report.status = 1;
    s.report.metadata = @sizeOf(dev.Manager);
    s.report.internal_bytes = local.capacity;
    s.report.internal_free = local.free;
    s.report.external_bytes = remote.capacity;
    s.report.external_free = remote.free;
    s.report.internal_floor = local.floor;
    s.report.external_floor = remote.floor;
    s.report.reaped = reaped.load(.acquire);
    s.report.guards = 16384;
    s.report.recovered = 1;
    out.* = s.report;
}
