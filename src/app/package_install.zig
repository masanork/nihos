//! Crash-consistent two-slot installation model for signed nihos packages.
//!
//! This module owns commit ordering and the persistent package-sequence floor.
//! It deliberately does not choose a filesystem, flash erase geometry, key
//! store, or user-consent policy. A storage adapter must make `sync` truthful.
const std = @import("std");
const package = @import("app_package");
const policy = @import("app_policy");

pub const slot_count: usize = 2;
pub const record_bytes: usize = 144;
const record_checksum_offset: usize = 112;
const record_magic = "NIHINST1".*;
const record_format: u16 = 1;

const Offset = struct {
    const magic = 0;
    const format = 8;
    const bytes = 10;
    const package_bytes = 12;
    const generation = 16;
    const sequence = 24;
    const trust_epoch = 32;
    const module_id = 40;
    const publisher_id = 56;
    const package_sha256 = 72;
    const reserved = 104;
    const checksum = record_checksum_offset;
};

pub const IoError = error{ Io, PowerLoss };

pub const Storage = struct {
    context: *anyopaque,
    bytes: usize,
    readAt: *const fn (*anyopaque, usize, []u8) IoError!void,
    writeAt: *const fn (*anyopaque, usize, []const u8) IoError!void,
    sync: *const fn (*anyopaque) IoError!void,

    fn read(self: Storage, offset: usize, output: []u8) IoError!void {
        return self.readAt(self.context, offset, output);
    }

    fn write(self: Storage, offset: usize, input: []const u8) IoError!void {
        return self.writeAt(self.context, offset, input);
    }

    fn flush(self: Storage) IoError!void {
        return self.sync(self.context);
    }
};

pub const Layout = struct {
    max_package_bytes: usize,

    pub fn requiredBytes(self: Layout) error{InvalidLayout}!usize {
        if (self.max_package_bytes < package.header_bytes) return error.InvalidLayout;
        const stride = std.math.add(usize, self.max_package_bytes, record_bytes) catch
            return error.InvalidLayout;
        return std.math.mul(usize, slot_count, stride) catch error.InvalidLayout;
    }

    fn slotStride(self: Layout) usize {
        return self.max_package_bytes + record_bytes;
    }

    fn packageOffset(self: Layout, slot: u1) usize {
        return @as(usize, slot) * self.slotStride();
    }

    fn recordOffset(self: Layout, slot: u1) usize {
        return self.packageOffset(slot) + self.max_package_bytes;
    }
};

pub const Verification = struct {
    trust_epoch: u64,
    max_signature_bytes: u16,
    trust: package.TrustProvider,
    limits: policy.Limits,
};

pub const Installed = struct {
    slot: u1,
    generation: u64,
    sequence: u64,
    trust_epoch: u64,
    package_bytes: u32,
    module_id: [16]u8,
    publisher_id: [16]u8,
    package_sha256: [32]u8,
};

pub const Disposition = enum { installed, already_installed };

pub const Outcome = struct {
    state: Installed,
    disposition: Disposition,
};

pub const Error = IoError || error{
    InvalidLayout,
    StorageTooSmall,
    WorkspaceTooSmall,
    InvalidPackage,
    RejectedPackage,
    ActivePackageInvalid,
    ActivePackageRejected,
    AmbiguousState,
    CorruptState,
    TrustSnapshotTooOld,
    StaleTrustSnapshot,
    WrongIdentity,
    Rollback,
    SequenceConflict,
    GenerationOverflow,
};

const Record = struct {
    package_bytes: u32,
    generation: u64,
    sequence: u64,
    trust_epoch: u64,
    module_id: [16]u8,
    publisher_id: [16]u8,
    package_sha256: [32]u8,
};

const Inspected = struct {
    state: Installed,
    envelope: package.Envelope,
};

