const std = @import("std");
const rpc = @import("vfs_rpc.zig");
const memory = @import("vfs_memory.zig");
const broker = @import("../kernel/memory_broker.zig");
const equal = std.testing.expectEqual;
const expect = std.testing.expect;
const expectError = std.testing.expectError;
const Fake = struct {
    notifications: ?*rpc.Notifications = null,
    event: enum { none, cancel, exit } = .none,
    reads: u32 = 0,
    closes: u32 = 0,
    last_offset: u64 = 0,
    pub fn lookupBeneath(_: *@This(), _: u64, _: []const u8) rpc.api.Error!u64 {
        return 7;
    }
    pub fn open(_: *@This(), _: u64, _: rpc.api.Rights) rpc.api.Error!u64 {
        return 9;
    }
    pub fn close(self: *@This(), _: u64) rpc.api.Error!void {
        self.closes += 1;
    }
    pub fn readAt(self: *@This(), _: u64, offset: u64, bytes: []u8) rpc.api.Transfer {
        self.reads += 1;
        self.last_offset = offset;
        @memset(bytes, 0x42);
        if (self.notifications) |notification| switch (self.event) {
            .none => {},
            .cancel => std.debug.assert(notification.cancelRead(42, 1, 2)),
            .exit => std.debug.assert(notification.notifyExit(42, 1)),
        };
        return .{ .transferred = bytes.len };
    }
    pub fn writeAt(_: *@This(), _: u64, _: u64, _: []const u8) rpc.api.Transfer {
        unreachable;
    }
    pub fn syncFile(_: *@This(), _: u64) rpc.api.Error!void {
        unreachable;
    }
    pub fn syncVolume(_: *@This(), _: u64) rpc.api.Error!void {
        unreachable;
    }
};
const Service = rpc.Owner(Fake);
fn open(service: *Service, queues: *rpc.Queues, root: rpc.Token) !rpc.Token {
    var request = rpc.Request{ .epoch = 1, .sequence = 1, .operation = 3, .token = root, .path_length = 1 };
    request.path[0] = 'a';
    try expect(service.submit(queues, 42, &request));
    try expect(service.step(queues));
    var response = rpc.Response{};
    try expect(queues.responses.tryPopInto(&response));
    try equal(@as(i32, 0), response.status);
    return response.token;
}
test "copy-only v2 authenticates binding and carries full offsets and reply credit" {
    var notifications = rpc.Notifications{};
    var backend = Fake{};
    var service = Service{ .notifications = &notifications, .client = 42 };
    var queues = rpc.Queues{};
    const root = try service.start(&backend);
    const file = try open(&service, &queues, root);
    var request = rpc.Request{ .epoch = 1, .sequence = 2, .operation = 4, .token = file, .offset = 0x100000008, .length = 4096 };
    try expect(!service.submit(&queues, 7, &request));
    try expect(queues.responses.tryPush(.{}));
    try expect(queues.responses.tryPush(.{}));
    try expect(service.submit(&queues, 42, &request));
    request.offset = 0; // Published copy must retain the 64-bit offset.
    try expect(!service.step(&queues));
    try equal(@as(u32, 0), backend.reads);
    var response = rpc.Response{};
    try expect(queues.responses.tryPopInto(&response));
    try expect(queues.responses.tryPopInto(&response));
    try expect(service.step(&queues));
    try expect(queues.responses.tryPopInto(&response));
    try equal(@as(u64, 0x100000008), backend.last_offset);
    try equal(@as(u32, 4096), response.length);
    try expect(rpc.responseMatches(&response, 1, 2));
    try expect(!rpc.responseMatches(&response, 2, 2));
}
test "read cancellation scrubs the reply only after backend completion" {
    var notifications = rpc.Notifications{};
    var backend = Fake{ .notifications = &notifications, .event = .cancel };
    var service = Service{ .notifications = &notifications, .client = 42 };
    var queues = rpc.Queues{};
    const file = try open(&service, &queues, try service.start(&backend));
    var request = rpc.Request{ .epoch = 1, .sequence = 2, .operation = 4, .token = file, .length = 4096 };
    try expect(!notifications.cancelRead(42, 1, 2));
    try expect(service.submit(&queues, 42, &request) and service.step(&queues));
    var response = rpc.Response{};
    try expect(queues.responses.tryPopInto(&response));
    try equal(@as(i32, -125), response.status);
    try equal(@as(u32, 1), backend.reads);
    try equal(@as(u32, 0), response.length);
    for (response.data) |byte| try equal(@as(u8, 0), byte);
    try expect(!notifications.cancelRead(42, 1, 2));
    backend.event = .none;
    request.sequence = 3;
    try expect(service.submit(&queues, 42, &request) and service.step(&queues));
    try expect(queues.responses.tryPopInto(&response));
    try equal(@as(i32, 0), response.status);
}
test "exit during read drains copies then rebind rejects old notifications and handles" {
    var notifications = rpc.Notifications{};
    var backend = Fake{ .notifications = &notifications, .event = .exit };
    var service = Service{ .notifications = &notifications, .client = 42 };
    var queues = rpc.Queues{};
    const root = try service.start(&backend);
    const file = try open(&service, &queues, root);
    var request = rpc.Request{ .epoch = 1, .sequence = 2, .operation = 4, .token = file, .length = 4096 };
    try expect(queues.responses.tryPush(.{}));
    try expect(service.submit(&queues, 42, &request));
    request.sequence = 3;
    try expect(service.submit(&queues, 42, &request));
    try expect(service.step(&queues));
    try expect(!service.alive and service.rebind_ready);
    try equal(@as(u32, 1), backend.reads);
    try equal(@as(u32, 1), backend.closes);
    try equal(@as(u32, 1), service.discarded_requests);
    try equal(@as(u32, 2), service.discarded_responses);
    try expect(service.rebind(&queues, 43));
    try expect(!notifications.notifyExit(42, 1));
    try expect(!notifications.cancelRead(42, 1, 2));
    try expect(!service.submit(&queues, 42, &request));
    request.epoch = 2;
    request.sequence = 1;
    try expect(service.submit(&queues, 43, &request) and service.step(&queues));
    var response = rpc.Response{};
    try expect(queues.responses.tryPopInto(&response));
    try equal(@as(i32, -9), response.status);
    try expect(notifications.notifyExit(43, 2));
    try expect(service.step(&queues));
    try service.shutdown(&queues);
    try service.shutdown(&queues); // Private FS teardown may need a retry.
}
test "memory admission and teardown keep the broker pin through private FS failure" {
    const layout = try memory.Layout.make(4152, 15712, @sizeOf(Service), @sizeOf(rpc.Queues));
    try expect(layout.used <= memory.parent_bytes);
    try expectError(error.TooLarge, memory.Layout.make(65536, 1, 1, 1));
    var payload: [32 * 4096]u8 align(4096) = @splat(0);
    var policy = broker.Policy{};
    policy.groups[@backingInt(broker.Group.vfs)].external = memory.parent_bytes;
    var manager = broker.Broker(1, 32, 4, 2, 4){};
    try expect(manager.init(&.{}, &.{.{ .memory = &payload }}, policy));
    const owner = try manager.open(.vfs, .{ .external = memory.parent_bytes });
    var parent = try memory.Parent.reserve(&manager, owner);
    try expectError(error.Busy, manager.free(owner, parent.lease));
    const Endpoint = struct {
        pub fn shutdown(_: *@This(), _: *u8) !void {}
    };
    const Filesystem = struct {
        busy: bool = true,
        pub fn destroy(self: *@This()) error{Busy}!void {
            if (self.busy) return error.Busy;
        }
    };
    var endpoint = Endpoint{};
    var filesystem = Filesystem{};
    var queue: u8 = 0;
    try manager.beginClose(owner);
    try expectError(error.Busy, parent.retire(&manager, &endpoint, &queue, &filesystem));
    try equal(broker.Reclaim.waiting, try manager.reclaimOne(owner));
    try expect(parent.borrow != null);
    filesystem.busy = false;
    _ = try parent.retire(&manager, &endpoint, &queue, &filesystem);
    for (payload[0..memory.parent_bytes]) |byte| try equal(@as(u8, 0), byte);
    try equal(broker.Reclaim.released, try manager.reclaimOne(owner));
    try equal(broker.Reclaim.complete, try manager.reclaimOne(owner));
}

