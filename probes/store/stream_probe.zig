//! Fixed-buffer host streaming/patch probe. Never creates or formats devices.
const std = @import("std");
const model = @import("checkpoint_model");
const file_media = @import("file_media");
const Device = file_media.Media(16 * 1024 * 1024 * 1024);
const Store = model.Store(Device, .{ .index_pages = 256, .payload_start_page = Device.capacity / model.page_bytes - 32768, .payload_reserve_pages = 16, .leaf_cache_pages = 128 });
const length: u64 = 33 * 1024 * 1024 + 17;
const short_length = length - 4096 - 13;
const patch_offset = model.checksums_per_page * model.page_bytes - 5;
const replacement = "STREAMING-PATCH-TEST";
const mapped_replacement = "MAPPED-PAGE-CHANGED!";
fn value(offset: u64) u8 {
    return @truncate(offset *% 17 +% 0x31);
}
fn report(io: std.Io, device: *Device, store: *Store, command: []const u8) !void {
    var buffer: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buffer);
    try stdout.interface.print("{{\"phase\":\"{s}\",\"generation\":{d},\"state_bytes\":{d},\"object_bytes\":{d},\"input_buffer_bytes\":4096,\"data_pages\":{d},\"checksum_pages\":{d},\"writes\":{d},\"syncs\":{d},\"map_metadata_pages\":{d},\"payload_high_water_pages\":{d}}}\n", .{
        command, store.generation(), @sizeOf(Store), length, model.dataPages(length), model.checksumPages(length), device.writes, device.syncs, try Store.mapMetadataPages(length), store.current.payload_next - Store.payload_start,
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
fn verify(store: *Store, change: []const u8) !void {
    if ((try store.get(1)).length != length) return error.BadLength;
    var buffer: [4096]u8 = undefined;
    var offset: u64 = 0;
    while (offset < length) {
        const n = try store.read(1, offset, buffer[0..@intCast(@min(buffer.len, length - offset))]);
        if (n == 0 or n > length - offset) return error.BadRead;
        for (buffer[0..n], 0..) |byte, i| {
            const position = offset + i;
            const expected = if (change.len != 0 and position >= patch_offset and position < patch_offset + change.len) change[@intCast(position - patch_offset)] else value(position);
            if (byte != expected) return error.BadPayload;
        }
        offset += n;
    }
    try store.verify(1);
}
fn verifyResized(store: *Store, expected_length: u64) !void {
    if ((try store.get(1)).length != expected_length) return error.BadLength;
    var buffer: [4096]u8 = undefined;
    var offset: u64 = 0;
    while (offset < expected_length) {
        const n = try store.read(1, offset, &buffer);
        if (n == 0) return error.BadRead;
        for (buffer[0..n], 0..) |byte, i| {
            const position = offset + i;
            const expected = if (position >= short_length) 0 else if (position >= patch_offset and position < patch_offset + mapped_replacement.len) mapped_replacement[@intCast(position - patch_offset)] else value(position);
            if (byte != expected) return error.ResizedPayload;
        }
        offset += n;
    }
    try store.verify(1);
}
fn resizePrepared(store: *Store, size: u64, scratch: *model.ResizeScratch) !void {
    try store.begin();
    const pages = try store.mappedResizePages(1, size, scratch);
    if (pages != 3) return error.UnexpectedResizeCost;
    try store.beginPayloadSearch(pages);
    while (true) switch (try store.stepPayloadSearch(.{})) {
        .pending => {},
        .found => break,
        else => return error.BadSearch,
    };
    try store.resizeMappedPrepared(1, size, scratch);
    try store.commit();
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
    const known = [_][]const u8{ "format", "seed", "verify-old", "patch", "patch-wait", "verify-new", "cancel", "stage-wait", "finish-wait", "promote-map", "verify-map-old", "mapped-patch-wait", "verify-map-new", "collect-map", "resize-cycle", "verify-resized" };
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
        try verify(&store, "");
    } else if (std.mem.eql(u8, command, "verify-new")) {
        if (store.generation() != 3) return error.BadGeneration;
        try verify(&store, replacement);
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
    } else if (std.mem.eql(u8, command, "promote-map")) {
        if (store.generation() != 3) return error.BadGeneration;
        try store.begin();
        try store.promoteMapped(1);
        try store.commit();
    } else if (std.mem.eql(u8, command, "verify-map-old")) {
        if (store.generation() != 4 or (try store.get(1)).kind != .mapped) return error.BadGeneration;
        try verify(&store, replacement);
    } else if (std.mem.eql(u8, command, "mapped-patch-wait")) {
        if (store.generation() != 4) return error.BadGeneration;
        try store.begin();
        var consumed: usize = 0;
        while (consumed < mapped_replacement.len) {
            const position = patch_offset + consumed;
            const n = @min(model.page_bytes - position % model.page_bytes, mapped_replacement.len - consumed);
            try store.beginPayloadSearch(try Store.mappedPatchPages(length));
            while (true) switch (try store.stepPayloadSearch(.{})) {
                .pending => {},
                .found => break,
                else => return error.BadSearch,
            };
            try store.patchMappedPagePrepared(1, position, mapped_replacement[consumed..][0..n]);
            consumed += n;
        }
        try store.commit();
        try report(init.io, &device, &store, command);
        return waitForKill(init.io);
    } else if (std.mem.eql(u8, command, "verify-map-new")) {
        if ((store.generation() != 5 and store.generation() != 6) or (try store.get(1)).kind != .mapped) return error.BadGeneration;
        try verify(&store, mapped_replacement);
    } else if (std.mem.eql(u8, command, "resize-cycle")) {
        if (store.generation() != 6) return error.BadGeneration;
        const reader = try store.pin();
        var scratch = model.ResizeScratch{};
        try resizePrepared(&store, short_length, &scratch);
        try verifyResized(&store, short_length);
        try resizePrepared(&store, length, &scratch);
        try verifyResized(&store, length);
        var old: [4096]u8 = undefined;
        var offset: u64 = short_length;
        while (offset < length) {
            const n = try store.readPinned(reader, 1, offset, &old);
            if (n == 0) return error.BadRead;
            for (old[0..n], 0..) |byte, i| if (byte != value(offset + i)) return error.OldReaderChanged;
            offset += n;
        }
        try store.release(reader);
        try store.collectPayload();
    } else if (std.mem.eql(u8, command, "verify-resized")) {
        if (store.generation() != 9) return error.BadGeneration;
        try verifyResized(&store, length);
    } else if (std.mem.eql(u8, command, "collect-map")) {
        if (store.generation() != 5) return error.BadGeneration;
        try store.collectPayload();
        const space = try store.payloadSpace();
        if (space.free_pages != 24268) return error.BadMappedSpace;
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
