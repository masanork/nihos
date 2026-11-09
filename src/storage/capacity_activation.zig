//! Host-only one-way activation experiment. Device and volume identities,
//! exclusive ownership, range mapping and recovery attestations are trusted
//! caller inputs, not authenticated facts. Not a native boot selector.
const std = @import("std");
const readiness = @import("capacity_readiness.zig");
const migration = @import("capacity_copy.zig");
pub const Error = readiness.Error || error{ PublicationUnknown, Fenced };
pub const Choice = enum { legacy, target };
pub const Binding = struct {
    layout: readiness.Layout,
    card_id: [32]u8,
    target_id: [32]u8,
};
const magic = "NIHACT01";
const crc_offset = readiness.sector_bytes - 4;

fn validRange(start: u64, count: u64, limit: u64) bool {
    return start != 0 and count != 0 and start < limit and count <= limit - start;
}
fn overlaps(a: u64, an: u64, b: u64, bn: u64) bool {
    return a < b + bn and b < a + an;
}
fn validate(binding: Binding) Error!void {
    const l = binding.layout;
    if (std.mem.allEqual(u8, &binding.card_id, 0) or std.mem.allEqual(u8, &binding.target_id, 0) or
        !validRange(l.source_start, l.source_count, l.card_sectors) or !validRange(l.target_start, l.target_count, l.card_sectors) or
        l.record_lba == 0 or l.record_lba >= l.card_sectors or overlaps(l.source_start, l.source_count, l.target_start, l.target_count) or
        overlaps(l.source_start, l.source_count, l.record_lba, 1) or overlaps(l.target_start, l.target_count, l.record_lba, 1)) return error.InvalidLayout;
}
fn encode(binding: Binding, readiness_hash: [32]u8) [readiness.sector_bytes]u8 {
    const l = binding.layout;
    var raw: [readiness.sector_bytes]u8 = @splat(0);
    @memcpy(raw[0..8], magic);
    std.mem.writeInt(u64, raw[8..16], l.card_sectors, .little);
    std.mem.writeInt(u64, raw[16..24], l.source_start, .little);
    std.mem.writeInt(u64, raw[24..32], l.source_count, .little);
    std.mem.writeInt(u64, raw[32..40], l.target_start, .little);
    std.mem.writeInt(u64, raw[40..48], l.target_count, .little);
    std.mem.writeInt(u64, raw[48..56], l.record_lba, .little);
    @memcpy(raw[56..88], &binding.card_id);
    @memcpy(raw[88..120], &binding.target_id);
    @memcpy(raw[120..152], &readiness_hash);
    std.mem.writeInt(u32, raw[crc_offset..][0..4], std.hash.Crc32.hash(raw[0..crc_offset]), .little);
    return raw;
}

pub const Guard = struct {
    pub const State = enum { fresh, active, fenced };
    state: State = .fresh,

    /// Only a caller that owns an explicitly reserved metadata device and
    /// frozen, independently recovered stores may call this. A failed write or
    /// sync has unknown outcome and permanently fences this guard instance.
    pub fn activate(self: *Guard, meta: anytype, proof: *const [readiness.sector_bytes]u8, source: anytype, target: anytype, binding: Binding, scratch: *migration.Scratch) Error!void {
        if (self.state == .fenced) return error.Fenced;
        if (self.state != .fresh) return error.Busy;
        try validate(binding);
        if (try readiness.assess(proof, false, source, target, binding.layout, scratch) != .candidate_ready) return error.RecoveryRequired;
        var old: [readiness.sector_bytes]u8 = undefined;
        meta.read(0, &old) catch {
            self.state = .fenced;
            return error.RecoveryRequired;
        };
        if (!std.mem.allEqual(u8, &old, 0xff)) {
            self.state = .fenced;
            return error.RecoveryRequired;
        }
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(proof, &digest, .{});
        const record = encode(binding, digest);
        self.state = .fenced;
        meta.write(0, &record) catch return error.PublicationUnknown;
        meta.sync() catch return error.PublicationUnknown;
        self.state = .active;
    }
};

/// `target_recovered` and `legacy_authoritative` are independently established
/// boot facts; they are not inferred from this record. Blank or corrupt metadata
/// cannot authorize fallback after target writes have been allowed. A target
/// choice requires matching actual card/volume identity and successful recovery.
/// Neither this CRC nor the unkeyed proof digest authenticates media.
pub fn recover(raw: *const [readiness.sector_bytes]u8, binding: Binding, target_recovered: bool, legacy_authoritative: bool) Error!Choice {
    try validate(binding);
    if (std.mem.allEqual(u8, raw, 0xff)) return if (legacy_authoritative) .legacy else error.RecoveryRequired;
    if (!std.mem.eql(u8, raw[0..8], magic) or
        std.hash.Crc32.hash(raw[0..crc_offset]) != std.mem.readInt(u32, raw[crc_offset..][0..4], .little) or
        !std.mem.allEqual(u8, raw[152..crc_offset], 0) or !target_recovered) return error.RecoveryRequired;
    const digest: [32]u8 = raw[120..152].*;
    if (std.mem.allEqual(u8, &digest, 0)) return error.RecoveryRequired;
    const expected = encode(binding, digest);
    if (!std.mem.eql(u8, raw, &expected)) return error.RecoveryRequired;
    return .target;
}