test "malformed versioned messages never reach the backend and consume only current sequences" {
    var notification = rpc.Notifications{};
    var fake = Fake{};
    var service = Service{ .notifications = &notification, .client = 42 };
    var queues = rpc.Queues{};
    const root = try service.start(&fake);
    var request = rpc.Request{ .epoch = 1, .sequence = 1, .version = 1, .operation = 4, .token = root };
    var response = rpc.Response{};
    try expect(service.submit(&queues, 42, &request) and service.step(&queues));
    try expect(queues.responses.tryPopInto(&response));
    try equal(@as(i32, -13), response.status);
    try equal(@as(u32, 1), service.next_sequence);
    request.version = 2;
    request.length = 4097;
    try expect(service.submit(&queues, 42, &request) and service.step(&queues));
    try expect(queues.responses.tryPopInto(&response));
    try equal(@as(i32, -27), response.status);
    request.sequence = 2;
    request.length = 1;
    request.token.reserved = 1;
    try expect(service.submit(&queues, 42, &request) and service.step(&queues));
    try expect(queues.responses.tryPopInto(&response));
    try equal(@as(i32, -9), response.status);
    try equal(@as(u32, 0), fake.reads);
}

test "a stopped consumer cannot deadlock cleanup behind a full response queue" {
    var notification = rpc.Notifications{};
    var fake = Fake{};
    var service = Service{ .notifications = &notification, .client = 42 };
    var queues = rpc.Queues{};
    _ = try service.start(&fake);
    try expect(queues.responses.tryPush(.{}) and queues.responses.tryPush(.{}));
    try expect(queues.requests.tryPush(.{}) and queues.requests.tryPush(.{}));
    try expect(!notification.notifyExit(7, 1));
    try expect(notification.notifyExit(42, 1));
    try expect(service.step(&queues));
    try equal(@as(u32, 2), service.discarded_requests);
    try equal(@as(u32, 2), service.discarded_responses);
    try expect(service.rebind_ready);
}

