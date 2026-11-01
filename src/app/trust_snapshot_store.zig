//! Crash-consistent storage ordering for authenticated trust snapshots.
//!
//! Snapshot format and root-signature verification are supplied by a separate
//! authority. The monotonic counter must be independently protected and make
//! `advance` atomic, durable, and non-decreasing.
const std = @import("std");

pub const slot_count: usize = 2;
pub const record_bytes: usize = 96;
const checksum_offset: usize = 64;
const magic = "NIHTRST1".*;
const format: u16 = 1;

const Offset = struct {
    const magic = 0;
    const format = 8;
    const bytes = 10;
    const snapshot_bytes = 12;
    const generation = 16;
    const epoch = 24;
    const digest = 32;
    const checksum = checksum_offset;
};

pub const IoError = error{ Io, PowerLoss };

pub const Storage = struct {
    context: *anyopaque,
    bytes: usize,
    readAt: *const fn (*anyopaque, usize, []u8) IoError!void,
    writeAt: *const fn (*anyopaque, usize, []const u8) IoError!void,
    sync: *const fn (*anyopaque) IoError!void,
};

pub const Monotonic = struct {
    context: *anyopaque,
    read: *const fn (*anyopaque) IoError!u64,
    advance: *const fn (*anyopaque, u64) IoError!void,
};

/// Returns the authenticated epoch or null. The epoch must be covered by the
/// authority's signature/MAC, not merely read from unauthenticated bytes.
pub const Authenticator = struct {
    context: *anyopaque,
    authenticate: *const fn (*anyopaque, []const u8) ?u64,
};

/// Nominally separate capability used only by `recoveryReplace`. Its callback
/// must accept recovery-authority snapshots and reject normal snapshots.
pub const RecoveryAuthenticator = struct {
    context: *anyopaque,
    authenticate: *const fn (*anyopaque, []const u8) ?u64,
};

pub const Layout = struct {
    max_snapshot_bytes: usize,

    pub fn requiredBytes(self: Layout) error{InvalidLayout}!usize {
        if (self.max_snapshot_bytes == 0 or self.max_snapshot_bytes > std.math.maxInt(u32))
            return error.InvalidLayout;
        const slot_stride = std.math.add(usize, self.max_snapshot_bytes, record_bytes) catch
            return error.InvalidLayout;
        return std.math.mul(usize, slot_count, slot_stride) catch error.InvalidLayout;
    }

    fn stride(self: Layout) usize {
        return self.max_snapshot_bytes + record_bytes;
    }

    fn snapshotOffset(self: Layout, slot: u1) usize {
        return @as(usize, slot) * self.stride();
    }

    fn recordOffset(self: Layout, slot: u1) usize {
        return self.snapshotOffset(slot) + self.max_snapshot_bytes;
    }
};

pub const State = struct {
    slot: u1,
    generation: u64,
    epoch: u64,
    snapshot_bytes: u32,
    snapshot_sha256: [32]u8,
};

pub const Disposition = enum { updated, already_current };
pub const Outcome = struct { state: State, disposition: Disposition };

pub const Error = IoError || error{
    InvalidLayout,
    StorageTooSmall,
    WorkspaceTooSmall,
    InvalidSnapshot,
    InvalidActiveSnapshot,
    SnapshotMissing,
    Rollback,
    EpochConflict,
    GenerationOverflow,
    CounterRollback,
    CorruptState,
    AmbiguousState,
    RecoveryStateUnavailable,
    RecoveryEpochRequired,
};

const Record = struct {
    snapshot_bytes: u32,
    generation: u64,
    epoch: u64,
    digest: [32]u8,
};

const Inspected = struct { state: State, bytes: []u8 };
const Structural = struct { slot: u1, record: Record };

