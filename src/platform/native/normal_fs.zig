//! Normal CPU0 storage task. Common-pool parent, no heap retirement/test kills.
//! UI requests are copied and authenticated against the current kernel handle.
const std = @import("std");
pub const panic = std.debug.no_panic;
const storage = @import("storage_vfs");
const rpc = storage.rpc;
const fat = storage.fatfs;
const calls = @import("task_calls");
const control = @import("task_control");
const ring = storage.spsc;
const sd = @import("sdmmc");
const timers = @import("timer_group");
const abi = @import("normal_fs_abi.zig");
const shared = @import("shared_sdmmc.zig");
const host = @import("shared_sdmmc_abi.zig");
const test_hooks = @import("normal_fs_test_hooks.zig");
const Atomic = std.atomic.Value;
const Card = opaque {};
const CardReport = extern struct { status: u32 = 0, generation: u32 = 0, sectors: u32 = 0, kind: u32 = 0, partition: u32 = 0, first: u32 = 0, count: u32 = 0, bytes: u32 = 0, crc: u32 = 0, repeated_crc: u32 = 0, file_name_crc: u32 = 0, reads: u32 = 0, destroyed: u32 = 0, charged: u32 = 0, cleared: u32 = 0, recovered: u32 = 0 };
extern fn nih_fatfs_card_bytes() callconv(.c) u32;
extern fn nih_fatfs_card_mount_volume(*anyopaque, u32, u32, u32, *?*Card, *CardReport) callconv(.c) i32;
extern fn nih_fatfs_card_backend(*Card, u32) callconv(.c) ?*fat.Session;
extern fn nih_fatfs_card_remove(*Card, u32) callconv(.c) i32;
extern fn nih_fatfs_card_destroy(*Card, u32) callconv(.c) i32;
const PoolLease = extern struct { start: u32 = 0, bytes: u32 = 0, generation: u32 = 0, owner: u32 = 0 };
extern fn nih_base_sram_take(u32, u32, u32, *PoolLease) callconv(.c) bool;
extern fn nih_base_sram_release(*const PoolLease) callconv(.c) bool;
extern fn nih_normal_fs_wake() callconv(.c) void;
extern fn nih_sdmmc_power_off() callconv(.c) void;
extern fn nih_sdmmc_power_on() callconv(.c) void;
extern fn nih_rom_cache_writeback(u32, u32, u32) callconv(.c) i32;
extern fn nih_rom_cache_invalidate(u32, u32, u32) callconv(.c) i32;
const Backend = struct {
    value: fat.Backend,
    generation: u32,
    fn current(self: *@This()) bool {
        return self.generation == host.generation();
    }
    pub fn lookupBeneath(self: *@This(), root: u64, path: []const u8) rpc.api.Error!u64 {
        if (!self.current()) return error.RecoveryRequired;
        const result = try self.value.lookupBeneath(root, path);
        if (!self.current()) return error.RecoveryRequired;
        return result;
    }
    pub fn open(self: *@This(), identity: u64, rights: rpc.api.Rights) rpc.api.Error!u64 {
        if (!self.current()) return error.RecoveryRequired;
        const result = try self.value.open(identity, rights);
        if (!self.current()) {
            self.value.close(result) catch return error.RecoveryRequired;
            return error.RecoveryRequired;
        }
        return result;
    }
    pub fn close(self: *@This(), token: u64) rpc.api.Error!void {
        return self.value.close(token);
    }
    pub fn readAt(self: *@This(), token: u64, offset: u64, output: []u8) rpc.api.Transfer {
        if (!self.current()) return .{ .failure = .removed };
        const result = self.value.readAt(token, offset, output);
        if (!self.current()) {
            @memset(output, 0);
            return .{ .failure = .removed };
        }
        return result;
    }
    pub fn writeAt(_: *@This(), _: u64, _: u64, _: []const u8) rpc.api.Transfer {
        return .{ .failure = .io_error };
    }
    pub fn syncFile(_: *@This(), _: u64) rpc.api.Error!void {
        return error.ReadOnly;
    }
    pub fn syncVolume(_: *@This(), _: u64) rpc.api.Error!void {
        return error.ReadOnly;
    }
};
const Owner = rpc.Owner(Backend);
const Command = struct { client: u32 = 0, epoch: u32 = 0, length: u32 = 0, path: [512]u8 = @splat(0) };
const State = struct {
    c_workspace: [32768]u8 align(8),
    owner: Owner,
    queues: rpc.Queues,
    frames: rpc.ClientFrames,
    notifications: rpc.Notifications,
    commands: ring.SpscRing(Command, 2),
    active_command: Command,
    result: [4096]u8,
    dma_data: [512]u8 align(64),
    dma_descriptor: [16]u32 align(64),
    card_controller: sd.Controller(Bus),
    backend: Backend,
    context: ?*Card,
    card_report: CardReport,
    report: abi.Report,
    root: rpc.Token,
    parent: PoolLease,
    client: u32,
    epoch: u32,
    sequence: u32,
    host_generation: u32,
    result_generation: u32,
    result_revision: Atomic(u32),
    consumed_revision: u32,
    phase: Atomic(u32),
    pending: Atomic(bool),
    client_busy: Atomic(bool),
};
comptime {
    if (@sizeOf(State) > 65536) @compileError("normal FS parent exceeds its common-pool quota");
}
var address = Atomic(usize).init(0);
var unavailable = abi.Report{ .status = .off };
fn state() ?*State {
    const at = address.load(.acquire);
    return if (at == 0) null else @ptrFromInt(at);
}
fn phase(s: *State, value: abi.Status) void {
    s.phase.store(@backingInt(value), .release);
}
fn status(s: *State) abi.Status {
    return @fromBackingInt(@intCast(s.phase.load(.acquire)));
}
fn physical(pointer: anytype) u32 {
    return if (test_hooks.enabled) test_hooks.nih_fs_test_address(@intFromPtr(pointer)) else @intCast(@intFromPtr(pointer));
}
fn barrier() void {
    if (!test_hooks.enabled) asm volatile ("fence iorw,iorw" ::: .{ .memory = true });
}
fn mask() u32 {
    if (test_hooks.enabled) return test_hooks.nih_fs_test_mask();
    return asm volatile ("csrrci %[v],mstatus,8"
        : [v] "=r" (-> u32),
        :
        : .{ .memory = true });
}
fn restore(v: u32) void {
    if (test_hooks.enabled) return test_hooks.nih_fs_test_restore(v);
    if (v & 8 != 0) asm volatile ("csrsi mstatus,8" ::: .{ .memory = true });
}
fn caller() u32 {
    const handle = calls.current() orelse return 0;
    return control.encodeHandle(handle);
}
fn yield() void {
    _ = calls.yieldNow();
}
fn quarantine(s: *State) noreturn {
    phase(s, .quarantined);
    if (test_hooks.enabled) test_hooks.nih_fs_test_quarantine();
    while (true) _ = calls.sleep(1);
}
const Bus = struct {
    pub const shared_host = true;
    lease: host.Lease = .{},
    pub fn ownsSlot(self: @This(), slot: u32) bool {
        return slot == 0 and host.owns(self.lease);
    }
    pub fn read(self: @This(), register: usize) u32 {
        return host.read(self.lease, register);
    }
    pub fn write(self: @This(), register: usize, value: u32) void {
        host.write(self.lease, register, value);
    }
    pub fn delay(_: @This(), us: u32) void {
        const clock = timers.Timer.fromGroup(0x500c3000, 0).?;
        const start = if (test_hooks.enabled) test_hooks.nih_fs_test_now() else clock.counter() orelse return;
        for (0..200_000_000) |i| {
            const now = if (test_hooks.enabled) test_hooks.nih_fs_test_now() else clock.counter() orelse return;
            if (now -| start >= us) return;
            if (i & 63 == 63) yield();
        }
    }
    pub fn prepareDma(self: @This(), length: u32) ?u32 {
        if (!self.ownsSlot(0) or (length != 8 and length != 512)) return null;
        const s = state() orelse return null;
        const previous = mask();
        defer restore(previous);
        s.dma_descriptor = @splat(0);
        s.dma_descriptor[0] = (1 << 31) | (1 << 4) | (1 << 3) | (1 << 2);
        s.dma_descriptor[1] = length;
        s.dma_descriptor[2] = physical(&s.dma_data);
        if (nih_rom_cache_writeback(1 << 4, physical(&s.dma_data), 512) != 0 or
            nih_rom_cache_invalidate(1 << 4, physical(&s.dma_data), 512) != 0 or
            nih_rom_cache_writeback(1 << 4, physical(&s.dma_descriptor), 64) != 0) return null;
        barrier();
        return physical(&s.dma_descriptor);
    }
    pub fn finishDma(_: @This(), destination: *[512]u8, length: u32) bool {
        const s = state() orelse return false;
        if (length != 8 and length != 512) return false;
        const previous = mask();
        defer restore(previous);
        barrier();
        if (nih_rom_cache_invalidate(1 << 4, physical(&s.dma_data), 512) != 0 or
            nih_rom_cache_invalidate(1 << 4, physical(&s.dma_descriptor), 64) != 0 or
            @as(*volatile u32, &s.dma_descriptor[0]).* & ((1 << 31) | (1 << 30)) != 0) return false;
        for (destination[0..length], 0..) |*byte, i| byte.* = @as(*volatile u8, &s.dma_data[i]).*;
        return true;
    }
    pub fn releaseDma(_: @This()) bool {
        return nih_normal_card_dma_release() == 1;
    }
};
export fn nih_normal_card_dma_release() callconv(.c) u32 {
    const s = state() orelse return 1;
    const previous = mask();
    defer restore(previous);
    barrier();
    if (nih_rom_cache_invalidate(1 << 4, physical(&s.dma_data), 512) != 0 or
        nih_rom_cache_invalidate(1 << 4, physical(&s.dma_descriptor), 64) != 0) return 0;
    s.dma_descriptor = @splat(0);
    if (nih_rom_cache_writeback(1 << 4, physical(&s.dma_descriptor), 64) != 0) return 0;
    barrier();
    return 1;
}
fn acquire(s: *State) ?host.Lease {
    const before = calls.nowTicks();
    while (true) {
        return host.acquire(0) catch |err| {
            if (err != error.Busy or calls.nowTicks() - before > 100) return null;
            s.report.yields +|= 1;
            yield();
            continue;
        };
    }
}
fn release(s: *State, lease: host.Lease) bool {
    return switch (host.release(lease)) {
        .clean => true,
        .recovered => false,
        .quarantined, .invalid => quarantine(s),
    };
}
export fn nih_storage_read(lba: u32, destination: *[512]u8) callconv(.c) i32 {
    const s = state() orelse return -1;
    if (s.host_generation != host.generation()) return -3;
    const lease = acquire(s) orelse return -1;
    s.card_controller.io.lease = lease;
    const success = blk: {
        s.card_controller.readSector(lba, destination) catch |err| {
            s.report.io_error = @intFromError(err);
            break :blk false;
        };
        s.report.io_error = 0;
        break :blk true;
    };
    s.report.command = s.card_controller.last_command;
    s.report.interrupts = s.card_controller.last_interrupts;
    s.report.dma_status = s.card_controller.last_status;
    const fenced = release(s, lease);
    s.card_controller.io.lease = .{};
    s.report.io_reads +|= 1;
    s.report.yields +|= 1;
    yield(); // UI/network may run only after this sector's device/cache fence.
    if (!fenced or s.host_generation != host.generation()) return -3;
    return if (success) 0 else -1;
}
fn unmount(s: *State) bool {
    phase(s, .starting);
    if (s.context) |context| {
        _ = nih_fatfs_card_remove(context, s.epoch);
        s.owner.revoke(&s.queues) catch return false;
        if (nih_fatfs_card_destroy(context, s.epoch) != 1) return false;
        s.context = null;
    }
    return true;
}
fn mount(s: *State) void {
    if (!unmount(s)) quarantine(s);
    s.report.error_code = 0;
    if (s.epoch == 0x7fffffff) {
        phase(s, .rejected);
        return;
    }
    s.epoch += 1;
    s.sequence = 1;
    s.report.generation = s.epoch;
    s.host_generation = host.generation();
    nih_sdmmc_power_off();
    Bus.delay(.{}, 1000);
    nih_sdmmc_power_on();
    Bus.delay(.{}, 5000);
    const lease = acquire(s) orelse {
        phase(s, .no_card);
        return;
    };
    s.card_controller = .{ .io = .{ .lease = lease } };
    const identified = blk: {
        s.card_controller.prepareShared() catch break :blk false;
        s.card_controller.identify() catch break :blk false;
        break :blk s.card_controller.sectors <= 0xffffffff;
    };
    const fenced = release(s, lease);
    s.card_controller.io.lease = .{};
    if (!identified or !fenced) {
        phase(s, .no_card);
        return;
    }
    s.report.sectors = @intCast(s.card_controller.sectors);
    s.card_report = .{};
    const mounted = nih_fatfs_card_mount_volume(&s.c_workspace, s.c_workspace.len, s.report.sectors, s.epoch, &s.context, &s.card_report);
    if (mounted < 0) quarantine(s);
    if (mounted != 1) {
        s.report.error_code = if (s.card_report.status == 0) -5 else -@as(i32, @intCast(s.card_report.status));
        phase(s, .rejected);
        return;
    }
    const session = nih_fatfs_card_backend(s.context.?, s.epoch) orelse {
        phase(s, .rejected);
        return;
    };
    s.backend = .{ .value = .{ .session = session, .epoch = s.epoch }, .generation = s.host_generation };
    s.queues = .{};
    s.owner = .{ .notifications = &s.notifications, .client = s.client, .epoch = s.epoch };
    s.root = s.owner.start(&s.backend) catch {
        phase(s, .rejected);
        return;
    };
    s.report.kind = s.card_report.kind;
    phase(s, .mounted);
}
fn exchange(s: *State, operation: rpc.Operation, token: rpc.Token, path: []const u8) bool {
    s.frames.request = .{ .epoch = s.epoch, .sequence = s.sequence, .operation = @backingInt(operation), .token = token, .length = if (operation == .read) 4096 else 0, .path_length = @intCast(path.len) };
    @memcpy(s.frames.request.path[0..path.len], path);
    if (s.sequence == 0xffffffff) return false;
    s.sequence += 1;
    if (!s.queues.requests.tryPushFrom(&s.frames.request) or !s.owner.step(&s.queues) or
        !s.queues.responses.tryPopInto(&s.frames.response)) return false;
    return s.frames.response.epoch == s.epoch and s.frames.response.sequence == s.sequence - 1 and
        s.frames.response.status == 0 and s.host_generation == host.generation();
}
fn readCommand(s: *State, command: *const Command) void {
    s.report.error_code = -9;
    s.report.bytes = 0;
    s.report.crc = 0;
    s.report.eof = 0;
    if (status(s) != .mounted or command.client != s.client or command.epoch != s.epoch or
        s.host_generation != host.generation()) return;
    const lease = acquire(s) orelse return;
    s.card_controller.io.lease = lease;
    const present = blk: {
        const response = s.card_controller.command(13, s.card_controller.rca) catch break :blk false;
        break :blk response[0] & 0xfdffe008 == 0 and (response[0] >> 9) & 15 == 4 and response[0] & 0x100 != 0;
    };
    const fenced = release(s, lease);
    s.card_controller.io.lease = .{};
    if (!present or !fenced) {
        if (!unmount(s)) quarantine(s);
        phase(s, .no_card);
        return;
    }
    if (!exchange(s, .open, s.root, command.path[0..command.length])) {
        s.report.error_code = if (s.frames.response.status == 0) -9 else s.frames.response.status;
        if (s.report.error_code == -5 or s.host_generation != host.generation()) {
            if (!unmount(s)) quarantine(s);
            phase(s, .rejected);
        }
        return;
    }
    const file = s.frames.response.token;
    const read = exchange(s, .read, file, "");
    if (read) {
        const length = s.frames.response.length;
        if (length <= s.result.len) {
            @memcpy(s.result[0..length], s.frames.response.data[0..length]);
            s.report.bytes = length;
            s.report.crc = sd.crc32(s.result[0..length]);
            s.report.eof = s.frames.response.eof;
            s.report.error_code = 0;
        }
    } else s.report.error_code = if (s.frames.response.status == 0) -9 else s.frames.response.status;
    if (!exchange(s, .close, file, "") or s.host_generation != host.generation()) {
        @memset(&s.result, 0);
        s.report.bytes = 0;
        s.report.error_code = -9;
    }
    if (s.report.error_code == -5 or s.report.error_code == -9) {
        if (!unmount(s)) quarantine(s);
        phase(s, .rejected);
    }
}
fn stepOnce() callconv(.c) u32 {
    const s = state() orelse return 0;
    if (status(s) == .quarantined) quarantine(s);
    var worked = false;
    if (s.pending.swap(false, .acq_rel)) {
        mount(s);
        worked = true;
    }
    if (status(s) == .mounted and s.host_generation != host.generation()) {
        mount(s);
        worked = true;
    }
    const command = &s.active_command;
    if (s.commands.tryPopInto(command)) {
        s.report.bytes = 0;
        s.report.crc = 0;
        s.report.eof = 0;
        s.report.error_code = 0;
        @memset(&s.result, 0);
        if (command.length == 0) mount(s) else readCommand(s, command);
        s.report.completed +|= 1;
        s.result_generation = s.host_generation;
        _ = s.result_revision.fetchAdd(1, .release);
        worked = true;
    }
    return @intFromBool(worked);
}
comptime {
    if (test_hooks.enabled) @export(&stepOnce, .{ .name = "nih_fs_test_step" });
}
export fn nih_normal_fs_task(_: u32) callconv(.c) i32 {
    while (true) if (stepOnce() == 0) {
        _ = calls.waitEvents(1);
    };
}
export fn nih_normal_fs_begin(client: u32) callconv(.c) void {
    if (state() != null or client == 0 or caller() != client) return;
    if (!shared.begin(timers.Timer.fromGroup(0x500c3000, 0).?)) {
        unavailable.status = .quarantined;
        return;
    }
    var lease = PoolLease{};
    if (!nih_base_sram_take(2, 65536, 65536, &lease)) {
        unavailable.status = .no_memory;
        return;
    }
    const allocated = if (test_hooks.enabled) test_hooks.nih_fs_test_pointer(lease.start) else lease.start;
    const bytes: [*]u8 = @ptrFromInt(allocated);
    @memset(bytes[0..lease.bytes], 0);
    const s: *State = @ptrFromInt(allocated);
    s.parent = lease;
    s.client = client;
    s.context = null;
    s.notifications = .{};
    s.commands = .init();
    s.owner = .{ .notifications = &s.notifications, .client = client };
    s.queues = .{};
    s.phase = .init(@backingInt(abi.Status.starting));
    s.pending = .init(true);
    s.result_revision = .init(0);
    s.client_busy = .init(false);
    s.report = .{ .parent_start = lease.start, .parent_bytes = lease.bytes };
    if (nih_fatfs_card_bytes() > s.c_workspace.len) {
        unavailable.status = .no_memory;
        _ = nih_base_sram_release(&lease);
        return;
    }
    address.store(@intFromPtr(s), .release);
    nih_normal_fs_wake();
}
export fn nih_normal_fs_submit(client: u32, path: [*]const u8, length: u32) callconv(.c) u32 {
    const s = state() orelse return 0;
    if (client != s.client or caller() != client or length > 512 or s.commands.countApprox() != 0 or
        s.result_revision.load(.acquire) != s.consumed_revision) return 0;
    var command = Command{ .client = client, .epoch = s.report.generation, .length = length };
    if (length != 0) {
        if (status(s) != .mounted or s.host_generation != host.generation()) return 0;
        @memcpy(command.path[0..length], path[0..length]);
    }
    if (s.client_busy.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) return 0;
    if (!s.commands.tryPushFrom(&command)) {
        s.client_busy.store(false, .release);
        return 0;
    }
    s.report.requests +|= 1;
    nih_normal_fs_wake();
    return 1;
}
export fn nih_normal_fs_poll(client: u32) callconv(.c) u32 {
    const s = state() orelse return 0;
    if (client != s.client or caller() != client) return 0;
    if (status(s) == .mounted and s.host_generation != host.generation()) nih_normal_fs_wake();
    const revision = s.result_revision.load(.acquire);
    if (revision == s.consumed_revision) return 0;
    s.consumed_revision = revision;
    s.client_busy.store(false, .release);
    return 1;
}
export fn nih_normal_fs_snapshot(output: *abi.Report) callconv(.c) void {
    const s = state() orelse {
        output.* = unavailable;
        return;
    };
    const previous = mask();
    defer restore(previous);
    output.* = s.report;
    output.status = status(s);
}
export fn nih_normal_fs_result(offset: u32, destination: [*]u8, capacity: u32) callconv(.c) u32 {
    const s = state() orelse return 0;
    if (caller() != s.client or capacity > 128) return 0;
    const previous = mask();
    defer restore(previous);
    if (s.result_generation != host.generation() or s.report.error_code != 0 or offset > s.report.bytes or s.report.bytes > s.result.len) return 0;
    const length = @min(capacity, s.report.bytes - offset);
    @memcpy(destination[0..length], s.result[offset..][0..length]);
    return length;
}
