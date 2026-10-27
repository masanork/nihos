//! Host-only copy-mailbox service probe over an existing regular file.
const std = @import("std");
const api = @import("checkpoint_service");
const model = api.model;
const file_media = @import("file_media");
const Device = file_media.Media(16 * 1024 * 1024 * 1024);
const Store = model.Store(Device, .{ .index_pages = 256, .payload_start_page = Device.capacity / model.page_bytes - 1024, .payload_reserve_pages = 16, .leaf_cache_pages = 128 });
const Owner = api.Owner(Store);
const Queues = api.Queues(@import("spsc_ring"));
const wide_length = 0x1_0000_0011;
const tail_offset = 0x1_0000_0007;
const payload: [5003]u8 = @splat(0xa7);
fn req(owner: *Owner, handle: api.Handle, op: api.Operation) api.Request {
    return .{ .epoch = owner.epoch, .sequence = owner.next_sequence, .handle = handle, .operation = @backingInt(op) };
}
fn send(owner: *Owner, q: *Queues, request: api.Request) !api.Response {
    if (!q.requests.tryPush(request)) return error.RequestFull;
    for (0..10000) |_| switch (owner.step(q, .{ .leaf_visits = 1, .bitmap_pages = 1 })) {
        .idle => return error.Idle,
        .pending => {},
        .completed => {
            const reply = q.responses.tryPop() orelse return error.MissingReply;
            if (!api.matches(&reply, request.epoch, request.sequence)) return error.BadReply;
            return reply;
        },
    };
    return error.Stuck;
}
fn ok(owner: *Owner, q: *Queues, request: api.Request) !api.Response {
    const reply = try send(owner, q, request);
    if (reply.status != .ok) return error.RequestFailed;
    return reply;
}
fn stage(owner: *Owner, q: *Queues, a: api.Handle, b: api.Handle) !void {
    var request = req(owner, a, .write);
    request.offset = 4095;
    request.length = 3;
    @memcpy(request.data[0..3], "XYZ");
    const written = try ok(owner, q, request);
    if (written.visibility != .staged or written.generation != owner.last_durable_generation) return error.FalseDurableAck;
    request = req(owner, b, .batch);
    request.length = 2;
    @memcpy(request.data[0..2], "JK");
    request.part_count = 2;
    request.parts[0] = .{ .offset = 1, .length = 1 };
    request.parts[1] = .{ .offset = 4097, .data_offset = 1, .length = 1 };
    _ = try ok(owner, q, request);
}
fn verify(owner: *Owner, q: *Queues, changed: bool) !void {
    for ([_]u32{ 1, 2 }) |key| {
        const handle = try owner.grant(key, false);
        const info = try ok(owner, q, req(owner, handle, .stat));
        if (info.size != (if (changed and key == 1) @as(u64, wide_length) else payload.len)) return error.BadLength;
        var request = req(owner, handle, .read);
        request.length = 4096;
        const first = try ok(owner, q, request);
        if (first.length != 4096) return error.BadRead;
        for (first.data, 0..) |byte, i| {
            const expected: u8 = if (changed and key == 1 and i == 4095) 'X' else if (changed and key == 2 and i == 1) 'J' else 0xa7;
            if (byte != expected) return error.BadPayload;
        }
        request = req(owner, handle, .read);
        request.offset = 4096;
        request.length = 907;
        const last = try ok(owner, q, request);
        for (last.data[0..907], 0..) |byte, i| {
            const expected: u8 = if (changed and key == 1 and i < 2) "YZ"[i] else if (changed and key == 2 and i == 1) 'K' else 0xa7;
            if (byte != expected) return error.BadPayload;
        }
        if (changed and key == 1) {
            request = req(owner, handle, .read);
            request.offset = 0xffff_ffff;
            request.length = 18;
            const tail = try ok(owner, q, request);
            if (tail.length != 18) return error.BadRead;
            for (tail.data[0..18], 0..) |byte, i| if (byte != (if (i >= 8 and i < 12) @as(u8, "TAIL"[i - 8]) else 0)) return error.BadTail;
        }
        _ = try ok(owner, q, req(owner, handle, .close));
    }
}
fn report(io: std.Io, device: *Device, store: *Store, owner: *Owner, phase: []const u8) !void {
    var buffer: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buffer);
    try stdout.interface.print("{{\"phase\":\"{s}\",\"generation\":{d},\"durable_generation\":{d},\"store_bytes\":{d},\"owner_bytes\":{d},\"queues_bytes\":{d},\"request_bytes\":{d},\"response_bytes\":{d},\"writes\":{d},\"syncs\":{d},\"payload_high_water_pages\":{d}}}\n", .{ phase, store.generation(), owner.last_durable_generation, @sizeOf(Store), @sizeOf(Owner), @sizeOf(Queues), @sizeOf(api.Request), @sizeOf(api.Response), device.writes, device.syncs, store.current.payload_next - Store.payload_start });
    try stdout.interface.flush();
}
fn wait(io: std.Io) !void {
    var byte: [1]u8 = undefined;
    _ = try std.Io.File.stdin().readStreaming(io, &.{&byte});
    return error.UnexpectedResume;
}
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3) return error.Usage;
    const command = args[1];
    const is = std.mem.eql;
    var device = try Device.open(init.io, .cwd(), args[2]);
    defer device.close();
    var store = Store{};
    if (is(u8, command, "seed")) {
        try store.format(&device);
        try store.begin();
        try store.put(1, &payload);
        try store.put(2, &payload);
        try store.commit();
        try store.begin();
        try store.promoteMapped(1);
        try store.promoteMapped(2);
        try store.commit();
    } else try store.recover(&device);
    var owner = try Owner.init(&store, 11);
    var q = Queues{};
    if (is(u8, command, "seed")) return report(init.io, &device, &store, &owner, command);
    if (is(u8, command, "verify-old") or is(u8, command, "verify-new")) {
        const changed = is(u8, command, "verify-new");
        if (store.generation() != (if (changed) @as(u64, 4) else 3) and !(changed and store.generation() == 5)) return error.BadGeneration;
        try verify(&owner, &q, changed);
    } else {
        const after_sync = is(u8, command, "sync-rebind");
        if (store.generation() != (if (after_sync) @as(u64, 4) else 3)) return error.BadGeneration;
        const a = try owner.grant(1, true);
        const b = try owner.grant(2, true);
        try stage(&owner, &q, a, b);
        if (is(u8, command, "stage-wait")) {
            try report(init.io, &device, &store, &owner, command);
            return wait(init.io);
        }
        if (is(u8, command, "exit-staged")) {
            if (try owner.clientExited(11, &q) != .cancelled_staging or !owner.rebind(12, &q)) return error.BadExit;
            try verify(&owner, &q, false);
        } else if (is(u8, command, "sync-wait") or after_sync) {
            if (!after_sync) {
                var request = req(&owner, a, .truncate);
                request.offset = wide_length;
                _ = try ok(&owner, &q, request);
                request = req(&owner, a, .write);
                request.offset = tail_offset;
                request.length = 4;
                @memcpy(request.data[0..4], "TAIL");
                _ = try ok(&owner, &q, request);
            }
            if (after_sync) {
                if (!q.requests.tryPush(req(&owner, a, .sync)) or owner.step(&q, .{}) != .completed) return error.BadSync;
                if (try owner.clientExited(11, &q) != .clean or owner.discarded_responses != 1 or !owner.rebind(12, &q)) return error.BadExit;
                const fresh = try owner.grant(1, true);
                var stale = req(&owner, fresh, .stat);
                stale.epoch = 1;
                if ((try sendRaw(&owner, &q, stale)).status != .denied) return error.BadReplay;
                if ((try ok(&owner, &q, req(&owner, fresh, .stat))).size != wide_length) return error.BadLength;
                stale = req(&owner, a, .read);
                stale.length = 1;
                if ((try sendRaw(&owner, &q, stale)).status != .stale) return error.BadReplay;
                try verify(&owner, &q, true);
            } else {
                const synced = try ok(&owner, &q, req(&owner, a, .sync));
                if (synced.visibility != .committed or synced.generation != 4) return error.BadSync;
                try report(init.io, &device, &store, &owner, command);
                return wait(init.io);
            }
        } else return error.Usage;
    }
    try report(init.io, &device, &store, &owner, command);
}
// Deliberately submit an old epoch: its reply carries the current owner epoch.
fn sendRaw(owner: *Owner, q: *Queues, request: api.Request) !api.Response {
    if (!q.requests.tryPush(request)) return error.RequestFull;
    while (true) switch (owner.step(q, .{})) {
        .idle => return error.Idle,
        .pending => {},
        .completed => return q.responses.tryPop() orelse error.MissingReply,
    };
}
