//! Host-only sparse-file probe. Image creation belongs to the Python harness.
const std = @import("std");
const model = @import("checkpoint_model");
const file_media = @import("file_media");
const Backend = file_media.Media(16 * 1024 * 1024 * 1024);
const Device = struct {
    pub const capacity = Backend.capacity;
    backend: *Backend,
    bytes_read: usize = 0,
    mount_only: bool = false,
    pub fn read(self: *@This(), offset: u64, destination: []u8) error{Io}!void {
        const metadata_end = (2 + 256) * model.page_bytes;
        if (self.mount_only and (offset > metadata_end or destination.len > metadata_end - offset)) return error.Io;
        self.bytes_read += destination.len;
        return self.backend.read(offset, destination);
    }
    pub fn write(self: *@This(), offset: u64, data: []const u8) error{Io}!void {
        return self.backend.write(offset, data);
    }
    pub fn sync(self: *@This()) error{Io}!void {
        return self.backend.sync();
    }
};
const Store = model.Store(Device, .{ .index_pages = 256, .payload_start_page = Backend.capacity / model.page_bytes - 64 });
const large_length = 70 * 1024 + 1;
fn pattern(comptime n: usize, seed: u8) [n]u8 {
    @setEvalBranchQuota(n * 2 + 1000);
    var result: [n]u8 = undefined;
    for (&result, 0..) |*byte, i| byte.* = value(i, seed);
    return result;
}
fn value(index: usize, seed: u8) u8 {
    return @truncate(index *% 17 +% seed);
}
const old_a = pattern(large_length, 0x31);
const old_b = pattern(4096, 0x42);
const new_a = pattern(large_length, 0x53);
const new_c = pattern(4101, 0x64);

fn object(store: *Store, id: u32, length: usize, seed: u8) !void {
    var bytes: [777]u8 = undefined;
    var offset: usize = 0;
    while (offset < length) {
        const n = try store.read(id, offset, &bytes);
        if (n == 0 or n > length - offset) return error.BadReadLength;
        for (bytes[0..n], 0..) |byte, i| if (byte != value(offset + i, seed)) return error.BadPayload;
        offset += n;
    }
    if (try store.read(id, offset, &bytes) != 0) return error.BadEof;
}
fn check(store: *Store, expected: u64) !void {
    if (store.generation() != expected) return error.BadGeneration;
    if ((try store.get(Store.max_objects)).length != 0) return error.BadEmptyObject;
    if (expected == 2) {
        try object(store, 1, large_length, 0x31);
        try object(store, 127, old_b.len, 0x42);
        if (store.get(2)) |_| return error.UnexpectedObject else |err| if (err != error.NotFound) return err;
    } else {
        try object(store, 1, large_length, 0x53);
        try object(store, 2, new_c.len, 0x64);
        if (store.get(127)) |_| return error.UnexpectedObject else |err| if (err != error.NotFound) return err;
    }
}
fn report(io: std.Io, backend: *Backend, store: *Store, phase: []const u8, mount_bytes: usize, operation_bytes: usize) !void {
    const first = if (store.get(1)) |item| item.first * model.page_bytes else |err| switch (err) {
        error.NotFound => 0,
        else => return err,
    };
    var buffer: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buffer);
    try stdout.interface.print("{{\"phase\":\"{s}\",\"generation\":{d},\"mount_bytes\":{d},\"mount_limit_bytes\":{d},\"state_bytes\":{d},\"payload_first_byte\":{d},\"max_objects\":{d},\"tail_replay_bytes\":0,\"writes\":{d},\"syncs\":{d},\"operation_read_bytes\":{d}}}\n", .{
        phase, store.generation(), mount_bytes, Store.mount_limit_bytes, @sizeOf(Store), first, Store.max_objects, backend.writes, backend.syncs, operation_bytes,
    });
    try stdout.interface.flush();
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3) return error.Usage;
    const command = args[1];
    const known = [_][]const u8{ "format", "seed", "update", "verify-old", "verify-new", "fill-index", "checkpoint", "verify-index", "inspect", "read-one", "read-cross", "read-far", "verify-full" };
    var valid = false;
    for (known) |name| if (std.mem.eql(u8, command, name)) {
        valid = true;
        break;
    };
    if (!valid) return error.Usage;
    var backend = try Backend.open(init.io, .cwd(), args[2]);
    defer backend.close();
    var device = Device{ .backend = &backend };
    var store = Store{};
    if (std.mem.eql(u8, command, "format")) {
        try store.format(&device);
        return report(init.io, &backend, &store, command, 0, 0);
    }
    device.mount_only = true;
    try store.recover(&device);
    if (device.bytes_read != store.mount_bytes or device.bytes_read > Store.mount_limit_bytes) return error.BadMountIo;
    const mount_bytes = device.bytes_read;
    device.mount_only = false;
    if (std.mem.eql(u8, command, "seed")) {
        if (store.generation() != 1) return error.BadGeneration;
        try store.begin();
        try store.put(1, &old_a);
        try store.put(127, &old_b);
        try store.put(Store.max_objects, "");
        try store.commit();
    } else if (std.mem.eql(u8, command, "update")) {
        try check(&store, 2);
        try store.begin();
        try store.put(1, &new_a);
        try store.remove(127);
        try store.put(2, &new_c);
        try store.commit();
    } else if (std.mem.eql(u8, command, "verify-old")) {
        try check(&store, 2);
    } else if (std.mem.eql(u8, command, "verify-new")) {
        try check(&store, 3);
    } else if (std.mem.eql(u8, command, "verify-full")) {
        if (store.generation() != 3) return error.BadGeneration;
        try store.verify(1);
    } else if (std.mem.startsWith(u8, command, "read-")) {
        if (store.generation() != 3) return error.BadGeneration;
        const cross = std.mem.eql(u8, command, "read-cross");
        const offset: usize = if (cross) model.page_bytes - 1 else if (std.mem.eql(u8, command, "read-far")) 17 * model.page_bytes + 17 else 17;
        var bytes: [2]u8 = undefined;
        const n: usize = if (cross) 2 else 1;
        if (try store.read(1, offset, bytes[0..n]) != n) return error.BadReadLength;
        for (bytes[0..n], 0..) |byte, i| if (byte != value(offset + i, 0x53)) return error.BadPayload;
    } else if (std.mem.eql(u8, command, "fill-index")) {
        if (store.generation() != 3) return error.BadGeneration;
        try store.begin();
        for (0..128) |index| try store.put(@intCast(index * model.leaf_entries + 1), "");
        try store.commit();
    } else if (std.mem.eql(u8, command, "checkpoint")) {
        if (store.generation() != 4) return error.BadGeneration;
        try store.begin();
        try store.commit();
    } else if (std.mem.eql(u8, command, "verify-index")) {
        if (store.generation() != 5 or mount_bytes != Store.mount_limit_bytes) return error.BadFullIndex;
        for (0..128) |index| if ((try store.get(@intCast(index * model.leaf_entries + 1))).length != 0) return error.BadEmptyObject;
    }
    try report(init.io, &backend, &store, command, mount_bytes, device.bytes_read - mount_bytes);
}