pub fn recover(
    storage: Storage,
    layout: Layout,
    verification: Verification,
    package_scratch: []u8,
) Error!?Installed {
    if (verification.trust_epoch == 0) return error.TrustSnapshotTooOld;
    const inspected = (try inspectHead(storage, layout, package_scratch)) orelse return null;
    if (inspected.state.trust_epoch > verification.trust_epoch)
        return error.TrustSnapshotTooOld;
    const admission = package.admit(inspected.envelope, verification.trust, verification.limits);
    if (!admission.accepted()) return error.ActivePackageRejected;
    return inspected.state;
}

/// Installs an already signed package into the inactive slot. Candidate trust
/// and policy are checked before any write and again after durable readback.
/// The commit record is written last, so a cut exposes either the prior record
/// or the complete new record, never a partially installed package.
pub fn install(
    storage: Storage,
    layout: Layout,
    candidate: []const u8,
    verification: Verification,
    package_scratch: []u8,
) Error!Outcome {
    try validateStorage(storage, layout, package_scratch);
    if (verification.trust_epoch == 0) return error.StaleTrustSnapshot;
    const envelope = package.parse(candidate, .{
        .max_package_bytes = @intCast(layout.max_package_bytes),
        .max_signature_bytes = verification.max_signature_bytes,
    }) catch return error.InvalidPackage;
    const admission = package.admit(envelope, verification.trust, verification.limits);
    if (!admission.accepted()) return error.RejectedPackage;

    const current = try inspectHead(storage, layout, package_scratch);
    var target: u1 = 0;
    var generation: u64 = 1;
    if (current) |active| {
        if (!sameIdentity(active.state, envelope)) return error.WrongIdentity;
        if (verification.trust_epoch < active.state.trust_epoch)
            return error.StaleTrustSnapshot;
        if (envelope.sequence < active.state.sequence) return error.Rollback;

        var candidate_digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(candidate, &candidate_digest, .{});
        if (envelope.sequence == active.state.sequence) {
            if (!std.mem.eql(u8, &candidate_digest, &active.state.package_sha256))
                return error.SequenceConflict;
            if (verification.trust_epoch == active.state.trust_epoch) {
                return .{ .state = active.state, .disposition = .already_installed };
            }
        }
        target = active.state.slot ^ 1;
        generation = std.math.add(u64, active.state.generation, 1) catch
            return error.GenerationOverflow;
    }

    // Invalidate and durably clear the inactive commit record before reusing
    // its payload area. The active slot is never touched by this transaction.
    var empty_record: [record_bytes]u8 = @splat(0);
    try storage.write(layout.recordOffset(target), &empty_record);
    try storage.flush();
    try storage.write(layout.packageOffset(target), candidate);
    try storage.flush();

    const readback = package_scratch[0..candidate.len];
    try storage.read(layout.packageOffset(target), readback);
    if (!std.mem.eql(u8, readback, candidate)) return error.ActivePackageInvalid;
    const readback_envelope = package.parse(readback, .{
        .max_package_bytes = @intCast(layout.max_package_bytes),
        .max_signature_bytes = verification.max_signature_bytes,
    }) catch return error.ActivePackageInvalid;
    const readback_admission = package.admit(
        readback_envelope,
        verification.trust,
        verification.limits,
    );
    if (!readback_admission.accepted()) return error.ActivePackageRejected;

    var package_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(readback, &package_digest, .{});
    const record = Record{
        .package_bytes = @intCast(readback.len),
        .generation = generation,
        .sequence = readback_envelope.sequence,
        .trust_epoch = verification.trust_epoch,
        .module_id = readback_envelope.module_id,
        .publisher_id = readback_envelope.publisher_id,
        .package_sha256 = package_digest,
    };
    var encoded: [record_bytes]u8 = undefined;
    encodeRecord(&encoded, record);
    try storage.write(layout.recordOffset(target), &encoded);
    try storage.flush();

    const installed = (try recover(storage, layout, verification, package_scratch)) orelse
        return error.ActivePackageInvalid;
    if (installed.slot != target or installed.generation != generation or
        installed.sequence != readback_envelope.sequence)
        return error.ActivePackageInvalid;
    return .{ .state = installed, .disposition = .installed };
}

