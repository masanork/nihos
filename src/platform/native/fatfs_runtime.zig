//! Opt-in native scheduler/RPC qualification over immutable FAT12 Flash input.
//! Ordinary owner code lives in mapped Flash; IRQ hooks use resident words only.
const std = @import("std");
const support = @import("storage_vfs");
const rpc = support.rpc;
const memory = support.memory;
const dev = support.development;
const adapter = support.fatfs;
const calls = @import("task_calls");
const Owner = rpc.Owner(adapter.Backend);
const A = std.atomic.Value(u32);
const Report = @import("fatfs_service_abi.zig").Report;
const options = @import("native_options");
const card = @import("fatfs_card_abi.zig");
extern fn nih_storage_fatfs_session_begin(*u32) callconv(.c) u32;
extern fn nih_storage_fatfs_session_end(u32) callconv(.c) u32;
extern fn nih_fatfs_card_bytes() callconv(.c) u32;
extern fn nih_fatfs_card_read(*anyopaque, u32, u32, u32, *card.Report) callconv(.c) c_int;
const CardContext = opaque {};
extern fn nih_fatfs_card_mount(*anyopaque, u32, u32, u32, *?*CardContext, *card.Report) callconv(.c) c_int;
extern fn nih_fatfs_card_backend(*CardContext, u32) callconv(.c) ?*adapter.Session;
extern fn nih_fatfs_card_path(*CardContext, u32) callconv(.c) ?[*:0]const u8;
extern fn nih_fatfs_card_destroy(*CardContext, u32) callconv(.c) c_int;
extern fn nih_fatfs_card_reads(*CardContext, u32) callconv(.c) u32;
extern fn nih_fatfs_fixture_read(?*anyopaque, u32, [*]u8) callconv(.c) c_int;
extern fn nih_native_task_failed() callconv(.c) noreturn;
extern fn nih_rom_putc(u8) callconv(.c) i32;
extern fn nih_sqlite_stack_paint(u32) callconv(.c) u32;
extern fn nih_fatfs_backend_bytes() u32;
extern fn nih_fatfs_backend_init([*]u8, u32, *anyopaque, u64) ?*adapter.Session;
extern fn nih_fatfs_backend_mount(*adapter.Session, u64) c_int;
extern fn nih_fatfs_backend_destroy(*adapter.Session, u64) c_int;
extern fn nih_fatfs_native_disk_bytes() u32;
extern fn nih_fatfs_fixture_bind(*anyopaque, u64) c_int;
extern fn nih_fatfs_fixture_id() u32;