/// Recovers the newest complete authenticated snapshot, rejects a state below
/// the protected floor, then advances a lagging counter before returning it.
pub fn recoverAndSeal(
    storage: Storage,
    monotonic: Monotonic,
    authenticator: Authenticator,
    layout: Layout,
    scratch: []u8,
) Error!?State {
    const floor = try monotonic.read(monotonic.context);
    const inspected = (try inspectHead(storage, authenticator, layout, scratch)) orelse {
        if (floor != 0) return error.SnapshotMissing;
        return null;
    };
    if (inspected.state.epoch < floor) return error.Rollback;
    if (inspected.state.epoch > floor) {
        try monotonic.advance(monotonic.context, inspected.state.epoch);
        const sealed = try monotonic.read(monotonic.context);
        if (sealed != inspected.state.epoch) return error.CounterRollback;
    }
    return inspected.state;
}

pub fn update(
    storage: Storage,
    monotonic: Monotonic,
    authenticator: Authenticator,
    layout: Layout,
    candidate: []const u8,
    scratch: []u8,
) Error!Outcome {
    return transition(storage, monotonic, authenticator, authenticator, layout, candidate, scratch);
}

/// Changes authority as well as content while authenticating the current and
/// candidate snapshots with separate capabilities. This is used to hand off a
/// recovery snapshot to a newly provisioned normal root.
pub fn transition(
    storage: Storage,
    monotonic: Monotonic,
    current_authenticator: Authenticator,
    candidate_authenticator: Authenticator,
    layout: Layout,
    candidate: []const u8,
    scratch: []u8,
) Error!Outcome {
    try validate(storage, layout, scratch);
    if (candidate.len == 0 or candidate.len > layout.max_snapshot_bytes)
        return error.InvalidSnapshot;
    const epoch = candidate_authenticator.authenticate(candidate_authenticator.context, candidate) orelse
        return error.InvalidSnapshot;
    if (epoch == 0) return error.InvalidSnapshot;
    const floor = try monotonic.read(monotonic.context);
    if (epoch < floor) return error.Rollback;

    const current = try inspectHead(storage, current_authenticator, layout, scratch);
    var target: u1 = 0;
    var generation: u64 = 1;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(candidate, &digest, .{});
    if (current) |active| {
        if (active.state.epoch < floor) return error.Rollback;
        if (epoch < active.state.epoch) return error.Rollback;
        if (epoch == active.state.epoch) {
            if (!std.mem.eql(u8, &digest, &active.state.snapshot_sha256))
                return error.EpochConflict;
            if (floor < epoch) try monotonic.advance(monotonic.context, epoch);
            return .{ .state = active.state, .disposition = .already_current };
        }
        target = active.state.slot ^ 1;
        generation = std.math.add(u64, active.state.generation, 1) catch
            return error.GenerationOverflow;
    }

    var invalid: [record_bytes]u8 = @splat(0);
    try storage.writeAt(storage.context, layout.recordOffset(target), &invalid);
    try storage.sync(storage.context);
    try storage.writeAt(storage.context, layout.snapshotOffset(target), candidate);
    try storage.sync(storage.context);
    const readback = scratch[0..candidate.len];
    try storage.readAt(storage.context, layout.snapshotOffset(target), readback);
    if (!std.mem.eql(u8, readback, candidate) or
        candidate_authenticator.authenticate(candidate_authenticator.context, readback) != epoch)
        return error.InvalidActiveSnapshot;

    const record = Record{
        .snapshot_bytes = @intCast(candidate.len),
        .generation = generation,
        .epoch = epoch,
        .digest = digest,
    };
    var encoded: [record_bytes]u8 = undefined;
    encode(&encoded, record);
    try storage.writeAt(storage.context, layout.recordOffset(target), &encoded);
    try storage.sync(storage.context);

    // Storage commit precedes the protected counter. A cut here leaves a newer
    // authenticated snapshot that recovery can safely seal on the next boot.
    try monotonic.advance(monotonic.context, epoch);
    const recovered = (try recoverAndSeal(
        storage,
        monotonic,
        candidate_authenticator,
        layout,
        scratch,
    )) orelse return error.InvalidActiveSnapshot;
    if (recovered.slot != target or recovered.generation != generation or recovered.epoch != epoch)
        return error.InvalidActiveSnapshot;
    return .{ .state = recovered, .disposition = .updated };
}

