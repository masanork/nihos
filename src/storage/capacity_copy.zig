//! Experimental host-only copy between caller-proven distinct store media.
//! Never formats, selects, provisions, or writes the source. The caller must
//! exclusively own both devices, ensure the domains really are disjoint, and
//! keep the source unmodified through later remount and cutover verification.
const std = @import("std");
const model = @import("checkpoint_model.zig");
pub const Error = model.Error || error{ SameDomain, DestinationNotEmpty, IncompatibleGeometry, VerificationFailed, CleanupFailed };
pub const Scratch = struct {
    data: [model.page_bytes]u8 = @splat(0),
    read: [model.page_bytes]u8 = @splat(0),
    compare: [model.page_bytes]u8 = @splat(0),
};
pub const Report = struct { objects: u32 = 0, bytes: u64 = 0 };

/// IDs are trusted caller assertions, not proof that ranges do not overlap.
/// A success verifies the currently mounted destination only. It is not an
/// atomic selector update, a remount receipt, or a physical durability claim.
pub fn copy(source: anytype, destination: anytype, source_domain: u64, destination_domain: u64, scratch: *Scratch) Error!Report {
    if (source_domain == 0 or destination_domain == 0 or source_domain == destination_domain or @intFromPtr(source) == @intFromPtr(destination)) return error.SameDomain;
    if (@TypeOf(source.*).max_objects > @TypeOf(destination.*).max_objects) return error.IncompatibleGeometry;
    if (source.in_transaction or destination.in_transaction or destination.budget != null) return error.Busy;
    for (1..@TypeOf(destination.*).max_objects + 1) |key| {
        if (destination.get(@intCast(key))) |_| return error.DestinationNotEmpty else |err| if (err != error.NotFound) return err;
    }
    const pin = try source.pin();
    const result = copyPinned(source, destination, pin, scratch) catch |err| {
        var cleanup_failed = false;
        if (destination.in_transaction and !destination.faulted) destination.rollback() catch {
            cleanup_failed = true;
        };
        source.release(pin) catch {
            cleanup_failed = true;
        };
        if (cleanup_failed) return error.CleanupFailed;
        return err;
    };
    source.release(pin) catch return error.CleanupFailed;
    return result;
}

fn copyPinned(source: anytype, destination: anytype, pin: model.Reader, scratch: *Scratch) Error!Report {
    try destination.begin();
    var report: Report = .{};
    for (1..@TypeOf(source.*).max_objects + 1) |raw_key| {
        const key: u32 = @intCast(raw_key);
        const entry = source.getPinned(pin, key) catch |err| if (err == error.NotFound) continue else return err;
        const writer = try destination.beginStream(key, entry.length);
        var offset: u64 = 0;
        while (offset < entry.length) {
            const amount: usize = @intCast(@min(model.page_bytes, entry.length - offset));
            const got = try source.readPinnedWithScratch(pin, key, offset, scratch.data[0..amount], &scratch.read);
            if (got != amount) return error.VerificationFailed;
            const written = try destination.writeStream(writer, scratch.data[0..amount]);
            if (written != amount) return error.VerificationFailed;
            offset += amount;
        }
        try destination.finishStream(writer);
        if (entry.kind == .mapped) {
            if (entry.length == 0) return error.IncompatibleGeometry;
            try destination.promoteMapped(key);
        }
        report.objects += 1;
        report.bytes = std.math.add(u64, report.bytes, entry.length) catch return error.IncompatibleGeometry;
    }
    // A commit error has unknown publication outcome. The caller must not
    // select this candidate without independent recovery and verification.
    try destination.commit();
    try verifyPinned(source, destination, pin, scratch);
    return report;
}

/// Exact key presence, kind, length and contents; does not validate SQLite or
/// other application invariants, partition layout or an on-disk selector.
pub fn verifyPinned(source: anytype, destination: anytype, pin: model.Reader, scratch: *Scratch) Error!void {
    if (@TypeOf(source.*).max_objects > @TypeOf(destination.*).max_objects) return error.IncompatibleGeometry;
    for (1..@TypeOf(destination.*).max_objects + 1) |raw_key| {
        const key: u32 = @intCast(raw_key);
        if (raw_key > @TypeOf(source.*).max_objects) {
            if (destination.get(key)) |_| return error.VerificationFailed else |err| if (err != error.NotFound) return err;
            continue;
        }
        const original = source.getPinned(pin, key) catch |err| {
            if (err != error.NotFound) return err;
            if (destination.get(key)) |_| return error.VerificationFailed else |other| if (other != error.NotFound) return other;
            continue;
        };
        const copied = destination.get(key) catch |err| if (err == error.NotFound) return error.VerificationFailed else return err;
        if (original.length != copied.length or original.kind != copied.kind) return error.VerificationFailed;
        var offset: u64 = 0;
        while (offset < original.length) {
            const n: usize = @intCast(@min(model.page_bytes, original.length - offset));
            if (try source.readPinnedWithScratch(pin, key, offset, scratch.data[0..n], &scratch.read) != n) return error.VerificationFailed;
            if (try destination.read(key, offset, scratch.compare[0..n]) != n) return error.VerificationFailed;
            if (!std.mem.eql(u8, scratch.data[0..n], scratch.compare[0..n])) return error.VerificationFailed;
            offset += n;
        }
    }
}