var notifications = rpc.Notifications{};
var handles: [2]A = @splat(.init(0));
var flags: [2]support.event_latch.Latch = @splat(.{});
var enabled = A.init(0);
var ready = A.init(0);
var cleanup = A.init(0);
var retired = A.init(0);
var cancel_requested = A.init(0);
var io_armed = A.init(0);
var inflight = A.init(0);
var bound_epoch = A.init(0);
var stale_exits = A.init(0);
var bounds: [2]struct { low: u32 = 0, high: u32 = 0 } = @splat(.{});
const State = struct {
    report: Report = .{},
    parent: ?memory.Parent = null,
    layout: ?memory.Layout = null,
    service_owner: ?dev.api.Owner = null,
    client_owner: ?dev.api.Owner = null,
    client_lease: ?dev.api.Lease = null,
    backend: ?adapter.Backend = null,
    root: rpc.Token = .{},
    old_file: rpc.Token = .{},
    old_client: u32 = 0,
    next_sequence: u32 = 1,
    card_context: ?*CardContext = null,
    card_report: card.Report = .{},
    path: ?[*:0]const u8 = null,
    client_painted: u32 = 0,
};
comptime {
    if (@sizeOf(State) > 32768) @compileError("native FSD control exceeds retired broker IPC reservation");
}
// Bound by the image audit; the broker's retired IPC is outside its page pools.
pub export const nih_fatfs_native_config: [8]u32 linksection(".rodata.fatfs_config") = .{ 1, 0x48008000, 32768, @sizeOf(State), memory.parent_bytes, @sizeOf(rpc.ClientFrames), @sizeOf(Owner), @sizeOf(rpc.Queues) };
fn state() *State {
    return @ptrFromInt(0x48008000);
}
fn manager() *dev.Manager {
    return @import("broker_runtime.zig").manager();
}
fn cardAttempt(out: *card.Report) callconv(.c) u32 {
    var generation: u32 = 0;
    const sectors = nih_storage_fatfs_session_begin(&generation);
    if (sectors == 0) return 0;
    const account = manager().open(.vfs, .{ .external = 32768 }) catch fail();
    check(nih_fatfs_card_bytes() <= 32768);
    const lease = manager().alloc(account, .external, 32768, 128) catch fail();
    const held = manager().pin(account, lease) catch fail();
    const result = nih_fatfs_card_read(held.bytes.ptr, @intCast(held.bytes.len), sectors, generation, out);
    check(result >= 0); // Unproved teardown must retain the pin/session.
    check(nih_storage_fatfs_session_end(generation) == 1);
    @memset(held.bytes, 0);
    out.charged = lease.charged;
    out.cleared = 1;
    manager().unpin(held.token) catch fail();
    manager().free(account, lease) catch fail();
    manager().beginClose(account) catch fail();
    check((manager().reclaimOne(account) catch fail()) == .complete);
    check(manager().stats(.external).free == dev.external_bytes);
    out.recovered = 1;
    return @intCast(result);
}
comptime {
    if (options.fatfs_sd) {
        @export(&cardAttempt, .{ .name = "nih_fatfs_card_attempt" });
        @export(&card_mode, .{ .name = "nih_fatfs_card_mode" });
    }
    if (options.fatfs_sd_rpc) {
        @export(&readTicket, .{ .name = "nih_fatfs_read_ticket" });
        @export(&readCancelled, .{ .name = "nih_fatfs_read_cancelled" });
    }
}
const card_mode: u32 linksection(".rodata.fatfs_config") = if (options.fatfs_sd_rpc) 3 else @intFromBool(options.fatfs_sd_direct);
fn readTicket() linksection(".iram1.storage_hooks") callconv(.c) u32 {
    return notifications.activeReadTicket();
}
fn readCancelled(ticket: u32) linksection(".iram1.storage_hooks") callconv(.c) u32 {
    return @intFromBool(notifications.readCancelled(ticket));
}
fn owner() *Owner {
    return @ptrCast(@alignCast(state().parent.?.borrow.?.bytes.ptr + state().layout.?.endpoint));
}
fn queues() *rpc.Queues {
    return @ptrCast(@alignCast(state().parent.?.borrow.?.bytes.ptr + state().layout.?.queues));
}
fn frames() *rpc.ClientFrames {
    return @ptrCast(@alignCast(state().client_lease.?.bytes.ptr));
}
noinline fn fail() noreturn {
    for ("NIHOS_FATFS_FAILURE caller=") |byte| _ = nih_rom_putc(byte);
    const address = @returnAddress();
    const digits = "0123456789abcdef";
    var shift: u5 = 28;
    while (true) {
        _ = nih_rom_putc(digits[@as(u4, @truncate(address >> shift))]);
        if (shift == 0) break;
        shift -= 4;
    }
    _ = nih_rom_putc('\n');
    nih_native_task_failed();
}
noinline fn stage(value: u8) void {
    for ("NIHOS_FATFS_STAGE ") |byte| _ = nih_rom_putc(byte);
    _ = nih_rom_putc('0' + value / 10);
    _ = nih_rom_putc('0' + value % 10);
    _ = nih_rom_putc('\n');
}
fn check(ok: bool) void {
    if (!ok) fail();
}
inline fn signal(hart: u32) void {
    flags[hart].notify();
    @as(*volatile u32, @ptrFromInt(0x500e5010 + hart * 4)).* = 1;
    asm volatile ("fence iorw, iorw" ::: .{ .memory = true });
}
fn wait() void {
    switch (calls.waitEvents(1)) {
        .received => {},
        .failed => fail(),
    }
}
fn currentHandle() u32 {
    // Registration and exit notifications use the scheduler's handle namespace.
    // The legacy C allocator identity is unavailable after broker retirement
    // and also encodes the CPU, so it cannot authenticate this endpoint.
    const current = calls.current() orelse fail();
    return (@as(u32, current.generation) << 16) | current.slot;
}
pub export fn nih_storage_runtime_ready() linksection(".iram1.storage_hooks") callconv(.c) u32 {
    return enabled.load(.acquire);
}
pub export fn nih_storage_register(hart: u32, handle: u32, low: u32, high: u32) linksection(".iram1.storage_hooks") callconv(.c) void {
    bounds[hart] = .{ .low = low, .high = high };
    if (hart == 1 and handles[1].load(.acquire) != 0) {
        ready.store(0, .release);
        cancel_requested.store(0, .release);
        cleanup.store(0, .release);
    }
    handles[hart].store(handle, .release);
    signal(hart);
    signal(hart ^ 1);
}
pub export fn nih_storage_pending(hart: u32) linksection(".iram1.storage_hooks") callconv(.c) u32 {
    return flags[hart].take();
}
pub export fn nih_storage_task_exited(hart: u32, handle: u32) linksection(".iram1.storage_hooks") callconv(.c) void {
    if (hart != 1) return;
    if (handles[1].load(.acquire) != handle) {
        _ = stale_exits.fetchAdd(1, .release);
        return;
    }
    _ = notifications.notifyExit(handle, bound_epoch.load(.acquire));
    signal(0);
}
pub export fn nih_storage_cancel_requested() linksection(".iram1.storage_hooks") callconv(.c) u32 {
    return cancel_requested.load(.acquire);
}
pub export fn nih_storage_cleanup_ready() linksection(".iram1.storage_hooks") callconv(.c) u32 {
    return cleanup.load(.acquire);
}
pub export fn nih_storage_retired(hart: u32) linksection(".iram1.storage_hooks") callconv(.c) void {
    _ = retired.fetchOr(@as(u32, 1) << @intCast(hart), .release);
}
pub export fn nih_storage_runtime_init() callconv(.c) void {
    stage(10);
    // The previous broker qualification has finished and released every lease.
    check(manager().stats(.external).free == dev.external_bytes);
    state().* = .{};
    enabled.store(1, .release);
    signal(1);
}
pub export fn nih_storage_runtime_finished() callconv(.c) u32 {
    return @intFromBool(retired.load(.acquire) == 3);
}
pub export fn nih_storage_runtime_poll(_: u32) callconv(.c) void {}

