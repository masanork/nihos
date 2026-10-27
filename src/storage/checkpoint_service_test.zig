const std = @import("std");
const api = @import("checkpoint_service.zig");
const model = api.model;
const media = @import("model_media.zig");
const equal = std.testing.expectEqual;
const expect = std.testing.expect;
const expectError = std.testing.expectError;
const page = model.page_bytes;
const Backend = media.Media(64 * page);
const Device = struct {
    pub const capacity: u64 = 16 * 1024 * 1024 * 1024;
    backend: *Backend,
    fail_offset: ?u64 = null,
    writes: usize = 0,
    pub fn read(self: *@This(), offset: u64, bytes: []u8) error{Io}!void {
        if (self.fail_offset == offset) return error.Io;
        return self.backend.read(offset, bytes);
    }
    pub fn write(self: *@This(), offset: u64, bytes: []const u8) error{Io}!void {
        self.writes += bytes.len;
        return self.backend.write(offset, bytes);
    }
    pub fn sync(self: *@This()) error{Io}!void {
        return self.backend.sync();
    }
};
const Store = model.Store(Device, .{ .leaf_pages = 1, .index_pages = 8, .leaf_cache_pages = 1, .payload_window_bytes = 1, .payload_reserve_pages = Device.capacity / page - 64 });
const Owner = api.Owner(Store);
const Queues = api.Queues(@import("../kernel/spsc_ring.zig"));
const payload: [5003]u8 = @splat(0xa7);
fn seed(store: *Store, device: *Device) !u64 {
    try store.format(device);
    try store.begin();
    try store.put(1, &payload);
    try store.put(2, &payload);
    try store.commit();
    const data = (try store.get(1)).first;
    try store.begin();
    try store.promoteMapped(1);
    try store.promoteMapped(2);
    try store.commit();
    return data;
}
fn request(owner: *Owner, handle: api.Handle, op: api.Operation) api.Request {
    return .{ .epoch = owner.epoch, .sequence = owner.next_sequence, .handle = handle, .operation = @backingInt(op) };
}
fn send(owner: *Owner, queues: *Queues, req: api.Request) !api.Response {
    try expect(queues.requests.tryPush(req));
    for (0..10000) |_| switch (owner.step(queues, .{ .leaf_visits = 1, .bitmap_pages = 1 })) {
        .idle => return error.UnexpectedIdle,
        .pending => {},
        .completed => return queues.responses.tryPop() orelse error.MissingReply,
    };
    return error.DidNotFinish;
}
fn write(owner: *Owner, queues: *Queues, handle: api.Handle, offset: u64, bytes: []const u8) !api.Response {
    var req = request(owner, handle, .write);
    req.offset = offset;
    req.length = @intCast(bytes.len);
    @memcpy(req.data[0..bytes.len], bytes);
    return send(owner, queues, req);
}
fn read(owner: *Owner, queues: *Queues, handle: api.Handle, offset: u64, length: u32) !api.Response {
    var req = request(owner, handle, .read);
    req.offset = offset;
    req.length = length;
    return send(owner, queues, req);
}
test "checkpoint service owns queued copies and separates staged read from durable sync" {
    var backend = Backend{};
    var device = Device{ .backend = &backend };
    var store = Store{};
    _ = try seed(&store, &device);
    var owner = try Owner.init(&store, 11);
    var queues = Queues{};
    const handle = try owner.grant(1, true);
    var req = request(&owner, handle, .write);
    req.offset = page - 1;
    req.length = 3;
    @memcpy(req.data[0..3], "XYZ");
    try expect(queues.requests.tryPush(req));
    @memset(req.data[0..3], 0xff);
    try equal(api.Work.pending, owner.step(&queues, .{}));
    while (owner.step(&queues, .{}) == .pending) {}
    const staged = queues.responses.tryPop().?;
    try equal(api.Status.ok, staged.status);
    try equal(api.Visibility.staged, staged.visibility);
    try equal(@as(u64, 3), staged.generation);
    try equal(@as(u32, 3), staged.transferred);
    const own = try read(&owner, &queues, handle, page - 1, 3);
    try std.testing.expectEqualSlices(u8, "XYZ", own.data[0..3]);
    var old: [3]u8 = undefined;
    _ = try store.read(1, page - 1, &old);
    try std.testing.expectEqualSlices(u8, &.{ 0xa7, 0xa7, 0xa7 }, &old);
    try equal(api.Status.busy, (try send(&owner, &queues, request(&owner, handle, .close))).status);
    const synced = try send(&owner, &queues, request(&owner, handle, .sync));
    try equal(api.Visibility.committed, synced.visibility);
    try equal(@as(u64, 4), synced.generation);
    _ = try write(&owner, &queues, handle, 0, "cancel me");
    try equal(api.Status.ok, (try send(&owner, &queues, request(&owner, handle, .cancel))).status);
    const kept = try read(&owner, &queues, handle, 0, 1);
    try equal(@as(u8, 0xa7), kept.data[0]);
    backend.powerLoss();
    var recovered = Store{};
    try recovered.recover(&device);
    _ = try recovered.read(1, page - 1, &old);
    try std.testing.expectEqualSlices(u8, "XYZ", &old);
}
test "checkpoint service refuses malformed batches ranges rights and stale epoch before writes" {
    var backend = Backend{};
    var device = Device{ .backend = &backend };
    var store = Store{};
    _ = try seed(&store, &device);
    var owner = try Owner.init(&store, 11);
    var queues = Queues{};
    const handle = try owner.grant(1, true);
    const ro = try owner.grant(1, false);
    const before = device.writes;
    try equal(api.Status.denied, (try write(&owner, &queues, ro, 0, "no")).status);
    var req = request(&owner, handle, .batch);
    req.length = 1;
    req.part_count = 17;
    try equal(api.Status.invalid, (try send(&owner, &queues, req)).status);
    req = request(&owner, handle, .batch);
    req.length = 1;
    req.part_count = 1;
    req.parts[0] = .{ .offset = 0, .data_offset = 1, .length = 1 };
    try equal(api.Status.invalid, (try send(&owner, &queues, req)).status);
    req = request(&owner, handle, .batch);
    req.length = 2;
    req.part_count = 2;
    req.parts[0] = .{ .offset = page, .length = 1 };
    req.parts[1] = .{ .offset = 0, .data_offset = 1, .length = 1 };
    try equal(api.Status.invalid, (try send(&owner, &queues, req)).status);
    try equal(api.Status.invalid, (try write(&owner, &queues, handle, payload.len, "x")).status);
    try equal(api.Status.invalid, (try read(&owner, &queues, handle, std.math.maxInt(u64), 1)).status);
    req = request(&owner, handle, .read);
    req.length = 4097;
    try equal(api.Status.invalid, (try send(&owner, &queues, req)).status);
    req = request(&owner, handle, .stat);
    req.epoch += 1;
    const sequence = owner.next_sequence;
    try equal(api.Status.denied, (try send(&owner, &queues, req)).status);
    try equal(sequence, owner.next_sequence);
    try equal(before, device.writes);
    try expect(!store.in_transaction);
}
test "checkpoint service reserves reply credit and cancels stopped binding without executing queued work" {
    var backend = Backend{};
    var device = Device{ .backend = &backend };
    var store = Store{};
    _ = try seed(&store, &device);
    var owner = try Owner.init(&store, 11);
    var queues = Queues{};
    const old_handle = try owner.grant(1, true);
    try expect(queues.responses.tryPush(.{}));
    try expect(queues.responses.tryPush(.{}));
    var req = request(&owner, old_handle, .write);
    req.length = 1;
    req.data[0] = 'X';
    try expect(queues.requests.tryPush(req));
    const before = device.writes;
    try equal(api.Work.idle, owner.step(&queues, .{}));
    try equal(before, device.writes);
    _ = queues.responses.tryPop();
    _ = queues.responses.tryPop();
    try equal(api.Work.pending, owner.step(&queues, .{}));
    req.sequence += 1;
    try expect(queues.requests.tryPush(req));
    req.sequence += 1;
    try expect(queues.requests.tryPush(req));
    try expectError(error.InvalidArgument, owner.clientExited(9, &queues));
    try expect(owner.pending);
    try equal(api.Exit.cancelled_staging, try owner.clientExited(11, &queues));
    try equal(before, device.writes);
    try equal(@as(u32, 1), owner.discarded_pending);
    try equal(@as(u32, 2), owner.discarded_requests);
    for (queues.requests.slots) |slot| for (slot.data) |byte| try equal(@as(u8, 0), byte);
    try expect(owner.rebind(12, &queues));
    const fresh = try owner.grant(1, true);
    req = request(&owner, fresh, .stat);
    req.epoch = 1;
    try equal(api.Status.denied, (try send(&owner, &queues, req)).status);
    try equal(@as(u64, 1), owner.next_sequence);
    req = request(&owner, old_handle, .read);
    req.length = 1;
    try equal(api.Status.stale, (try send(&owner, &queues, req)).status);
    try equal(api.Status.ok, (try read(&owner, &queues, fresh, 0, 1)).status);
    try expectError(error.InvalidArgument, owner.clientExited(11, &queues));
}
test "checkpoint service exit discards successful staging but never undoes a synced unread reply" {
    var backend = Backend{};
    var device = Device{ .backend = &backend };
    var store = Store{};
    _ = try seed(&store, &device);
    var owner = try Owner.init(&store, 11);
    var queues = Queues{};
    var handle = try owner.grant(1, true);
    _ = try write(&owner, &queues, handle, 0, "X");
    try equal(api.Exit.cancelled_staging, try owner.clientExited(11, &queues));
    try expect(owner.rebind(12, &queues));
    handle = try owner.grant(1, true);
    try equal(@as(u8, 0xa7), (try read(&owner, &queues, handle, 0, 1)).data[0]);
    _ = try write(&owner, &queues, handle, 0, "Y");
    const req = request(&owner, handle, .sync);
    try expect(queues.requests.tryPush(req));
    try equal(api.Work.completed, owner.step(&queues, .{})); // peer stops without consuming durable reply
    try equal(api.Exit.clean, try owner.clientExited(12, &queues));
    try equal(@as(u32, 1), owner.discarded_responses);
    try equal(@as(u64, 4), store.generation());
    backend.powerLoss();
    var recovered = Store{};
    try recovered.recover(&device);
    var byte: [1]u8 = undefined;
    _ = try recovered.read(1, 0, &byte);
    try equal(@as(u8, 'Y'), byte[0]);
}
test "checkpoint service sparse truncate and four GiB offsets are visible before sync and survive it" {
    var backend = Backend{};
    var device = Device{ .backend = &backend };
    var store = Store{};
    _ = try seed(&store, &device);
    var owner = try Owner.init(&store, 11);
    var queues = Queues{};
    const handle = try owner.grant(1, true);
    var req = request(&owner, handle, .truncate);
    req.offset = 0;
    try equal(api.Status.ok, (try send(&owner, &queues, req)).status);
    req = request(&owner, handle, .truncate);
    req.offset = 0x1_0000_0001;
    try equal(req.offset, (try send(&owner, &queues, req)).size);
    try equal(api.Status.ok, (try write(&owner, &queues, handle, 0x1_0000_0000, "Z")).status);
    const result = try read(&owner, &queues, handle, 0xffff_ffff, 2);
    try std.testing.expectEqualSlices(u8, &.{ 0, 'Z' }, result.data[0..2]);
    try equal(api.Status.ok, (try send(&owner, &queues, request(&owner, handle, .sync))).status);
    backend.powerLoss();
    var recovered = Store{};
    try recovered.recover(&device);
    try equal(@as(u64, 0x1_0000_0001), (try recovered.get(1)).length);
    var bytes: [2]u8 = undefined;
    _ = try recovered.read(1, 0xffff_ffff, &bytes);
    try std.testing.expectEqualSlices(u8, &.{ 0, 'Z' }, &bytes);
}
test "checkpoint service read failure clears partial reply and stops further device use" {
    var backend = Backend{};
    var device = Device{ .backend = &backend };
    var store = Store{};
    const first = try seed(&store, &device);
    var owner = try Owner.init(&store, 11);
    var queues = Queues{};
    const handle = try owner.grant(1, true);
    device.fail_offset = (first + 1) * page;
    const failed = try read(&owner, &queues, handle, page - 6, 100);
    try equal(api.Status.recovery_required, failed.status);
    try equal(api.Visibility.unknown, failed.visibility);
    try equal(@as(u32, 0), failed.length);
    for (failed.data) |byte| try equal(@as(u8, 0), byte);
    const before = device.writes;
    try equal(api.Status.recovery_required, (try write(&owner, &queues, handle, 0, "X")).status);
    try equal(before, device.writes);
    try equal(api.Exit.recovery_required, try owner.clientExited(11, &queues));
    try expect(!owner.rebind(12, &queues));
}
fn update(store: *Store) !bool {
    var owner = try Owner.init(store, 11);
    var queues = Queues{};
    const a = try owner.grant(1, true);
    const b = try owner.grant(2, true);
    const first = try write(&owner, &queues, a, 1, "X");
    if (first.status != .ok) return false;
    try equal(api.Visibility.staged, first.visibility);
    if ((try write(&owner, &queues, b, 1, "Y")).status != .ok) return false;
    const sync = try send(&owner, &queues, request(&owner, a, .sync));
    if (sync.status != .ok) {
        try equal(api.Status.publication_unknown, sync.status);
        try equal(api.Visibility.unknown, sync.visibility);
        try equal(api.Exit.recovery_required, try owner.clientExited(11, &queues));
        try expect(!owner.rebind(12, &queues));
        return false;
    }
    try equal(api.Visibility.committed, sync.visibility);
    try equal(@as(u64, 4), sync.generation);
    return true;
}
test "checkpoint service multiobject staged writes and durable ack survive every publication cut" {
    var base = Backend{};
    var initial_device = Device{ .backend = &base };
    var initial = Store{};
    _ = try seed(&initial, &initial_device);
    base.powerLoss();
    var cases: usize = 0;
    var events: usize = 0;
    for ([_]media.Background{ .none, .alternating, .all }) |background| for ([_]media.Order{ .ascending, .descending }) |order| {
        var clean = base;
        clean.background = background;
        clean.order = order;
        var device = Device{ .backend = &clean };
        var store = Store{};
        try store.recover(&device);
        try expect(try update(&store));
        events = clean.events;
        clean.powerLoss();
        var acknowledged = Store{};
        try acknowledged.recover(&device);
        try equal(@as(u64, 4), acknowledged.generation());
        for (0..events) |event| for ([_]usize{ 0, 1, 31, 255, 511, 512 }) |prefix| {
            var broken = base;
            broken.background = background;
            broken.order = order;
            var failing = Device{ .backend = &broken };
            var interrupted = Store{};
            try interrupted.recover(&failing);
            broken.cut = .{ .event = event, .prefix = prefix };
            try expect(!try update(&interrupted));
            broken.powerLoss();
            var recovered = Store{};
            try recovered.recover(&failing);
            const new = recovered.generation() == 4;
            try expect(new or recovered.generation() == 3);
            var byte: [1]u8 = undefined;
            _ = try recovered.read(1, 1, &byte);
            try equal(@as(u8, if (new) 'X' else 0xa7), byte[0]);
            _ = try recovered.read(2, 1, &byte);
            try equal(@as(u8, if (new) 'Y' else 0xa7), byte[0]);
            cases += 1;
        };
    };
    try equal(@as(usize, 114), events);
    try equal(@as(usize, 4104), cases);
    std.debug.print("SERVICE_CAMPAIGN events={d} crash_cases={d} acknowledged_cases=6\n", .{ events, cases });
}