pub fn readInstalled(
    storage: Storage,
    layout: Layout,
    installed: Installed,
    output: []u8,
) Error![]u8 {
    try validateBounds(storage, layout);
    if (installed.package_bytes > layout.max_package_bytes or
        output.len < installed.package_bytes) return error.WorkspaceTooSmall;
    const result = output[0..installed.package_bytes];
    try storage.read(layout.packageOffset(installed.slot), result);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(result, &digest, .{});
    if (!std.mem.eql(u8, &digest, &installed.package_sha256))
        return error.ActivePackageInvalid;
    return result;
}

fn inspectHead(storage: Storage, layout: Layout, package_scratch: []u8) Error!?Inspected {
    try validateStorage(storage, layout, package_scratch);
    var records: [slot_count]?Record = .{ null, null };
    for (0..slot_count) |slot| records[slot] = try readRecord(storage, layout, @intCast(slot));
    if (records[0] == null and records[1] == null) return null;

    var head_slot: u1 = if (records[0] != null) 0 else 1;
    if (records[0] != null and records[1] != null) {
        const left = records[0].?;
        const right = records[1].?;
        if (!sameRecordIdentity(left, right)) return error.CorruptState;
        if (left.generation == right.generation) return error.AmbiguousState;
        head_slot = if (right.generation > left.generation) 1 else 0;
    }
    const head = records[head_slot].?;
    for (records) |entry| if (entry) |record| {
        if (record.sequence > head.sequence or record.trust_epoch > head.trust_epoch)
            return error.CorruptState;
    };

    const bytes = package_scratch[0..head.package_bytes];
    try storage.read(layout.packageOffset(head_slot), bytes);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    if (!std.mem.eql(u8, &digest, &head.package_sha256))
        return error.ActivePackageInvalid;
    const envelope = package.parse(bytes, .{
        .max_package_bytes = @intCast(layout.max_package_bytes),
        .max_signature_bytes = std.math.maxInt(u16),
    }) catch return error.ActivePackageInvalid;
    if (envelope.sequence != head.sequence or
        !std.mem.eql(u8, &envelope.module_id, &head.module_id) or
        !std.mem.eql(u8, &envelope.publisher_id, &head.publisher_id))
        return error.ActivePackageInvalid;
    return .{
        .state = .{
            .slot = head_slot,
            .generation = head.generation,
            .sequence = head.sequence,
            .trust_epoch = head.trust_epoch,
            .package_bytes = head.package_bytes,
            .module_id = head.module_id,
            .publisher_id = head.publisher_id,
            .package_sha256 = head.package_sha256,
        },
        .envelope = envelope,
    };
}

fn validateStorage(storage: Storage, layout: Layout, scratch: []u8) Error!void {
    try validateBounds(storage, layout);
    if (scratch.len < layout.max_package_bytes) return error.WorkspaceTooSmall;
}

fn validateBounds(storage: Storage, layout: Layout) Error!void {
    const required = layout.requiredBytes() catch return error.InvalidLayout;
    if (storage.bytes < required) return error.StorageTooSmall;
    if (layout.max_package_bytes > std.math.maxInt(u32)) return error.InvalidLayout;
}

fn readRecord(storage: Storage, layout: Layout, slot: u1) IoError!?Record {
    var bytes: [record_bytes]u8 = undefined;
    try storage.read(layout.recordOffset(slot), &bytes);
    const record = decodeRecord(&bytes) orelse return null;
    if (record.package_bytes > layout.max_package_bytes) return null;
    return record;
}

fn encodeRecord(output: *[record_bytes]u8, record: Record) void {
    @memset(output, 0);
    @memcpy(output[Offset.magic..Offset.format], &record_magic);
    write16(output, Offset.format, record_format);
    write16(output, Offset.bytes, record_bytes);
    write32(output, Offset.package_bytes, record.package_bytes);
    write64(output, Offset.generation, record.generation);
    write64(output, Offset.sequence, record.sequence);
    write64(output, Offset.trust_epoch, record.trust_epoch);
    @memcpy(output[Offset.module_id..Offset.publisher_id], &record.module_id);
    @memcpy(output[Offset.publisher_id..Offset.package_sha256], &record.publisher_id);
    @memcpy(output[Offset.package_sha256..Offset.reserved], &record.package_sha256);
    var checksum: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(output[0..Offset.checksum], &checksum, .{});
    @memcpy(output[Offset.checksum..record_bytes], &checksum);
}

