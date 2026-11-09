//! Experimental readiness record for a quiesced, copied store. This module
//! performs no I/O, partition writes, activation, or automatic cutover.
//! Callers must exclusively own and independently identify all three ranges.
const std = @import("std");
const model = @import("checkpoint_model.zig");
const migration = @import("capacity_copy.zig");
pub const sector_bytes = 512;
pub const Error = migration.Error || error{ InvalidLayout, RecoveryRequired };
pub const Decision = enum { legacy, candidate_ready };
pub const Layout = struct {
    card_sectors: u64,
    source_start: u64,
    source_count: u64,
    target_start: u64,
    target_count: u64,
    record_lba: u64,
};
const magic = "NIHCAP01";
const checksum_offset = sector_bytes - 4;

fn validRange(start: u64, count: u64, capacity: u64) bool {
    return count != 0 and start != 0 and start < capacity and count <= capacity - start;
}
fn overlaps(a: u64, alen: u64, b: u64, blen: u64) bool {
    return a < b + blen and b < a + alen;
}
fn checkLayout(source: anytype, target: anytype, layout: Layout) Error!void {
    if (!validRange(layout.source_start, layout.source_count, layout.card_sectors) or
        !validRange(layout.target_start, layout.target_count, layout.card_sectors) or
        layout.record_lba == 0 or layout.record_lba >= layout.card_sectors or
        overlaps(layout.source_start, layout.source_count, layout.target_start, layout.target_count) or
        overlaps(layout.source_start, layout.source_count, layout.record_lba, 1) or
        overlaps(layout.target_start, layout.target_count, layout.record_lba, 1) or
        layout.source_count != @TypeOf(source.*).capacity_bytes / sector_bytes or
        layout.target_count != @TypeOf(target.*).capacity_bytes / sector_bytes or
        @intFromPtr(source) == @intFromPtr(target)) return error.InvalidLayout;
}
fn feedInt(hash: *std.crypto.hash.sha2.Sha256, value: u64) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    hash.update(&bytes);
}
fn fingerprint(source: anytype, pin: model.Reader, scratch: *migration.Scratch) Error![32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("NIHOS-CAPACITY-COPY-V1");
    for (1..@TypeOf(source.*).max_objects + 1) |raw_key| {
        const key: u32 = @intCast(raw_key);
        const value = source.getPinned(pin, key) catch |err| if (err == error.NotFound) continue else return err;
        feedInt(&hash, key);
        feedInt(&hash, @backingInt(value.kind));
        feedInt(&hash, value.length);
        var at: u64 = 0;
        while (at < value.length) {
            const n: usize = @intCast(@min(model.page_bytes, value.length - at));
            if (try source.readPinnedWithScratch(pin, key, at, scratch.data[0..n], &scratch.read) != n) return error.VerificationFailed;
            hash.update(scratch.data[0..n]);
            at += n;
        }
    }
    return hash.finalResult();
}

/// Caller guarantees source and target were independently recovered and both
/// remain frozen. The returned bytes are a proposal, not a durable receipt.
pub fn prepare(source: anytype, target: anytype, layout: Layout, scratch: *migration.Scratch) Error![sector_bytes]u8 {
    try checkLayout(source, target, layout);
    if (source.in_transaction or target.in_transaction or source.budget != null or target.budget != null) return error.Busy;
    const pin = try source.pin();
    const hash = fingerprint(source, pin, scratch) catch |err| {
        source.release(pin) catch return error.CleanupFailed;
        return err;
    };
    migration.verifyPinned(source, target, pin, scratch) catch |err| {
        source.release(pin) catch return error.CleanupFailed;
        return err;
    };
    source.release(pin) catch return error.CleanupFailed;
    var raw: [sector_bytes]u8 = @splat(0);
    @memcpy(raw[0..8], magic);
    std.mem.writeInt(u64, raw[8..16], layout.card_sectors, .little);
    std.mem.writeInt(u64, raw[16..24], layout.source_start, .little);
    std.mem.writeInt(u64, raw[24..32], layout.source_count, .little);
    std.mem.writeInt(u64, raw[32..40], layout.target_start, .little);
    std.mem.writeInt(u64, raw[40..48], layout.target_count, .little);
    std.mem.writeInt(u64, raw[48..56], layout.record_lba, .little);
    std.mem.writeInt(u64, raw[56..64], source.generation(), .little);
    std.mem.writeInt(u64, raw[64..72], target.generation(), .little);
    @memcpy(raw[72..104], &hash);
    std.mem.writeInt(u32, raw[checksum_offset..][0..4], std.hash.Crc32.hash(raw[0..checksum_offset]), .little);
    return raw;
}

/// A blank record is legacy only when the caller independently proves that
/// legacy remains authoritative. Invalid/torn records never select a target.
/// A valid record is readiness evidence only: both stores are rechecked and
/// must remain read-only. This function does not activate writable target use.
pub fn assess(raw: *const [sector_bytes]u8, legacy_authoritative: bool, source: anytype, target: anytype, layout: Layout, scratch: *migration.Scratch) Error!Decision {
    try checkLayout(source, target, layout);
    if (!source.ready or source.faulted or source.in_transaction or source.budget != null) return error.RecoveryRequired;
    if (std.mem.allEqual(u8, raw, 0xff)) return if (legacy_authoritative) .legacy else error.RecoveryRequired;
    if (!std.mem.eql(u8, raw[0..8], magic) or
        std.hash.Crc32.hash(raw[0..checksum_offset]) != std.mem.readInt(u32, raw[checksum_offset..][0..4], .little) or
        !std.mem.allEqual(u8, raw[104..checksum_offset], 0)) return error.RecoveryRequired;
    const expected = prepare(source, target, layout, scratch) catch return error.RecoveryRequired;
    if (!std.mem.eql(u8, raw, &expected)) return error.RecoveryRequired;
    return .candidate_ready;
}