/// Replaces a snapshot whose normal root is no longer trusted. It uses only a
/// checksummed commit record at the protected floor to choose the inactive
/// slot; it never re-enables or authenticates the revoked root.
pub fn recoveryReplace(
    storage: Storage,
    monotonic: Monotonic,
    recovery_authenticator: RecoveryAuthenticator,
    layout: Layout,
    candidate: []const u8,
    scratch: []u8,
) Error!Outcome {
    try validate(storage, layout, scratch);
    if (candidate.len == 0 or candidate.len > layout.max_snapshot_bytes)
        return error.InvalidSnapshot;
    const epoch = recovery_authenticator.authenticate(
        recovery_authenticator.context,
        candidate,
    ) orelse return error.InvalidSnapshot;
    const floor = try monotonic.read(monotonic.context);
    if (floor == 0 or epoch < floor) return error.RecoveryEpochRequired;
    const structural = (try structuralHead(storage, layout)) orelse
        return error.RecoveryStateUnavailable;

    var candidate_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(candidate, &candidate_digest, .{});
    if (structural.record.epoch == epoch) {
        if (structural.record.snapshot_bytes != candidate.len or
            !std.mem.eql(u8, &structural.record.digest, &candidate_digest))
            return error.EpochConflict;
        const bytes = scratch[0..candidate.len];
        try storage.readAt(storage.context, layout.snapshotOffset(structural.slot), bytes);
        if (!std.mem.eql(u8, bytes, candidate) or
            recovery_authenticator.authenticate(recovery_authenticator.context, bytes) != epoch)
            return error.InvalidActiveSnapshot;
        if (floor < epoch) try monotonic.advance(monotonic.context, epoch);
        const sealed = try monotonic.read(monotonic.context);
        if (sealed != epoch) return error.CounterRollback;
        return .{
            .state = stateFromRecord(structural.slot, structural.record),
            .disposition = .already_current,
        };
    }
    if (epoch == floor or structural.record.epoch > floor)
        return error.RecoveryStateUnavailable;
    if (structural.record.epoch != floor) return error.RecoveryStateUnavailable;
    const generation = std.math.add(u64, structural.record.generation, 1) catch
        return error.GenerationOverflow;
    const target = structural.slot ^ 1;

    var invalid: [record_bytes]u8 = @splat(0);
    try storage.writeAt(storage.context, layout.recordOffset(target), &invalid);
    try storage.sync(storage.context);
    try storage.writeAt(storage.context, layout.snapshotOffset(target), candidate);
    try storage.sync(storage.context);
    const readback = scratch[0..candidate.len];
    try storage.readAt(storage.context, layout.snapshotOffset(target), readback);
    if (!std.mem.eql(u8, readback, candidate) or
        recovery_authenticator.authenticate(recovery_authenticator.context, readback) != epoch)
        return error.InvalidActiveSnapshot;
    const record = Record{
        .snapshot_bytes = @intCast(candidate.len),
        .generation = generation,
        .epoch = epoch,
        .digest = candidate_digest,
    };
    var encoded: [record_bytes]u8 = undefined;
    encode(&encoded, record);
    try storage.writeAt(storage.context, layout.recordOffset(target), &encoded);
    try storage.sync(storage.context);
    try monotonic.advance(monotonic.context, epoch);
    const sealed = try monotonic.read(monotonic.context);
    if (sealed != epoch) return error.CounterRollback;
    return .{ .state = stateFromRecord(target, record), .disposition = .updated };
}

pub fn readSnapshot(
    storage: Storage,
    layout: Layout,
    state: State,
    output: []u8,
) Error![]u8 {
    try validateBounds(storage, layout);
    if (state.snapshot_bytes > layout.max_snapshot_bytes or output.len < state.snapshot_bytes)
        return error.WorkspaceTooSmall;
    const result = output[0..state.snapshot_bytes];
    try storage.readAt(storage.context, layout.snapshotOffset(state.slot), result);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(result, &digest, .{});
    if (!std.mem.eql(u8, &digest, &state.snapshot_sha256))
        return error.InvalidActiveSnapshot;
    return result;
}