fn decodeRecord(bytes: *const [record_bytes]u8) ?Record {
    if (!std.mem.eql(u8, bytes[Offset.magic..Offset.format], &record_magic)) return null;
    if (read16(bytes, Offset.format) != record_format or
        read16(bytes, Offset.bytes) != record_bytes or
        !allZero(bytes[Offset.reserved..Offset.checksum])) return null;
    var checksum: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes[0..Offset.checksum], &checksum, .{});
    if (!std.mem.eql(u8, &checksum, bytes[Offset.checksum..record_bytes])) return null;
    const result = Record{
        .package_bytes = read32(bytes, Offset.package_bytes),
        .generation = read64(bytes, Offset.generation),
        .sequence = read64(bytes, Offset.sequence),
        .trust_epoch = read64(bytes, Offset.trust_epoch),
        .module_id = bytes[Offset.module_id..Offset.publisher_id].*,
        .publisher_id = bytes[Offset.publisher_id..Offset.package_sha256].*,
        .package_sha256 = bytes[Offset.package_sha256..Offset.reserved].*,
    };
    if (result.package_bytes == 0 or result.generation == 0 or
        result.sequence == 0 or result.trust_epoch == 0) return null;
    return result;
}

fn sameIdentity(state: Installed, envelope: package.Envelope) bool {
    return std.mem.eql(u8, &state.module_id, &envelope.module_id) and
        std.mem.eql(u8, &state.publisher_id, &envelope.publisher_id);
}

fn sameRecordIdentity(left: Record, right: Record) bool {
    return std.mem.eql(u8, &left.module_id, &right.module_id) and
        std.mem.eql(u8, &left.publisher_id, &right.publisher_id);
}

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}

fn read16(bytes: []const u8, offset: usize) u16 {
    return @as(u16, bytes[offset]) | (@as(u16, bytes[offset + 1]) << 8);
}

fn read32(bytes: []const u8, offset: usize) u32 {
    return @as(u32, bytes[offset]) |
        (@as(u32, bytes[offset + 1]) << 8) |
        (@as(u32, bytes[offset + 2]) << 16) |
        (@as(u32, bytes[offset + 3]) << 24);
}

fn read64(bytes: []const u8, offset: usize) u64 {
    return @as(u64, read32(bytes, offset)) | (@as(u64, read32(bytes, offset + 4)) << 32);
}

fn write16(bytes: []u8, offset: usize, value: anytype) void {
    const cast: u16 = @intCast(value);
    bytes[offset] = @truncate(cast);
    bytes[offset + 1] = @truncate(cast >> 8);
}

fn write32(bytes: []u8, offset: usize, value: anytype) void {
    const cast: u32 = @intCast(value);
    bytes[offset] = @truncate(cast);
    bytes[offset + 1] = @truncate(cast >> 8);
    bytes[offset + 2] = @truncate(cast >> 16);
    bytes[offset + 3] = @truncate(cast >> 24);
}

fn write64(bytes: []u8, offset: usize, value: u64) void {
    write32(bytes, offset, @as(u32, @truncate(value)));
    write32(bytes, offset + 4, @as(u32, @truncate(value >> 32)));
}

const test_max_package = 512;
const test_storage_bytes = slot_count * (test_max_package + record_bytes);