test "checkpoint service batch owns full copied pages and can reuse a fragment across sixteen targets" {
    var backend = Backend{};
    var device = Device{ .backend = &backend };
    var store = Store{};
    _ = try seed(&store, &device);
    var owner = try Owner.init(&store, 11);
    var queues = Queues{};
    const handle = try owner.grant(1, true);
    var req = request(&owner, handle, .truncate);
    req.offset = 16 * page;
    try equal(api.Status.ok, (try send(&owner, &queues, req)).status);
    req = request(&owner, handle, .batch);
    req.length = page;
    req.part_count = 16;
    @memset(&req.data, 0x4d);
    for (&req.parts, 0..) |*part, i| part.* = .{ .offset = i * page, .length = page };
    const before = device.writes;
    try expect(queues.requests.tryPush(req));
    @memset(&req.data, 0xff);
    while (owner.step(&queues, .{}) == .pending) {}
    const result = queues.responses.tryPop().?;
    try equal(api.Status.ok, result.status);
    try equal(@as(u32, 16 * page), result.transferred);
    try equal(@as(usize, 18 * page), device.writes - before); // 16 data + shared map + object leaf
    for (0..16) |i| {
        const reply = try read(&owner, &queues, handle, i * page, page);
        try equal(@as(u32, page), reply.length);
        for (reply.data) |byte| try equal(@as(u8, 0x4d), byte);
    }
    try equal(api.Status.ok, (try send(&owner, &queues, request(&owner, handle, .sync))).status);
}
test "checkpoint service NoSpace preserves prior accepted staging and yields during allocation search" {
    var backend = Backend{};
    var device = Device{ .backend = &backend };
    var store = Store{};
    try store.format(&device);
    try store.begin();
    try store.put(1, "");
    try store.commit();
    var scratch = model.MapScratch{};
    try store.begin();
    try store.resizeMapped(1, 16 * page, &scratch);
    const blocker: [34 * page]u8 = @splat(0x19);
    try store.put(2, &blocker);
    try store.commit();
    var owner = try Owner.init(&store, 11);
    var queues = Queues{};
    const handle = try owner.grant(1, true);
    try equal(api.Status.ok, (try write(&owner, &queues, handle, 0, "A")).status);
    var req = request(&owner, handle, .batch);
    req.length = 1;
    req.data[0] = 'B';
    req.part_count = 16;
    for (&req.parts, 0..) |*part, i| part.* = .{ .offset = i * page, .length = 1 };
    try expect(queues.requests.tryPush(req));
    try equal(api.Work.pending, owner.step(&queues, .{}));
    try equal(api.Work.pending, owner.step(&queues, .{ .leaf_visits = 1, .bitmap_pages = 1 }));
    var steps: usize = 1;
    while (owner.step(&queues, .{ .leaf_visits = 1, .bitmap_pages = 1 }) == .pending) {
        try expect(store.step_leaf_visits <= 1 and store.step_bitmap_pages <= 1);
        steps += 1;
        try expect(steps < 10000);
    }
    try equal(api.Status.no_space, queues.responses.tryPop().?.status);
    try equal(@as(u8, 'A'), (try read(&owner, &queues, handle, 0, 1)).data[0]);
    try equal(api.Status.ok, (try send(&owner, &queues, request(&owner, handle, .sync))).status);
    try expect(steps > 1);
}
test "checkpoint service handle sequence and epoch exhaustion never revive old authority" {
    var backend = Backend{};
    var device = Device{ .backend = &backend };
    var store = Store{};
    _ = try seed(&store, &device);
    var owner = try Owner.init(&store, 11);
    var queues = Queues{};
    var handle = try owner.grant(1, true);
    try equal(api.Status.ok, (try send(&owner, &queues, request(&owner, handle, .close))).status);
    const old = handle;
    handle = try owner.grant(1, true);
    try expect(handle.generation != old.generation);
    try equal(api.Status.stale, (try read(&owner, &queues, old, 0, 1)).status);
    owner.handles[handle.slot].generation = std.math.maxInt(u64);
    handle.generation = std.math.maxInt(u64);
    try equal(api.Status.ok, (try send(&owner, &queues, request(&owner, handle, .close))).status);
    try expect(owner.handles[handle.slot].retired);
    handle = try owner.grant(1, true);
    owner.next_sequence = std.math.maxInt(u64);
    const last = try send(&owner, &queues, request(&owner, handle, .stat));
    try expect(api.matches(&last, 1, std.math.maxInt(u64)));
    try equal(@as(u64, 0), owner.next_sequence);
    try equal(api.Status.invalid, (try send(&owner, &queues, request(&owner, handle, .stat))).status);
    _ = try owner.clientExited(11, &queues);
    owner.epoch = std.math.maxInt(u64);
    try expect(!owner.rebind(12, &queues));
}