fn inspectHead(
    storage: Storage,
    authenticator: Authenticator,
    layout: Layout,
    scratch: []u8,
) Error!?Inspected {
    try validate(storage, layout, scratch);
    var records: [slot_count]?Record = .{ null, null };
    for (0..slot_count) |slot| records[slot] = try readRecord(storage, layout, @intCast(slot));
    if (records[0] == null and records[1] == null) return null;
    var slot: u1 = if (records[0] != null) 0 else 1;
    if (records[0] != null and records[1] != null) {
        if (records[0].?.generation == records[1].?.generation) return error.AmbiguousState;
        slot = if (records[1].?.generation > records[0].?.generation) 1 else 0;
    }
    const head = records[slot].?;
    for (records) |entry| if (entry) |record| {
        if (record.epoch > head.epoch) return error.CorruptState;
    };
    const bytes = scratch[0..head.snapshot_bytes];
    try storage.readAt(storage.context, layout.snapshotOffset(slot), bytes);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    if (!std.mem.eql(u8, &digest, &head.digest)) return error.InvalidActiveSnapshot;
    if (authenticator.authenticate(authenticator.context, bytes) != head.epoch)
        return error.InvalidActiveSnapshot;
    return .{
        .state = .{
            .slot = slot,
            .generation = head.generation,
            .epoch = head.epoch,
            .snapshot_bytes = head.snapshot_bytes,
            .snapshot_sha256 = head.digest,
        },
        .bytes = bytes,
    };
}

fn structuralHead(storage: Storage, layout: Layout) Error!?Structural {
    try validateBounds(storage, layout);
    var records: [slot_count]?Record = .{ null, null };
    for (0..slot_count) |slot| records[slot] = try readRecord(storage, layout, @intCast(slot));
    if (records[0] == null and records[1] == null) return null;
    var slot: u1 = if (records[0] != null) 0 else 1;
    if (records[0] != null and records[1] != null) {
        if (records[0].?.generation == records[1].?.generation) return error.AmbiguousState;
        slot = if (records[1].?.generation > records[0].?.generation) 1 else 0;
    }
    return .{ .slot = slot, .record = records[slot].? };
}

fn stateFromRecord(slot: u1, record: Record) State {
    return .{
        .slot = slot,
        .generation = record.generation,
        .epoch = record.epoch,
        .snapshot_bytes = record.snapshot_bytes,
        .snapshot_sha256 = record.digest,
    };
}

fn validate(storage: Storage, layout: Layout, scratch: []u8) Error!void {
    try validateBounds(storage, layout);
    if (scratch.len < layout.max_snapshot_bytes) return error.WorkspaceTooSmall;
}

fn validateBounds(storage: Storage, layout: Layout) Error!void {
    const required = layout.requiredBytes() catch return error.InvalidLayout;
    if (storage.bytes < required) return error.StorageTooSmall;
}

fn readRecord(storage: Storage, layout: Layout, slot: u1) IoError!?Record {
    var bytes: [record_bytes]u8 = undefined;
    try storage.readAt(storage.context, layout.recordOffset(slot), &bytes);
    const record = decode(&bytes) orelse return null;
    if (record.snapshot_bytes > layout.max_snapshot_bytes) return null;
    return record;
}

fn encode(output: *[record_bytes]u8, record: Record) void {
    @memset(output, 0);
    @memcpy(output[Offset.magic..Offset.format], &magic);
    write16(output, Offset.format, format);
    write16(output, Offset.bytes, record_bytes);
    write32(output, Offset.snapshot_bytes, record.snapshot_bytes);
    write64(output, Offset.generation, record.generation);
    write64(output, Offset.epoch, record.epoch);
    @memcpy(output[Offset.digest..Offset.checksum], &record.digest);
    var checksum: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(output[0..Offset.checksum], &checksum, .{});
    @memcpy(output[Offset.checksum..record_bytes], &checksum);
}