const MemoryStorage = struct {
    durable: [test_storage_bytes]u8 = @splat(0xff),
    fail_at: ?usize = null,
    events: usize = 0,

    fn interface(self: *MemoryStorage) Storage {
        return .{
            .context = self,
            .bytes = self.durable.len,
            .readAt = readAt,
            .writeAt = writeAt,
            .sync = sync,
        };
    }

    fn readAt(context: *anyopaque, offset: usize, output: []u8) IoError!void {
        const self: *MemoryStorage = @ptrCast(@alignCast(context));
        const end = std.math.add(usize, offset, output.len) catch return error.Io;
        if (end > self.durable.len) return error.Io;
        @memcpy(output, self.durable[offset..end]);
    }

    fn writeAt(context: *anyopaque, offset: usize, input: []const u8) IoError!void {
        const self: *MemoryStorage = @ptrCast(@alignCast(context));
        const end = std.math.add(usize, offset, input.len) catch return error.Io;
        if (end > self.durable.len) return error.Io;
        for (input, 0..) |byte, index| {
            if (self.fail_at == self.events) return error.PowerLoss;
            self.durable[offset + index] = byte;
            self.events += 1;
        }
    }

    fn sync(context: *anyopaque) IoError!void {
        const self: *MemoryStorage = @ptrCast(@alignCast(context));
        if (self.fail_at == self.events) return error.PowerLoss;
        self.events += 1;
    }
};

const TestPackage = struct {
    bytes: [test_max_package]u8 = @splat(0),
    length: usize = 0,

    fn slice(self: *const TestPackage) []const u8 {
        return self.bytes[0..self.length];
    }
};

fn makeTestPackage(sequence: u64, version: u32, marker: u8) TestPackage {
    var result = TestPackage{};
    const wasm = [_]u8{ 0x00, 0x61, 0x73, 0x6d, marker };
    const prepared = package.prepare(&result.bytes, .{
        .algorithm = 7,
        .signature_bytes = 64,
        .sequence = sequence,
        .schema = policy.current_schema,
        .sdk_abi = policy.current_sdk_abi,
        .module_id = "nihos-rust-wasm1".*,
        .publisher_id = "nihos.dev/system".*,
        .version = version,
        .services = policy.Service.graphics,
        .max_linear_pages = 1,
        .instruction_budget = 10_000,
        .key_id = "publisher-key-01".*,
        .wasm = &wasm,
    }) catch @panic("invalid install test fixture");
    @memset(prepared.signature, 0xa5);
    result.length = prepared.package.len;
    return result;
}

const MockTrust = struct { minimum_sequence: u64 = 1 };

fn testVerification(mock: *MockTrust, trust_epoch: u64) Verification {
    return .{
        .trust_epoch = trust_epoch,
        .max_signature_bytes = 64,
        .trust = .{
            .context = mock,
            .keyStatus = testKeyStatus,
            .minimumSequence = testMinimumSequence,
            .verifySignature = testVerifySignature,
        },
        .limits = .{
            .granted_services = policy.Service.graphics,
            .max_linear_pages = 1,
            .max_instruction_budget = 10_000,
            .max_wasm_bytes = test_max_package,
        },
    };
}

fn testKeyStatus(_: *anyopaque, publisher: [16]u8, key: [16]u8) package.KeyStatus {
    if (!std.mem.eql(u8, &publisher, "nihos.dev/system") or
        !std.mem.eql(u8, &key, "publisher-key-01")) return .unknown;
    return .trusted;
}

fn testMinimumSequence(context: *anyopaque, _: [16]u8, _: [16]u8) u64 {
    const mock: *MockTrust = @ptrCast(@alignCast(context));
    return mock.minimum_sequence;
}

fn testVerifySignature(
    _: *anyopaque,
    algorithm: u16,
    _: [16]u8,
    _: [16]u8,
    _: []const u8,
    signature: []const u8,
) package.SignatureStatus {
    return if (algorithm == 7 and signature.len == 64 and signature[0] == 0xa5)
        .verified
    else
        .invalid;
}

