const std = @import("std");
const support = @import("storage_vfs");
const rpc = support.rpc;
const dev = support.development;
const mem = support.memory;
const adapter = support.fatfs;
const Owner = rpc.Owner(adapter.Backend);
const equal = std.testing.expectEqual;
const expect = std.testing.expect;
const expectError = std.testing.expectError;
extern fn host_backend_session() *adapter.Session;
extern fn host_backend_epoch() u64;
extern fn host_backend_reads() u32;
extern fn host_rpc_arm(u32) void;
extern fn host_rpc_kind() u32;
extern fn host_test_failure([*:0]const u8) void;
extern fn host_backend_destroy() c_int;

// Host-owned stand-in backing for the UNCHANGED generated development policy.
// No physical address registration or device execution is claimed.
var internal: [dev.internal_bytes]u8 align(4096) = @splat(0);
var external: [dev.external_bytes]u8 align(4096) = @splat(0);
var manager: dev.Manager = .{};
var parent: ?mem.Parent = null;
var layout: ?mem.Layout = null;
var service_owner: ?dev.api.Owner = null;
var client_owner: ?dev.api.Owner = null;
var client_lease: ?dev.api.Lease = null;
const ClientFrames = rpc.ClientFrames;
fn clientFrames() *ClientFrames {
    return @ptrCast(@alignCast(client_lease.?.bytes.ptr));
}
fn newClient() !void {
    client_owner = try manager.open(.vm, .{ .external = 8192 });
    client_lease = try manager.alloc(client_owner.?, .external, @sizeOf(ClientFrames), 128);
    clientFrames().* = .{};
}
var notifications: rpc.Notifications = .{};
var backend: ?adapter.Backend = null;
var event_seen: u32 = 0;
fn endpoint() *Owner {
    return @ptrCast(@alignCast(parent.?.borrow.?.bytes.ptr + layout.?.endpoint));
}
fn queues() *rpc.Queues {
    return @ptrCast(@alignCast(parent.?.borrow.?.bytes.ptr + layout.?.queues));
}
const Filesystem = struct {
    pub fn destroy(_: @This()) error{Busy}!void {
        if (host_backend_destroy() != 0) return error.Busy;
    }
};
fn prepare(disk: u32, fs: u32, disk_address: *usize, fs_address: *usize) !void {
    try expect(manager.init(&.{.{ .memory = &internal }}, &.{.{ .memory = &external }}, dev.policy));
    service_owner = try manager.open(.vfs, .{ .external = mem.parent_bytes });
    try newClient();
    layout = try mem.Layout.make(disk, fs, @sizeOf(Owner), @sizeOf(rpc.Queues));
    parent = try mem.Parent.reserve(&manager, service_owner.?);
    const bytes = parent.?.borrow.?.bytes;
    disk_address.* = @intFromPtr(bytes.ptr + layout.?.disk);
    fs_address.* = @intFromPtr(bytes.ptr + layout.?.backend);
    queues().* = .{};
    endpoint().* = .{ .notifications = &notifications, .client = 42 };
}
export fn nih_rpc_prepare(disk: u32, fs: u32, disk_address: *usize, fs_address: *usize) callconv(.c) c_int {
    prepare(disk, fs, disk_address, fs_address) catch |err| {
        host_test_failure(@errorName(err).ptr);
        return 1;
    };
    return 0;
}
fn stoppedClient() !void {
    // This fixture's client account has one stopped actor. An endpoint exit
    // alone does not authorize closing an app with running sibling tasks.
    try manager.beginClose(client_owner.?);
    try equal(dev.api.Reclaim.released, try manager.reclaimOne(client_owner.?));
    try equal(dev.api.Reclaim.complete, try manager.reclaimOne(client_owner.?));
    client_owner = null;
    client_lease = null;
}
fn event(kind: u32) !void {
    event_seen += 1;
    const owner = endpoint();
    try expect(owner.in_step);
    try expectError(error.WrongOwner, manager.free(client_owner.?, parent.?.lease));
    try expectError(error.Busy, manager.free(service_owner.?, parent.?.lease));
    try expectError(error.Busy, parent.?.retire(&manager, owner, queues(), Filesystem{}));
    try expect(parent.?.borrow != null);
    if (kind == 1) {
        try expect(notifications.cancelRead(owner.client, owner.epoch, owner.request.sequence));
        try expect(!notifications.cancelRead(owner.client, owner.epoch, owner.request.sequence + 1));
    } else {
        try expect(notifications.notifyExit(owner.client, owner.epoch));
        try stoppedClient();
    }
    try equal(@as(u32, mem.parent_bytes), (try manager.ownerStats(service_owner.?)).used.external);
}
export fn nih_rpc_event(kind: u32) callconv(.c) void {
    event(kind) catch |err| {
        host_test_failure(@errorName(err).ptr);
        @panic("RPC callback lifetime failure");
    };
}
fn request(sequence: u32, operation: rpc.Operation, token: rpc.Token) *rpc.Request {
    const target = &clientFrames().request;
    target.* = .{ .sequence = sequence, .operation = @backingInt(operation), .epoch = endpoint().epoch, .token = token };
    return target;
}
fn publish(source: *const rpc.Request) !void {
    try expect(endpoint().submit(queues(), endpoint().client, source));
}
fn receive(sequence: u32) !void {
    try expect(queues().responses.tryPopInto(&clientFrames().response));
    try expect(rpc.responseMatches(&clientFrames().response, endpoint().epoch, sequence));
}
fn check() !void {
    backend = .{ .session = host_backend_session(), .epoch = host_backend_epoch() };
    const root = try endpoint().start(&backend.?);
    var open_request = request(1, .open, root);
    const name = if (host_rpc_kind() == 3) "large.bin" else "fragment.bin";
    open_request.path_length = @intCast(name.len);
    @memcpy(open_request.path[0..name.len], name);
    try publish(open_request);
    try expect(endpoint().step(queues()));
    try receive(1);
    try equal(@as(i32, 0), clientFrames().response.status);
    const file = clientFrames().response.token;
    var read_request = request(2, .read, file);
    read_request.offset = if (host_rpc_kind() == 3) 0x100001ff0 else 0;
    read_request.length = if (host_rpc_kind() == 3) 16 else 1;
    try publish(read_request);
    try expect(endpoint().step(queues()));
    if (host_rpc_kind() == 3) {
        try receive(2);
        try equal(@as(u32, 16), clientFrames().response.length);
        for (clientFrames().response.data[0..16], 0..) |byte, i| try equal(@as(u8, @intCast(0xc0 + i)), byte);
        try expect(notifications.notifyExit(42, 1));
        try stoppedClient();
        try expect(endpoint().step(queues()));
        return;
    }
    // Leave a valid earlier reply unread while the next operation is active.
    read_request = request(3, .read, file);
    read_request.offset = 512;
    read_request.length = 4096;
    try publish(read_request);
    if (host_rpc_kind() == 2) {
        read_request = request(4, .read, file);
        read_request.length = 1;
        try publish(read_request);
    }
    host_rpc_arm(host_rpc_kind());
    try expect(endpoint().step(queues()));
    try equal(@as(u32, 1), event_seen);
    if (host_rpc_kind() == 1) {
        try receive(2);
        try receive(3);
        try equal(@as(i32, -125), clientFrames().response.status);
        try equal(@as(u32, 0), clientFrames().response.length);
        for (clientFrames().response.data) |byte| try equal(@as(u8, 0), byte);
        try expect(endpoint().alive);
        try expect(notifications.notifyExit(42, 1));
        try stoppedClient();
        try expect(endpoint().step(queues()));
    } else {
        try expect(!endpoint().alive);
        try equal(@as(u32, 1), endpoint().discarded_requests);
        try equal(@as(u32, 2), endpoint().discarded_responses);
    }
    try expect(endpoint().rebind(queues(), 43));
    try newClient();
    try expect(!notifications.notifyExit(42, 1));
    try expect(!notifications.cancelRead(42, 1, 3));
    const before = host_backend_reads();
    read_request = request(1, .read, file);
    read_request.length = 1;
    try publish(read_request);
    try expect(endpoint().step(queues()));
    try receive(1);
    try equal(@as(i32, -9), clientFrames().response.status);
    try equal(before, host_backend_reads());
    open_request = request(2, .open, rpc.Token.from(endpoint().root.?));
    open_request.path_length = 8;
    @memcpy(open_request.path[0..8], "Memo.txt");
    try publish(open_request);
    try expect(endpoint().step(queues()));
    try receive(2);
    try equal(@as(i32, 0), clientFrames().response.status);
    read_request = request(3, .read, clientFrames().response.token);
    read_request.length = 4096;
    try publish(read_request);
    try expect(endpoint().step(queues()));
    try receive(3);
    try equal(@as(i32, 0), clientFrames().response.status);
    try std.testing.expectEqualStrings("nihos read-only fixture\n", clientFrames().response.data[0..clientFrames().response.length]);
    try expect(notifications.notifyExit(43, 2));
    try stoppedClient();
    try expect(endpoint().step(queues()));
}
export fn nih_check_rpc() callconv(.c) c_int {
    check() catch |err| {
        host_test_failure(@errorName(err).ptr);
        return 1;
    };
    return 0;
}
fn finish() !void {
    try expect(!endpoint().alive and notifications.signal.active() == 0);
    const lease = try parent.?.retire(&manager, endpoint(), queues(), Filesystem{});
    try expect(parent.?.borrow == null);
    for (lease.bytes) |byte| try equal(@as(u8, 0), byte);
    try manager.free(service_owner.?, lease);
    try manager.beginClose(service_owner.?);
    try equal(dev.api.Reclaim.complete, try manager.reclaimOne(service_owner.?));
    try equal(@as(u32, dev.external_bytes), manager.stats(.external).free);
}
export fn nih_rpc_finish() callconv(.c) c_int {
    finish() catch |err| {
        host_test_failure(@errorName(err).ptr);
        return 1;
    };
    return 0;
}
export fn nih_rpc_metric(which: u32) callconv(.c) u32 {
    return @intCast(switch (which) {
        0 => layout.?.used,
        1 => mem.parent_bytes,
        2 => @sizeOf(Owner),
        3 => @sizeOf(rpc.Queues),
        else => @sizeOf(rpc.Notifications),
    });
}