fn decode(bytes: *const [record_bytes]u8) ?Record {
    if (!std.mem.eql(u8, bytes[Offset.magic..Offset.format], &magic) or
        read16(bytes, Offset.format) != format or read16(bytes, Offset.bytes) != record_bytes)
        return null;
    var checksum: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes[0..Offset.checksum], &checksum, .{});
    if (!std.mem.eql(u8, &checksum, bytes[Offset.checksum..record_bytes])) return null;
    const record = Record{
        .snapshot_bytes = read32(bytes, Offset.snapshot_bytes),
        .generation = read64(bytes, Offset.generation),
        .epoch = read64(bytes, Offset.epoch),
        .digest = bytes[Offset.digest..Offset.checksum].*,
    };
    if (record.snapshot_bytes == 0 or record.generation == 0 or record.epoch == 0) return null;
    return record;
}

fn read16(bytes: []const u8, offset: usize) u16 {
    return @as(u16, bytes[offset]) | (@as(u16, bytes[offset + 1]) << 8);
}
fn read32(bytes: []const u8, offset: usize) u32 {
    return @as(u32, bytes[offset]) | (@as(u32, bytes[offset + 1]) << 8) |
        (@as(u32, bytes[offset + 2]) << 16) | (@as(u32, bytes[offset + 3]) << 24);
}
fn read64(bytes: []const u8, offset: usize) u64 {
    return @as(u64, read32(bytes, offset)) | (@as(u64, read32(bytes, offset + 4)) << 32);
}
fn write16(bytes: []u8, offset: usize, value: anytype) void {
    const v: u16 = @intCast(value);
    bytes[offset] = @truncate(v);
    bytes[offset + 1] = @truncate(v >> 8);
}
fn write32(bytes: []u8, offset: usize, value: anytype) void {
    const v: u32 = @intCast(value);
    bytes[offset] = @truncate(v);
    bytes[offset + 1] = @truncate(v >> 8);
    bytes[offset + 2] = @truncate(v >> 16);
    bytes[offset + 3] = @truncate(v >> 24);
}
fn write64(bytes: []u8, offset: usize, value: u64) void {
    write32(bytes, offset, @as(u32, @truncate(value)));
    write32(bytes, offset + 4, @as(u32, @truncate(value >> 32)));
}

const test_max = 128;
const test_bytes = slot_count * (test_max + record_bytes);

const World = struct {
    data: [test_bytes]u8 = @splat(0xff),
    floor: u64 = 0,
    events: usize = 0,
    fail_at: ?usize = null,

    fn storage(self: *World) Storage {
        return .{ .context = self, .bytes = self.data.len, .readAt = readAt, .writeAt = writeAt, .sync = sync };
    }
    fn counter(self: *World) Monotonic {
        return .{ .context = self, .read = readFloor, .advance = advance };
    }
    fn readAt(context: *anyopaque, offset: usize, output: []u8) IoError!void {
        const self: *World = @ptrCast(@alignCast(context));
        const end = std.math.add(usize, offset, output.len) catch return error.Io;
        if (end > self.data.len) return error.Io;
        @memcpy(output, self.data[offset..end]);
    }
    fn writeAt(context: *anyopaque, offset: usize, input: []const u8) IoError!void {
        const self: *World = @ptrCast(@alignCast(context));
        const end = std.math.add(usize, offset, input.len) catch return error.Io;
        if (end > self.data.len) return error.Io;
        for (input, 0..) |byte, index| {
            if (self.fail_at == self.events) return error.PowerLoss;
            self.data[offset + index] = byte;
            self.events += 1;
        }
    }
    fn sync(context: *anyopaque) IoError!void {
        const self: *World = @ptrCast(@alignCast(context));
        if (self.fail_at == self.events) return error.PowerLoss;
        self.events += 1;
    }
    fn readFloor(context: *anyopaque) IoError!u64 {
        const self: *World = @ptrCast(@alignCast(context));
        return self.floor;
    }
    fn advance(context: *anyopaque, epoch: u64) IoError!void {
        const self: *World = @ptrCast(@alignCast(context));
        if (epoch < self.floor) return error.Io;
        if (self.fail_at == self.events) return error.PowerLoss;
        self.floor = epoch;
        self.events += 1;
    }
};