test "capacity copy preserves blobs, mapped values, empty objects and source" {
    const Media = @import("model_media.zig").Media(1024 * 1024);
    const Store = model.Store(Media, .{ .leaf_pages = 2, .index_pages = 8 });
    const a = try std.testing.allocator.create(Media);
    defer std.testing.allocator.destroy(a);
    const b = try std.testing.allocator.create(Media);
    defer std.testing.allocator.destroy(b);
    a.* = .{};
    b.* = .{};
    var source: Store = .{};
    var destination: Store = .{};
    try source.format(a);
    try destination.format(b);
    var payload: [5003]u8 = undefined;
    for (&payload, 0..) |*byte, i| byte.* = @truncate(i *% 31);
    try source.begin();
    try source.put(1, "database bytes");
    try source.put(20, &payload);
    try source.promoteMapped(20);
    try source.put(200, "");
    try source.commit();
    var before: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&a.stable, &before, .{});
    var scratch: Scratch = .{};
    try std.testing.expectError(error.SameDomain, copy(&source, &destination, 1, 1, &scratch));
    const result = try copy(&source, &destination, 1, 2, &scratch);
    try std.testing.expectEqual(@as(u32, 3), result.objects);
    try std.testing.expectEqual(@as(u64, 5017), result.bytes);
    try std.testing.expectEqual(model.Kind.mapped, (try destination.get(20)).kind);
    var after: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&a.stable, &after, .{});
    try std.testing.expectEqualSlices(u8, &before, &after);
    try std.testing.expectError(error.DestinationNotEmpty, copy(&source, &destination, 1, 2, &scratch));
    b.powerLoss();
    var reopened: Store = .{};
    try reopened.recover(b);
    const pin = try source.pin();
    try verifyPinned(&source, &reopened, pin, &scratch);
    try source.release(pin);
}

test "failed destination writes leave the source intact and never publish partial object sets" {
    const Media = @import("model_media.zig").Media(1024 * 1024);
    const Store = model.Store(Media, .{ .leaf_pages = 2, .index_pages = 8 });
    const a = try std.testing.allocator.create(Media);
    defer std.testing.allocator.destroy(a);
    const b = try std.testing.allocator.create(Media);
    defer std.testing.allocator.destroy(b);
    a.* = .{};
    var source: Store = .{};
    try source.format(a);
    try source.begin();
    try source.put(1, "old database");
    try source.put(2, "journal payload");
    try source.commit();
    var before: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&a.stable, &before, .{});
    b.* = .{};
    var baseline: Store = .{};
    try baseline.format(b);
    b.events = 0;
    var baseline_scratch: Scratch = .{};
    _ = try copy(&source, &baseline, 1, 2, &baseline_scratch);
    const total = b.events;
    try std.testing.expect(total > 24);
    var failures: usize = 0;
    var successes: usize = 0;
    var recovered_new: usize = 0;
    for ([_]@import("model_media.zig").Background{ .none, .alternating }) |background| for (0..28) |sample| {
        const cut = switch (sample) {
            24 => total / 2,
            25 => total - 2,
            26 => total - 1,
            27 => total,
            else => sample,
        };
        b.* = .{};
        var dest: Store = .{};
        try dest.format(b);
        b.events = 0;
        b.background = background;
        b.cut = .{ .event = cut, .prefix = 17 };
        var scratch: Scratch = .{};
        if (copy(&source, &dest, 1, 2, &scratch)) |_| {
            successes += 1;
        } else |_| {
            failures += 1;
        }
        b.powerLoss();
        var reopened: Store = .{};
        try reopened.recover(b);
        if (reopened.get(1)) |_| {
            recovered_new += 1;
            const pin = try source.pin();
            try verifyPinned(&source, &reopened, pin, &scratch);
            try source.release(pin);
        } else |err| {
            try std.testing.expectEqual(error.NotFound, err);
            try std.testing.expectError(error.NotFound, reopened.get(2));
        }
        var after: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(&a.stable, &after, .{});
        try std.testing.expectEqualSlices(u8, &before, &after);
    };
    try std.testing.expect(failures > 0 and successes > 0 and recovered_new > 0);
    std.debug.print("CAPACITY_COPY_CUTS events={d} cases={d} failures={d} successes={d} recovered_new={d}\n", .{ total, failures + successes, failures, successes, recovered_new });
}