test "readiness requires a rechecked frozen copy and rejects stale content" {
    const Media = @import("model_media.zig").Media(1024 * 1024);
    const Store = model.Store(Media, .{ .leaf_pages = 2, .index_pages = 8 });
    const a = try std.testing.allocator.create(Media);
    defer std.testing.allocator.destroy(a);
    const b = try std.testing.allocator.create(Media);
    defer std.testing.allocator.destroy(b);
    a.* = .{};
    b.* = .{};
    var source: Store = .{};
    var target: Store = .{};
    try source.format(a);
    try target.format(b);
    try source.begin();
    try source.put(1, "database");
    try source.commit();
    var scratch: migration.Scratch = .{};
    _ = try migration.copy(&source, &target, 1, 2, &scratch);
    a.powerLoss();
    b.powerLoss();
    source = .{};
    target = .{};
    try source.recover(a);
    try target.recover(b);
    const layout = Layout{ .card_sectors = 8192, .source_start = 2048, .source_count = 2048, .target_start = 4096, .target_count = 2048, .record_lba = 1 };
    const blank: [sector_bytes]u8 = @splat(0xff);
    try std.testing.expectEqual(Decision.legacy, try assess(&blank, true, &source, &target, layout, &scratch));
    try std.testing.expectError(error.RecoveryRequired, assess(&blank, false, &source, &target, layout, &scratch));
    const record = try prepare(&source, &target, layout, &scratch);
    try std.testing.expectEqual(Decision.candidate_ready, try assess(&record, false, &source, &target, layout, &scratch));
    var bad = record;
    bad[80] ^= 1;
    try std.testing.expectError(error.RecoveryRequired, assess(&bad, true, &source, &target, layout, &scratch));
    var overlap = layout;
    overlap.target_start = layout.source_start;
    try std.testing.expectError(error.InvalidLayout, prepare(&source, &target, overlap, &scratch));
    var metadata_inside_source = layout;
    metadata_inside_source.record_lba = layout.source_start;
    try std.testing.expectError(error.InvalidLayout, prepare(&source, &target, metadata_inside_source, &scratch));
    var metadata_inside_target = layout;
    metadata_inside_target.record_lba = layout.target_start;
    try std.testing.expectError(error.InvalidLayout, prepare(&source, &target, metadata_inside_target, &scratch));
    var wrong_size = layout;
    wrong_size.target_count -= 1;
    try std.testing.expectError(error.InvalidLayout, prepare(&source, &target, wrong_size, &scratch));
    var wrong_card = layout;
    wrong_card.card_sectors += 1;
    try std.testing.expectError(error.RecoveryRequired, assess(&record, true, &source, &target, wrong_card, &scratch));
    try target.begin();
    try target.put(1, "changed!");
    try target.commit();
    try std.testing.expectError(error.RecoveryRequired, assess(&record, true, &source, &target, layout, &scratch));
}

test "torn readiness metadata never silently selects a candidate" {
    const Media = @import("model_media.zig").Media(1024 * 1024);
    const Store = model.Store(Media, .{ .leaf_pages = 2, .index_pages = 8 });
    const a = try std.testing.allocator.create(Media);
    defer std.testing.allocator.destroy(a);
    const b = try std.testing.allocator.create(Media);
    defer std.testing.allocator.destroy(b);
    a.* = .{};
    b.* = .{};
    var source: Store = .{};
    var target: Store = .{};
    try source.format(a);
    try target.format(b);
    try source.begin();
    try source.put(1, "database");
    try source.commit();
    var scratch: migration.Scratch = .{};
    _ = try migration.copy(&source, &target, 1, 2, &scratch);
    a.powerLoss();
    b.powerLoss();
    source = .{};
    target = .{};
    try source.recover(a);
    try target.recover(b);
    const layout = Layout{ .card_sectors = 8192, .source_start = 2048, .source_count = 2048, .target_start = 4096, .target_count = 2048, .record_lba = 1 };
    const record = try prepare(&source, &target, layout, &scratch);
    const Meta = @import("model_media.zig").Media(1024);
    var legacy_count: usize = 0;
    var ready_count: usize = 0;
    var fenced_count: usize = 0;
    for ([_]@import("model_media.zig").Background{ .none, .alternating, .all }) |background| for (0..4) |cut_event| for ([_]usize{ 0, 1, 64, 511, 512 }) |prefix| {
        var meta: Meta = .{ .background = background, .cut = .{ .event = cut_event, .prefix = prefix } };
        if (meta.write(0, &record)) |_| {
            meta.sync() catch |err| try std.testing.expectEqual(error.Io, err);
        } else |err| try std.testing.expectEqual(error.Io, err);
        meta.powerLoss();
        const recovered: *const [sector_bytes]u8 = @ptrCast(meta.cache[0..sector_bytes]);
        if (assess(recovered, true, &source, &target, layout, &scratch)) |decision| {
            switch (decision) {
                .legacy => legacy_count += 1,
                .candidate_ready => ready_count += 1,
            }
        } else |err| {
            try std.testing.expectEqual(error.RecoveryRequired, err);
            fenced_count += 1;
        }
    };
    try std.testing.expect(legacy_count > 0 and ready_count > 0 and fenced_count > 0);
    std.debug.print("CAPACITY_READINESS cases={d} legacy={d} ready={d} fenced={d}\n", .{ legacy_count + ready_count + fenced_count, legacy_count, ready_count, fenced_count });
}