fn snapshot(epoch: u64, marker: u8) [64]u8 {
    var bytes: [64]u8 = @splat(0);
    @memcpy(bytes[0..8], "TESTROOT");
    write64(&bytes, 8, epoch);
    bytes[16] = marker;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes[0..32], &digest, .{});
    @memcpy(bytes[32..64], &digest);
    return bytes;
}

fn authenticate(_: *anyopaque, bytes: []const u8) ?u64 {
    if (bytes.len != 64 or !std.mem.eql(u8, bytes[0..8], "TESTROOT")) return null;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes[0..32], &digest, .{});
    if (!std.mem.eql(u8, &digest, bytes[32..64])) return null;
    const epoch = read64(bytes, 8);
    return if (epoch == 0) null else epoch;
}

fn testAuthenticator() Authenticator {
    const Context = struct {
        var byte: u8 = 0;
    };
    return .{ .context = &Context.byte, .authenticate = authenticate };
}

test "trust snapshot and monotonic floor survive every update cut" {
    const t = std.testing;
    const layout = Layout{ .max_snapshot_bytes = test_max };
    const first = snapshot(1, 1);
    const second = snapshot(2, 2);
    var scratch: [test_max]u8 = undefined;
    var base = World{};
    _ = try update(base.storage(), base.counter(), testAuthenticator(), layout, &first, &scratch);
    try t.expectEqual(@as(u64, 1), base.floor);

    var successful = base;
    successful.events = 0;
    _ = try update(successful.storage(), successful.counter(), testAuthenticator(), layout, &second, &scratch);
    const event_count = successful.events;
    try t.expectEqual(@as(usize, 260), event_count);
    try t.expectEqual(@as(u64, 2), successful.floor);

    var cut: usize = 0;
    while (cut < event_count) : (cut += 1) {
        var crashed = base;
        crashed.events = 0;
        crashed.fail_at = cut;
        try t.expectError(error.PowerLoss, update(
            crashed.storage(),
            crashed.counter(),
            testAuthenticator(),
            layout,
            &second,
            &scratch,
        ));
        crashed.fail_at = null;
        const recovered = (try recoverAndSeal(
            crashed.storage(),
            crashed.counter(),
            testAuthenticator(),
            layout,
            &scratch,
        )).?;
        try t.expect(recovered.epoch == 1 or recovered.epoch == 2);
        try t.expectEqual(recovered.epoch, crashed.floor);
        const bytes = try readSnapshot(crashed.storage(), layout, recovered, &scratch);
        try t.expectEqualSlices(u8, if (recovered.epoch == 1) &first else &second, bytes);
    }
    std.debug.print(
        "NIHOS_TRUST_SNAPSHOT crash_cuts={d} old_or_new=1 sealed=1 partial=0\n",
        .{event_count},
    );
}

test "protected floor rejects whole-medium rollback and damaged head record" {
    const t = std.testing;
    const layout = Layout{ .max_snapshot_bytes = test_max };
    const first = snapshot(1, 1);
    const second = snapshot(2, 2);
    var scratch: [test_max]u8 = undefined;
    var old = World{};
    _ = try update(old.storage(), old.counter(), testAuthenticator(), layout, &first, &scratch);
    var current = old;
    _ = try update(current.storage(), current.counter(), testAuthenticator(), layout, &second, &scratch);
    try t.expectEqual(@as(u64, 2), current.floor);

    var restored = old;
    restored.floor = current.floor;
    try t.expectError(error.Rollback, recoverAndSeal(
        restored.storage(),
        restored.counter(),
        testAuthenticator(),
        layout,
        &scratch,
    ));

    const active = (try recoverAndSeal(
        current.storage(),
        current.counter(),
        testAuthenticator(),
        layout,
        &scratch,
    )).?;
    current.data[layout.recordOffset(active.slot)] ^= 1;
    try t.expectError(error.Rollback, recoverAndSeal(
        current.storage(),
        current.counter(),
        testAuthenticator(),
        layout,
        &scratch,
    ));
}
