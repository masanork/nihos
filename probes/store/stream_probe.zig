//! Fixed-buffer host streaming/patch probe. Never creates or formats devices.
const std = @import("std");
const model = @import("checkpoint_model");
const file_media = @import("file_media");
const Device = file_media.Media(16 * 1024 * 1024 * 1024);
const Store = model.Store(Device, .{ .index_pages = 256, .payload_start_page = Device.capacity / model.page_bytes - 32768, .payload_reserve_pages = 16, .leaf_cache_pages = 128 });
const length: u64 = 33 * 1024 * 1024 + 17;
const patch_offset = model.checksums_per_page * model.page_bytes - 5;
const replacement = "STREAMING-PATCH-TEST";
fn value(offset: u64) u8 {
    return @truncate(offset *% 17 +% 0x31);
}
fn report(io: std.Io, device: *Device, store: *Store, command: []const u8) !void {
    var buffer: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buffer);
    try stdout.interface.print("{{\"phase\":\"{s}\",\"generation\":{d},\"state_bytes\":{d},\"object_bytes\":{d},\"input_buffer_bytes\":4096,\"data_pages\":{d},\"checksum_pages\":{d},\"writes\":{d},\"syncs\":{d}}}\n", .{
        command, store.generation(), @sizeOf(Store), length, model.dataPages(length), model.checksumPages(length), device.writes, device.syncs,
    });
    try stdout.interface.flush();
}
fn allocation(store: *Store) !void {
    try store.beginPayloadSearch(model.dataPages(length) + model.checksumPages(length));
    while (true) switch (try store.stepPayloadSearch(.{})) {
        .pending => {},
        .found => return,
        .no_space => return error.NoSpace,
        .space => return error.BadSearch,
    };
}
fn streamData(store: *Store, stream: model.Stream, until: u64) !void {
    var buffer: [4096]u8 = undefined;
    var offset: u64 = 0;
    while (offset < until) {
        const n: usize = @intCast(@min(buffer.len, until - offset));
        for (buffer[0..n], 0..) |*byte, i| byte.* = value(offset + i);
        const consumed = try store.writeStream(stream, buffer[0..n]);
        if (consumed == 0 or consumed > n) return error.BadProgress;
        offset += consumed;
    }
}
fn verify(store: *Store, changed: bool) !void {
    if ((try store.get(1)).length != length) return error.BadLength;
    var buffer: [4096]u8 = undefined;
    var offset: u64 = 0;
    while (offset < length) {
        const n = try store.read(1, offset, buffer[0..@intCast(@min(buffer.len, length - offset))]);
        if (n == 0 or n > length - offset) return error.BadRead;
        for (buffer[0..n], 0..) |byte, i| {
            const position = offset + i;
            const expected = if (changed and position >= patch_offset and position < patch_offset + replacement.len) replacement[@intCast(position - patch_offset)] else value(position);
            if (byte != expected) return error.BadPayload;
        }
        offset += n;
    }
    try store.verify(1);
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
    const known = [_][]const u8{ "format", "seed", "verify-old", "patch", "patch-wait", "verify-new", "cancel", "stage-wait", "finish-wait" };
    var valid = false;
    for (known) |name| if (std.mem.eql(u8, command, name)) {
        valid = true;
        break;
    };
    if (!valid) return error.Usage;
    var device = try Device.open(init.io, .cwd(), args[2]);
    defer device.close();
    var store = Store{};
    if (std.mem.eql(u8, command, "format")) {
        try store.format(&device);
        return report(init.io, &device, &store, command);
    }
    try store.recover(&device);
    if (std.mem.eql(u8, command, "seed")) {
        if (store.generation() != 1) return error.BadGeneration;
        try store.begin();
        try allocation(&store);
        const stream = try store.beginStreamPrepared(1, length);
        try streamData(&store, stream, length);
        try store.finishStream(stream);
        try store.commit();
    } else if (std.mem.eql(u8, command, "verify-old")) {
        if (store.generation() != 2) return error.BadGeneration;
        try verify(&store, false);
    } else if (std.mem.eql(u8, command, "verify-new")) {
        if (store.generation() != 3) return error.BadGeneration;
        try verify(&store, true);
    } else if (std.mem.eql(u8, command, "patch") or std.mem.eql(u8, command, "patch-wait")) {
        if (store.generation() != 2) return error.BadGeneration;
        try store.begin();
        try allocation(&store);
        const stream = try store.beginPatchPrepared(1, patch_offset, replacement.len);
        var consumed: usize = 0;
        while (true) {
            const progress = try store.stepPatch(stream, replacement[consumed..]);
            consumed += progress.consumed;
            if (progress.done) break;
            if (progress.need_input) return error.UnexpectedInputWait;
        }
        if (consumed != replacement.len) return error.BadPatchProgress;
        try store.finishStream(stream);
        try store.commit();
        if (std.mem.eql(u8, command, "patch-wait")) {
            try report(init.io, &device, &store, command);
            return waitForKill(init.io);
        }
    } else {
        if (store.generation() != 2) return error.BadGeneration;
        try store.begin();
        try allocation(&store);
        const stream = try store.beginStreamPrepared(1, length);
        const staged = std.mem.eql(u8, command, "stage-wait");
        try streamData(&store, stream, if (staged or std.mem.eql(u8, command, "cancel")) 1024 * 1024 + 17 else length);
        if (std.mem.eql(u8, command, "cancel")) {
            try store.abortStream(stream);
            try store.rollback();
        } else {
            if (!staged) try store.finishStream(stream);
            try report(init.io, &device, &store, command);
            return waitForKill(init.io);
        }
    }
    try report(init.io, &device, &store, command);
}
