//! Separate-process host probe; never opens a native device or creates images.
const std = @import("std");
const model = @import("cow_model");
const file_media = @import("file_media");
const Device = file_media.Media(512 * 1024);
const Store = model.Store(Device, 8);
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
    var byte: [1]u8 = undefined;
    if (expected == 2) {
        try object(store, 1, large_length, 0x31);
        try object(store, 2, old_b.len, 0x42);
        if (store.read(3, 0, &byte)) |_| return error.UnexpectedObject else |err| if (err != error.NotFound) return err;
    } else {
        try object(store, 1, large_length, 0x53);
        try object(store, 3, new_c.len, 0x64);
        if (store.read(2, 0, &byte)) |_| return error.UnexpectedObject else |err| if (err != error.NotFound) return err;
    }
}

fn report(io: std.Io, device: *Device, phase: []const u8, generation: u64) !void {
    var buffer: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buffer);
    try stdout.interface.print("{{\"phase\":\"{s}\",\"generation\":{d},\"writes\":{d},\"syncs\":{d}}}\n", .{
        phase, generation, device.writes, device.syncs,
    });
    try stdout.interface.flush();
}

fn waitForKill(io: std.Io) !void {
    var byte: [1]u8 = undefined;
    _ = try std.Io.File.stdin().readStreaming(io, &.{&byte});
    return error.UnexpectedResume;
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3) return error.Usage;
    const command = args[1];
    const known = [_][]const u8{ "format", "seed", "update", "stage-wait", "commit-wait", "lock-wait", "verify-old", "verify-new", "inspect" };
    var valid = false;
    for (known) |name| if (std.mem.eql(u8, command, name)) {
        valid = true;
        break;
    };
    if (!valid) return error.Usage;
    var device = try Device.open(init.io, .cwd(), args[2]);
    defer device.close();
    if (std.mem.eql(u8, command, "lock-wait")) {
        try report(init.io, &device, "locked", 0);
        return waitForKill(init.io);
    }
    if (std.mem.eql(u8, command, "format")) {
        var store = try Store.format(&device);
        return report(init.io, &device, "formatted", store.generation());
    }
    var store = try Store.recover(&device);
    if (std.mem.eql(u8, command, "seed")) {
        if (store.generation() != 1) return error.BadGeneration;
        try store.begin();
        try store.put(1, &old_a);
        try store.put(2, &old_b);
        try store.commit();
    } else if (std.mem.eql(u8, command, "update") or std.mem.eql(u8, command, "commit-wait") or std.mem.eql(u8, command, "stage-wait")) {
        try check(&store, 2);
        try store.begin();
        try store.put(1, &new_a);
        if (std.mem.eql(u8, command, "stage-wait")) {
            try report(init.io, &device, "staged", store.generation());
            return waitForKill(init.io);
        }
        try store.remove(2);
        try store.put(3, &new_c);
        try store.commit();
        if (std.mem.eql(u8, command, "commit-wait")) {
            try report(init.io, &device, "acknowledged", store.generation());
            return waitForKill(init.io);
        }
    } else if (std.mem.eql(u8, command, "verify-old")) {
        try check(&store, 2);
    } else if (std.mem.eql(u8, command, "verify-new")) {
        try check(&store, 3);
    }
    try report(init.io, &device, command, store.generation());
}