test "two-slot update survives every byte and sync cut as old or new" {
    const t = std.testing;
    const layout = Layout{ .max_package_bytes = test_max_package };
    var mock = MockTrust{};
    const first = makeTestPackage(1, 1, 1);
    const second = makeTestPackage(2, 2, 2);
    var scratch: [test_max_package]u8 = undefined;
    var base = MemoryStorage{};
    const initial = try install(base.interface(), layout, first.slice(), testVerification(&mock, 1), &scratch);
    try t.expectEqual(@as(u64, 1), initial.state.sequence);

    var successful = base;
    successful.events = 0;
    const updated = try install(
        successful.interface(),
        layout,
        second.slice(),
        testVerification(&mock, 2),
        &scratch,
    );
    const event_count = successful.events;
    try t.expectEqual(@as(u64, 2), updated.state.sequence);
    try t.expectEqual(@as(usize, 504), event_count);

    var cut: usize = 0;
    while (cut < event_count) : (cut += 1) {
        var crashed = base;
        crashed.events = 0;
        crashed.fail_at = cut;
        try t.expectError(error.PowerLoss, install(
            crashed.interface(),
            layout,
            second.slice(),
            testVerification(&mock, 2),
            &scratch,
        ));
        crashed.fail_at = null;
        const recovered = (try recover(
            crashed.interface(),
            layout,
            testVerification(&mock, 2),
            &scratch,
        )).?;
        try t.expect(recovered.sequence == 1 or recovered.sequence == 2);
        const bytes = try readInstalled(crashed.interface(), layout, recovered, &scratch);
        if (recovered.sequence == 1) {
            try t.expectEqualSlices(u8, first.slice(), bytes);
        } else {
            try t.expectEqualSlices(u8, second.slice(), bytes);
        }
    }
    std.debug.print(
        "NIHOS_PACKAGE_INSTALL crash_cuts={d} old_or_new=1 partial=0 committed_payload_corruption=fail_closed\n",
        .{event_count},
    );
}

test "committed head payload corruption fails closed instead of rolling back" {
    const t = std.testing;
    const layout = Layout{ .max_package_bytes = test_max_package };
    var mock = MockTrust{};
    const first = makeTestPackage(1, 1, 1);
    const second = makeTestPackage(2, 2, 2);
    var scratch: [test_max_package]u8 = undefined;
    var storage = MemoryStorage{};
    _ = try install(storage.interface(), layout, first.slice(), testVerification(&mock, 1), &scratch);
    const updated = try install(storage.interface(), layout, second.slice(), testVerification(&mock, 2), &scratch);
    storage.durable[layout.packageOffset(updated.state.slot)] ^= 1;
    try t.expectError(error.ActivePackageInvalid, recover(
        storage.interface(),
        layout,
        testVerification(&mock, 2),
        &scratch,
    ));
}

test "sequence identity trust epoch and retry semantics fail closed" {
    const t = std.testing;
    const layout = Layout{ .max_package_bytes = test_max_package };
    var mock = MockTrust{};
    const first = makeTestPackage(3, 1, 1);
    const lower = makeTestPackage(2, 2, 2);
    const conflict = makeTestPackage(3, 2, 3);
    var scratch: [test_max_package]u8 = undefined;
    var storage = MemoryStorage{};
    const installed = try install(storage.interface(), layout, first.slice(), testVerification(&mock, 4), &scratch);
    try t.expectEqual(Disposition.already_installed, (try install(
        storage.interface(),
        layout,
        first.slice(),
        testVerification(&mock, 4),
        &scratch,
    )).disposition);
    try t.expectError(error.Rollback, install(
        storage.interface(),
        layout,
        lower.slice(),
        testVerification(&mock, 4),
        &scratch,
    ));
    try t.expectError(error.SequenceConflict, install(
        storage.interface(),
        layout,
        conflict.slice(),
        testVerification(&mock, 4),
        &scratch,
    ));
    try t.expectError(error.StaleTrustSnapshot, install(
        storage.interface(),
        layout,
        first.slice(),
        testVerification(&mock, 3),
        &scratch,
    ));
    try t.expectEqual(@as(u64, 3), installed.state.sequence);

    var other = first;
    other.bytes[36] ^= 1;
    try t.expectError(error.WrongIdentity, install(
        storage.interface(),
        layout,
        other.slice(),
        testVerification(&mock, 4),
        &scratch,
    ));
}