test "activation requires verified copy and never falls back after target writes" {
    const model = @import("checkpoint_model.zig");
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
    try source.put(1, "old");
    try source.commit();
    var scratch: migration.Scratch = .{};
    _ = try migration.copy(&source, &target, 1, 2, &scratch);
    a.powerLoss();
    b.powerLoss();
    source = .{};
    target = .{};
    try source.recover(a);
    try target.recover(b);
    const layout = readiness.Layout{ .card_sectors = 8192, .source_start = 2048, .source_count = 2048, .target_start = 4096, .target_count = 2048, .record_lba = 1 };
    const binding = Binding{ .layout = layout, .card_id = @splat(1), .target_id = @splat(2) };
    const proof = try readiness.prepare(&source, &target, layout, &scratch);
    const Meta = @import("model_media.zig").Media(512);
    var meta: Meta = .{};
    var guard: Guard = .{};
    try guard.activate(&meta, &proof, &source, &target, binding, &scratch);
    try std.testing.expectEqual(Guard.State.active, guard.state);
    meta.powerLoss();
    var raw: [512]u8 = undefined;
    try meta.read(0, &raw);
    try std.testing.expectEqual(Choice.target, try recover(&raw, binding, true, false));
    var duplicate_guard: Guard = .{};
    try std.testing.expectError(error.RecoveryRequired, duplicate_guard.activate(&meta, &proof, &source, &target, binding, &scratch));
    try std.testing.expectEqual(Guard.State.fenced, duplicate_guard.state);
    try target.begin();
    try target.put(1, "new target data");
    try target.commit();
    // A stale pre-activation proof must not cause any metadata writes.
    var stale_meta: Meta = .{};
    var stale_guard: Guard = .{};
    try std.testing.expectError(error.RecoveryRequired, stale_guard.activate(&stale_meta, &proof, &source, &target, binding, &scratch));
    try std.testing.expectEqual(@as(usize, 0), stale_meta.events);
    b.powerLoss();
    target = .{};
    try target.recover(b);
    try std.testing.expectEqual(Choice.target, try recover(&raw, binding, true, false));
    try std.testing.expectError(error.RecoveryRequired, recover(&raw, binding, false, true));
    var other = binding;
    other.target_id[0] ^= 1;
    try std.testing.expectError(error.RecoveryRequired, recover(&raw, other, true, true));
    const blank: [512]u8 = @splat(0xff);
    try std.testing.expectError(error.RecoveryRequired, recover(&blank, binding, true, false));
    var corrupted = raw;
    corrupted[40] ^= 1;
    try std.testing.expectError(error.RecoveryRequired, recover(&corrupted, binding, true, true));
}

test "activation write and sync cuts fence unknown outcome" {
    const model = @import("checkpoint_model.zig");
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
    const layout = readiness.Layout{ .card_sectors = 8192, .source_start = 2048, .source_count = 2048, .target_start = 4096, .target_count = 2048, .record_lba = 1 };
    const binding = Binding{ .layout = layout, .card_id = @splat(1), .target_id = @splat(2) };
    const proof = try readiness.prepare(&source, &target, layout, &scratch);
    const Meta = @import("model_media.zig").Media(512);
    var unknown: usize = 0;
    var success: usize = 0;
    var legacy: usize = 0;
    var selected: usize = 0;
    var fenced: usize = 0;
    for ([_]@import("model_media.zig").Background{ .none, .alternating, .all }) |background| for (0..4) |event| for ([_]usize{ 0, 1, 64, 511, 512 }) |prefix| {
        var meta: Meta = .{ .background = background, .cut = .{ .event = event, .prefix = prefix } };
        var guard: Guard = .{};
        var acknowledged = false;
        if (guard.activate(&meta, &proof, &source, &target, binding, &scratch)) |_| {
            success += 1;
            acknowledged = true;
            try std.testing.expectEqual(Guard.State.active, guard.state);
        } else |err| {
            try std.testing.expectEqual(error.PublicationUnknown, err);
            unknown += 1;
            try std.testing.expectEqual(Guard.State.fenced, guard.state);
            try std.testing.expectError(error.Fenced, guard.activate(&meta, &proof, &source, &target, binding, &scratch));
        }
        meta.powerLoss();
        var raw: [512]u8 = undefined;
        try meta.read(0, &raw);
        // In this test only, both stores remained frozen, so the old source is
        // independently known authoritative whenever activation was not acked.
        if (recover(&raw, binding, true, !acknowledged)) |choice| {
            if (acknowledged) try std.testing.expectEqual(Choice.target, choice);
            switch (choice) {
                .legacy => legacy += 1,
                .target => selected += 1,
            }
        } else |err| {
            try std.testing.expectEqual(error.RecoveryRequired, err);
            try std.testing.expect(!acknowledged);
            fenced += 1;
        }
        if (std.mem.allEqual(u8, &raw, 0xff)) try std.testing.expectError(error.RecoveryRequired, recover(&raw, binding, true, false));
    };
    try std.testing.expect(unknown > 0 and success > 0 and legacy > 0 and selected > 0 and fenced > 0);
    std.debug.print("CAPACITY_ACTIVATION cases={d} unknown={d} success={d} legacy={d} target={d} recovery={d}\n", .{ unknown + success, unknown, success, legacy, selected, fenced });
}