/// Qualification pause after a sector has returned fenced (Flash or SD).
/// CPU1 stops the client while this owner remains inside read. This hook does
/// not claim that DMA is still transferring at that point.
pub export fn nih_fatfs_fixture_after_read() callconv(.c) void {
    const mode = io_armed.load(.acquire);
    if ((mode != 1 and mode != 2) or io_armed.cmpxchgStrong(mode, mode + 2, .acq_rel, .acquire) != null) return;
    if (mode == 1) inflight.store(1, .release) else cancel_requested.store(1, .release);
    signal(1);
    const epoch = bound_epoch.load(.acquire);
    const began = asm volatile ("csrr %[v], mcycle"
        : [v] "=r" (-> u32),
    );
    while (if (mode == 1) inflight.load(.acquire) != 2 else !notifications.exited(epoch)) {
        const now = asm volatile ("csrr %[v], mcycle"
            : [v] "=r" (-> u32),
        );
        if (now -% began > 1_000_000_000) fail();
    }
}
noinline fn newClient() void {
    const s = state();
    s.client_owner = manager().open(.vm, .{ .external = 8192 }) catch fail();
    s.client_lease = manager().alloc(s.client_owner.?, .external, @sizeOf(rpc.ClientFrames), 128) catch fail();
    frames().* = .{};
    s.next_sequence = 1;
}
fn reapClient() void {
    const s = state();
    check(notifications.exited(bound_epoch.load(.acquire)));
    manager().beginClose(s.client_owner.?) catch fail();
    check((manager().reclaimOne(s.client_owner.?) catch fail()) == .released);
    check((manager().reclaimOne(s.client_owner.?) catch fail()) == .complete);
    s.client_owner = null;
    s.client_lease = null;
}
fn measure(hart: u32, painted: u32) u32 {
    var at = bounds[hart].low;
    while (at < painted and @as(*volatile u32, @ptrFromInt(at)).* == 0x5a7ec319) : (at += 4) {}
    check(at > bounds[hart].low + 160 and at <= painted);
    return bounds[hart].high - at;
}
const Filesystem = struct {
    pub fn destroy(_: @This()) error{Busy}!void {
        if (options.fatfs_sd_rpc) {
            const s = state();
            s.card_report.reads = nih_fatfs_card_reads(s.card_context.?, s.card_report.generation);
            if (nih_fatfs_card_destroy(s.card_context.?, s.card_report.generation) != 1) return error.Busy;
            if (nih_storage_fatfs_session_end(s.card_report.generation) != 1) return error.Busy;
            s.card_context = null;
            s.path = null;
            s.card_report.destroyed = 1;
            return;
        }
        if (nih_fatfs_backend_destroy(state().backend.?.session, state().backend.?.epoch) != 0) return error.Busy;
    }
};
noinline fn serve() i32 {
    stage(20);
    const painted = nih_sqlite_stack_paint(bounds[0].low);
    const s = state();
    while (handles[1].load(.acquire) == 0) wait();
    const client = handles[1].load(.acquire);
    s.old_client = client;
    s.service_owner = manager().open(.vfs, .{ .external = memory.parent_bytes }) catch fail();
    const disk_size = if (options.fatfs_sd_rpc) nih_fatfs_card_bytes() else nih_fatfs_native_disk_bytes();
    const fs_size = if (options.fatfs_sd_rpc) 8 else nih_fatfs_backend_bytes();
    s.layout = memory.Layout.make(disk_size, fs_size, @sizeOf(Owner), @sizeOf(rpc.Queues)) catch fail();
    s.parent = memory.Parent.reserve(manager(), s.service_owner.?) catch fail();
    const bytes = s.parent.?.borrow.?.bytes;
    const disk: *anyopaque = @ptrCast(bytes.ptr + s.layout.?.disk);
    if (options.fatfs_sd_rpc) {
        // Retain the immutable decoder self-check as an auxiliary input only.
        check(nih_fatfs_fixture_read(null, 0, bytes.ptr) == 0);
        var generation: u32 = 0;
        const sectors = nih_storage_fatfs_session_begin(&generation);
        check(sectors != 0);
        check(nih_fatfs_card_mount(disk, disk_size, sectors, generation, &s.card_context, &s.card_report) == 1);
        s.path = nih_fatfs_card_path(s.card_context.?, generation) orelse fail();
        s.backend = .{ .session = nih_fatfs_card_backend(s.card_context.?, generation) orelse fail(), .epoch = generation };
        s.report.version = 2;
        s.report.source = 2;
        stage(22);
    } else {
        check(nih_fatfs_fixture_bind(disk, 1) == 0);
        stage(21);
        const session = nih_fatfs_backend_init(bytes.ptr + s.layout.?.backend, fs_size, disk, 1) orelse fail();
        check(nih_fatfs_backend_mount(session, 1) == 0);
        stage(22);
        s.backend = .{ .session = session, .epoch = 1 };
    }
    queues().* = .{};
    owner().* = .{ .notifications = &notifications, .client = client };
    s.root = owner().start(&s.backend.?) catch fail();
    newClient();
    bound_epoch.store(1, .release);
    ready.store(1, .release);
    stage(23);
    signal(1);
    while (owner().alive) {
        if (owner().step(queues())) signal(1) else wait();
    }
    check(io_armed.load(.acquire) == 4 and owner().discarded_requests == 1 and owner().discarded_responses == 1);
    stage(30);
    check((manager().ownerStats(s.service_owner.?) catch fail()).used.external == memory.parent_bytes);
    s.report.forced_exit = 1;
    s.report.discarded_requests = owner().discarded_requests;
    s.report.discarded_replies = owner().discarded_responses;
    reapClient();
    // CPU1 has stopped the original client and has not yet reused its stack.
    s.report.client_stack = measure(1, s.client_painted);
    cleanup.store(1, .release);
    signal(1);
    while (handles[1].load(.acquire) == client) wait();
    check(owner().rebind(queues(), handles[1].load(.acquire)));
    stage(40);
    newClient();
    s.root = rpc.Token.from(owner().root.?);
    bound_epoch.store(2, .release);
    nih_storage_task_exited(1, client); // Exact stopped generation must be ignored.
    owner().response = .{ .epoch = 1, .sequence = 1, .status = -9 };
    check(queues().responses.tryPushFrom(&owner().response));
    s.report.rebound = 1;
    ready.store(1, .release);
    signal(1);
    while (owner().alive) {
        if (owner().step(queues())) signal(1) else wait();
    }
    reapClient();
    s.report.parent_used = @intCast(s.layout.?.used);
    s.report.parent_charged = s.parent.?.lease.charged;
    s.report.fixture_id = if (options.fatfs_sd_rpc) 0 else nih_fatfs_fixture_id();
    const lease = s.parent.?.retire(manager(), owner(), queues(), Filesystem{}) catch fail();
    for (lease.bytes) |byte| check(byte == 0);
    manager().free(s.service_owner.?, lease) catch fail();
    s.report.parent_cleared = 1;
    if (options.fatfs_sd_rpc) {
        s.card_report.charged = memory.parent_bytes;
        s.card_report.cleared = 1;
    }
    s.report.owner_stack = measure(0, painted);
    s.report.stale_exit = stale_exits.load(.acquire);
    cleanup.store(2, .release);
    signal(1);
    return 300;
}
fn send(operation: rpc.Operation, token: rpc.Token, path: []const u8, offset: u64, length: u32) void {
    const frame = frames();
    frame.request = .{ .epoch = bound_epoch.load(.acquire), .sequence = state().next_sequence, .operation = @backingInt(operation), .token = token, .offset = offset, .length = length, .path_length = @intCast(path.len) };
    @memcpy(frame.request.path[0..path.len], path);
    while (!owner().submit(queues(), currentHandle(), &frame.request)) wait();
    state().next_sequence += 1;
    state().report.requests += 1;
    signal(0);
}
fn receive(sequence: u32) *rpc.Response {
    while (true) {
        if (queues().responses.tryPopInto(&frames().response)) {
            signal(0);
            if (!rpc.responseMatches(&frames().response, bound_epoch.load(.acquire), sequence)) {
                state().report.stale_reply += 1;
                continue;
            }
            state().report.replies += 1;
            return &frames().response;
        }
        if (sequence == 2 and inflight.load(.acquire) == 1) {
            check(notifications.cancelRead(currentHandle(), bound_epoch.load(.acquire), sequence));
            inflight.store(2, .release);
            signal(0);
        }
        wait();
    }
}
noinline fn runClient() i32 {
    const painted = nih_sqlite_stack_paint(bounds[1].low);
    state().client_painted = painted;
    while (ready.load(.acquire) == 0) wait();
    check(currentHandle() == handles[1].load(.acquire));
    const s = state();
    if (bound_epoch.load(.acquire) == 1) {
        send(.open, s.root, if (options.fatfs_sd_rpc) std.mem.span(s.path.?) else "fragment.bin", 0, 0);
        const opened = receive(1);
        check(opened.status == 0);
        s.old_file = opened.token;
        io_armed.store(1, .release);
        send(.read, s.old_file, "", 0, 4096);
        const cancelled = receive(2);
        check(cancelled.status == -125 and cancelled.length == 0);
        for (&cancelled.data) |byte| check(byte == 0);
        s.report.cancelled = 1;
        inflight.store(0, .release);
        if (options.fatfs_sd_rpc) {
            send(.close, s.old_file, "", 0, 0);
            check(receive(3).status == 0);
            send(.open, s.root, std.mem.span(s.path.?), 0, 0);
            const reopened = receive(4);
            check(reopened.status == 0);
            s.old_file = reopened.token;
        }
        // Queue a read and a request that must never execute after this exit.
        io_armed.store(2, .release);
        send(.read, s.old_file, "", if (options.fatfs_sd_rpc) 0 else 512, 4096);
        send(.read, s.old_file, "", 0, 1);
        signal(0);
        _ = receive(if (options.fatfs_sd_rpc) 5 else 3);
        fail();
    }
    frames().request = .{ .epoch = 1, .sequence = 1, .operation = 4, .token = s.old_file };
    check(!owner().submit(queues(), currentHandle(), &frames().request));
    s.report.stale_epoch = 1;
    send(.read, s.old_file, "", 0, 1);
    check(receive(1).status == -9);
    s.report.stale_handle = 1;
    send(.open, s.root, if (options.fatfs_sd_rpc) std.mem.span(s.path.?) else "Memo.txt", 0, 0);
    const opened = receive(2);
    check(opened.status == 0);
    const file = opened.token;
    send(.read, file, "", 0, 4096);
    const read = receive(3);
    check(read.status == 0 and read.length > 0);
    s.report.bytes = read.length;
    s.report.crc = std.hash.Crc32.hash(read.data[0..read.length]);
    if (options.fatfs_sd_rpc) {
        s.card_report.bytes = read.length;
        s.card_report.crc = s.report.crc;
        send(.read, file, "", 0, 4096);
        const repeated = receive(4);
        check(repeated.status == 0 and repeated.length == s.card_report.bytes);
        s.card_report.repeated_crc = std.hash.Crc32.hash(repeated.data[0..repeated.length]);
        check(s.card_report.crc == s.card_report.repeated_crc);
    } else {
        check(read.length == "nihos read-only fixture\n".len);
        check(s.report.crc == std.hash.Crc32.hash("nihos read-only fixture\n"));
    }
    send(.close, file, "", 0, 0);
    check(receive(if (options.fatfs_sd_rpc) 5 else 4).status == 0);
    s.report.client_stack = @max(s.report.client_stack, measure(1, painted));
    return 301;
}
pub export fn nih_storage_task_entry(hart: u32) callconv(.c) i32 {
    return if (hart == 0) serve() else runClient();
}
pub export fn nih_storage_runtime_finish(out: *Report) callconv(.c) void {
    stage(50);
    const s = state();
    check(retired.load(.acquire) == 3 and s.parent.?.borrow == null);
    // Both actual kernel tasks have been reaped before closing this account.
    manager().beginClose(s.service_owner.?) catch fail();
    check((manager().reclaimOne(s.service_owner.?) catch fail()) == .complete);
    check(manager().stats(.external).free == dev.external_bytes and manager().stats(.internal).free == dev.internal_bytes);
    s.report.recovered = 1;
    s.report.status = 1;
    if (options.fatfs_sd_rpc) {
        s.card_report.status = 1;
        s.card_report.recovered = 1;
    }
    out.* = s.report;
}
fn cardRpcReport(out: *card.Report) callconv(.c) void {
    check(retired.load(.acquire) == 3);
    out.* = state().card_report;
}
comptime {
    if (options.fatfs_sd_rpc) @export(&cardRpcReport, .{ .name = "nih_fatfs_card_rpc_report" });
}