test "binding sequence and notification exhaustion never wrap into an old request" {
    var notification = rpc.Notifications{};
    var fake = Fake{};
    var service = Service{ .notifications = &notification, .client = 42, .epoch = 0x7fffffff };
    var queues = rpc.Queues{};
    const root = try service.start(&fake);
    service.next_sequence = std.math.maxInt(u32);
    var request = rpc.Request{ .epoch = service.epoch, .sequence = service.next_sequence, .operation = 999, .token = root };
    var response = rpc.Response{};
    try expect(service.submit(&queues, 42, &request) and service.step(&queues));
    try expect(queues.responses.tryPopInto(&response));
    try equal(@as(u32, 0), service.next_sequence);
    request.sequence = 0;
    try expect(service.submit(&queues, 42, &request) and service.step(&queues));
    try expect(queues.responses.tryPopInto(&response));
    try equal(@as(i32, -22), response.status);
    notification.signal.next_ticket = 1 << 30;
    request.sequence = 1;
    try expect(service.submit(&queues, 42, &request) and service.step(&queues));
    try expect(queues.responses.tryPopInto(&response));
    try equal(@as(i32, -28), response.status);
    try expect(notification.notifyExit(42, service.epoch));
    try expect(service.step(&queues));
    try expect(!service.rebind(&queues, 43));
    try service.shutdown(&queues);
}

test "parent pin admission failure rolls back the complete charged allocation" {
    var bytes: [64 * 4096]u8 align(4096) = @splat(0);
    var policy = broker.Policy{};
    policy.groups[@backingInt(broker.Group.vfs)].external = 2 * memory.parent_bytes;
    var manager = broker.Broker(1, 64, 4, 2, 1){};
    try expect(manager.init(&.{}, &.{.{ .memory = &bytes }}, policy));
    const owner = try manager.open(.vfs, .{ .external = 2 * memory.parent_bytes });
    const lease = try manager.alloc(owner, .external, 4096, 64);
    const pin = try manager.pin(owner, lease);
    const free = manager.stats(.external).free;
    try expectError(error.Full, memory.Parent.reserve(&manager, owner));
    try equal(free, manager.stats(.external).free);
    try equal(@as(u32, 4096), (try manager.ownerStats(owner)).used.external);
    try manager.unpin(pin.token);
    try manager.free(owner, lease);
}
