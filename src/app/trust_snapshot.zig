//! Canonical root-authenticated key/revocation/rollback snapshot framing.
const std = @import("std");
const package = @import("app_package");

pub const magic = "NIHTRS01".*;
pub const format_version: u16 = 1;
pub const header_bytes: usize = 64;
pub const key_record_bytes: usize = 104;
pub const rollback_record_bytes: usize = 40;
pub const max_public_key_bytes: usize = 64;

const Offset = struct {
    const magic = 0;
    const format = 8;
    const header = 10;
    const algorithm = 12;
    const signature_bytes = 14;
    const total_bytes = 16;
    const body_bytes = 20;
    const epoch = 24;
    const key_count = 32;
    const rollback_count = 34;
    const root_key_id = 36;
    const root_key_end = 52;
    const authority = 52;
    const reserved = 53;
};

pub const Authority = enum(u8) { normal = 1, recovery = 2 };

pub const KeyRecord = struct {
    publisher_id: [16]u8,
    key_id: [16]u8,
    algorithm: u16,
    status: package.KeyStatus,
    public_key_bytes: u16,
    public_key: [max_public_key_bytes]u8,
};

pub const RollbackRecord = struct {
    publisher_id: [16]u8,
    module_id: [16]u8,
    minimum_sequence: u64,
};

pub const BuildInput = struct {
    algorithm: u16,
    signature_bytes: u16,
    epoch: u64,
    root_key_id: [16]u8,
    authority: Authority,
    keys: []const KeyRecord,
    rollback: []const RollbackRecord,
};

pub const Prepared = struct {
    snapshot: []u8,
    signed_bytes: []u8,
    signature: []u8,
};

pub const Limits = struct {
    max_snapshot_bytes: u32,
    max_signature_bytes: u16,
    max_keys: u16,
    max_rollback: u16,
};

pub const Snapshot = struct {
    algorithm: u16,
    epoch: u64,
    root_key_id: [16]u8,
    authority: Authority,
    key_count: u16,
    rollback_count: u16,
    signed_bytes: []const u8,
    signature: []const u8,
    body: []const u8,

    pub fn key(self: Snapshot, index: usize) KeyRecord {
        std.debug.assert(index < self.key_count);
        const offset = index * key_record_bytes;
        return decodeKey(self.body[offset..][0..key_record_bytes]);
    }

    pub fn rollback(self: Snapshot, index: usize) RollbackRecord {
        std.debug.assert(index < self.rollback_count);
        const base = @as(usize, self.key_count) * key_record_bytes;
        const offset = base + index * rollback_record_bytes;
        return decodeRollback(self.body[offset..][0..rollback_record_bytes]);
    }
};

pub const Error = error{
    OutputTooSmall,
    LengthOverflow,
    TooManyRecords,
    EmptySnapshot,
    ZeroEpoch,
    ZeroSignature,
    InvalidRecord,
    UnsortedRecord,
    TooShort,
    BadMagic,
    BadFormat,
    BadHeaderSize,
    ReservedNonzero,
    SnapshotTooLarge,
    SignatureTooLarge,
    LengthMismatch,
};

pub fn prepare(output: []u8, input: BuildInput) Error!Prepared {
    if (input.epoch == 0) return error.ZeroEpoch;
    if (input.signature_bytes == 0) return error.ZeroSignature;
    if (input.algorithm == 0 or !nonzero(&input.root_key_id)) return error.InvalidRecord;
    if (input.keys.len == 0) return error.EmptySnapshot;
    if (input.keys.len > std.math.maxInt(u16) or input.rollback.len > std.math.maxInt(u16))
        return error.TooManyRecords;
    try validateRecords(input.keys, input.rollback);
    const key_bytes = std.math.mul(usize, input.keys.len, key_record_bytes) catch
        return error.LengthOverflow;
    const rollback_bytes = std.math.mul(usize, input.rollback.len, rollback_record_bytes) catch
        return error.LengthOverflow;
    const body_length = std.math.add(usize, key_bytes, rollback_bytes) catch
        return error.LengthOverflow;
    const signed_length = std.math.add(usize, header_bytes, body_length) catch
        return error.LengthOverflow;
    const total = std.math.add(usize, signed_length, input.signature_bytes) catch
        return error.LengthOverflow;
    if (total > std.math.maxInt(u32)) return error.LengthOverflow;
    if (output.len < total) return error.OutputTooSmall;

    @memset(output[0..header_bytes], 0);
    @memcpy(output[Offset.magic..Offset.format], &magic);
    write16(output, Offset.format, format_version);
    write16(output, Offset.header, header_bytes);
    write16(output, Offset.algorithm, input.algorithm);
    write16(output, Offset.signature_bytes, input.signature_bytes);
    write32(output, Offset.total_bytes, total);
    write32(output, Offset.body_bytes, body_length);
    write64(output, Offset.epoch, input.epoch);
    write16(output, Offset.key_count, input.keys.len);
    write16(output, Offset.rollback_count, input.rollback.len);
    @memcpy(output[Offset.root_key_id..Offset.root_key_end], &input.root_key_id);
    output[Offset.authority] = @backingInt(input.authority);
    var cursor = header_bytes;
    for (input.keys) |record| {
        encodeKey(output[cursor..][0..key_record_bytes], record);
        cursor += key_record_bytes;
    }
    for (input.rollback) |record| {
        encodeRollback(output[cursor..][0..rollback_record_bytes], record);
        cursor += rollback_record_bytes;
    }
    @memset(output[signed_length..total], 0);
    return .{
        .snapshot = output[0..total],
        .signed_bytes = output[0..signed_length],
        .signature = output[signed_length..total],
    };
}

pub fn parse(bytes: []const u8, limits: Limits) Error!Snapshot {
    if (bytes.len < header_bytes) return error.TooShort;
    if (!std.mem.eql(u8, bytes[Offset.magic..Offset.format], &magic)) return error.BadMagic;
    if (read16(bytes, Offset.format) != format_version) return error.BadFormat;
    if (read16(bytes, Offset.header) != header_bytes) return error.BadHeaderSize;
    if (!allZero(bytes[Offset.reserved..header_bytes])) return error.ReservedNonzero;
    const total = read32(bytes, Offset.total_bytes);
    const body_length = read32(bytes, Offset.body_bytes);
    const signature_length = read16(bytes, Offset.signature_bytes);
    const key_count = read16(bytes, Offset.key_count);
    const rollback_count = read16(bytes, Offset.rollback_count);
    if (read64(bytes, Offset.epoch) == 0) return error.ZeroEpoch;
    if (signature_length == 0) return error.ZeroSignature;
    if (read16(bytes, Offset.algorithm) == 0 or
        !nonzero(bytes[Offset.root_key_id..Offset.root_key_end])) return error.InvalidRecord;
    const authority: Authority = switch (bytes[Offset.authority]) {
        1 => .normal,
        2 => .recovery,
        else => return error.InvalidRecord,
    };
    if (key_count == 0) return error.EmptySnapshot;
    if (total > limits.max_snapshot_bytes) return error.SnapshotTooLarge;
    if (signature_length > limits.max_signature_bytes) return error.SignatureTooLarge;
    if (key_count > limits.max_keys or rollback_count > limits.max_rollback)
        return error.TooManyRecords;
    const expected_body = @as(usize, key_count) * key_record_bytes +
        @as(usize, rollback_count) * rollback_record_bytes;
    const signed_length = header_bytes + expected_body;
    if (body_length != expected_body or total != signed_length + signature_length or bytes.len != total)
        return error.LengthMismatch;
    const body = bytes[header_bytes..signed_length];
    try validateBody(body, key_count, rollback_count);
    return .{
        .algorithm = read16(bytes, Offset.algorithm),
        .epoch = read64(bytes, Offset.epoch),
        .root_key_id = bytes[Offset.root_key_id..Offset.root_key_end].*,
        .authority = authority,
        .key_count = key_count,
        .rollback_count = rollback_count,
        .signed_bytes = bytes[0..signed_length],
        .signature = bytes[signed_length..],
        .body = body,
    };
}

fn validateRecords(keys: []const KeyRecord, rollback: []const RollbackRecord) Error!void {
    for (keys, 0..) |record, index| {
        if (!validKey(record)) return error.InvalidRecord;
        if (index != 0 and compareKey(keys[index - 1], record) != .lt) return error.UnsortedRecord;
    }
    for (rollback, 0..) |record, index| {
        if (!validRollback(record)) return error.InvalidRecord;
        if (index != 0 and compareRollback(rollback[index - 1], record) != .lt)
            return error.UnsortedRecord;
    }
}

fn validateBody(body: []const u8, key_count: u16, rollback_count: u16) Error!void {
    var previous_key: ?KeyRecord = null;
    for (0..key_count) |index| {
        const record = decodeKey(body[index * key_record_bytes ..][0..key_record_bytes]);
        if (!validKey(record)) return error.InvalidRecord;
        if (previous_key) |previous| if (compareKey(previous, record) != .lt)
            return error.UnsortedRecord;
        previous_key = record;
    }
    const base = @as(usize, key_count) * key_record_bytes;
    var previous_rollback: ?RollbackRecord = null;
    for (0..rollback_count) |index| {
        const record = decodeRollback(body[base + index * rollback_record_bytes ..][0..rollback_record_bytes]);
        if (!validRollback(record)) return error.InvalidRecord;
        if (previous_rollback) |previous| if (compareRollback(previous, record) != .lt)
            return error.UnsortedRecord;
        previous_rollback = record;
    }
}

fn validKey(record: KeyRecord) bool {
    if (!nonzero(&record.publisher_id) or !nonzero(&record.key_id) or record.algorithm == 0 or
        record.status == .unknown or record.public_key_bytes == 0 or
        record.public_key_bytes > max_public_key_bytes) return false;
    return allZero(record.public_key[record.public_key_bytes..]);
}
fn validRollback(record: RollbackRecord) bool {
    return nonzero(&record.publisher_id) and nonzero(&record.module_id) and record.minimum_sequence != 0;
}
fn compareKey(a: KeyRecord, b: KeyRecord) std.math.Order {
    const publisher = std.mem.order(u8, &a.publisher_id, &b.publisher_id);
    return if (publisher == .eq) std.mem.order(u8, &a.key_id, &b.key_id) else publisher;
}
fn compareRollback(a: RollbackRecord, b: RollbackRecord) std.math.Order {
    const publisher = std.mem.order(u8, &a.publisher_id, &b.publisher_id);
    return if (publisher == .eq) std.mem.order(u8, &a.module_id, &b.module_id) else publisher;
}

fn encodeKey(output: []u8, record: KeyRecord) void {
    @memset(output, 0);
    @memcpy(output[0..16], &record.publisher_id);
    @memcpy(output[16..32], &record.key_id);
    write16(output, 32, record.algorithm);
    output[34] = switch (record.status) {
        .trusted => 1,
        .revoked => 2,
        .unknown => 0,
    };
    write16(output, 36, record.public_key_bytes);
    @memcpy(output[40..104], &record.public_key);
}
fn decodeKey(input: []const u8) KeyRecord {
    const status: package.KeyStatus = switch (input[34]) {
        1 => .trusted,
        2 => .revoked,
        else => .unknown,
    };
    var result = KeyRecord{
        .publisher_id = input[0..16].*,
        .key_id = input[16..32].*,
        .algorithm = read16(input, 32),
        .status = status,
        .public_key_bytes = read16(input, 36),
        .public_key = input[40..104].*,
    };
    if (input[35] != 0 or read16(input, 38) != 0) result.status = .unknown;
    return result;
}
fn encodeRollback(output: []u8, record: RollbackRecord) void {
    @memcpy(output[0..16], &record.publisher_id);
    @memcpy(output[16..32], &record.module_id);
    write64(output, 32, record.minimum_sequence);
}
fn decodeRollback(input: []const u8) RollbackRecord {
    return .{ .publisher_id = input[0..16].*, .module_id = input[16..32].*, .minimum_sequence = read64(input, 32) };
}
fn nonzero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return true;
    return false;
}
fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}
fn read16(b: []const u8, o: usize) u16 {
    return @as(u16, b[o]) | (@as(u16, b[o + 1]) << 8);
}
fn read32(b: []const u8, o: usize) u32 {
    return @as(u32, b[o]) | (@as(u32, b[o + 1]) << 8) | (@as(u32, b[o + 2]) << 16) | (@as(u32, b[o + 3]) << 24);
}
fn read64(b: []const u8, o: usize) u64 {
    return @as(u64, read32(b, o)) | (@as(u64, read32(b, o + 4)) << 32);
}
fn write16(b: []u8, o: usize, v: anytype) void {
    const x: u16 = @intCast(v);
    b[o] = @truncate(x);
    b[o + 1] = @truncate(x >> 8);
}
fn write32(b: []u8, o: usize, v: anytype) void {
    const x: u32 = @intCast(v);
    b[o] = @truncate(x);
    b[o + 1] = @truncate(x >> 8);
    b[o + 2] = @truncate(x >> 16);
    b[o + 3] = @truncate(x >> 24);
}
fn write64(b: []u8, o: usize, v: u64) void {
    write32(b, o, @as(u32, @truncate(v)));
    write32(b, o + 4, @as(u32, @truncate(v >> 32)));
}

test "canonical trust snapshot rejects ambiguity" {
    const t = std.testing;
    var key_bytes: [max_public_key_bytes]u8 = @splat(0);
    @memset(key_bytes[0..32], 1);
    var keys = [_]KeyRecord{.{
        .publisher_id = "nihos.dev/system".*,
        .key_id = "publisher-key-01".*,
        .algorithm = 1,
        .status = .trusted,
        .public_key_bytes = 32,
        .public_key = key_bytes,
    }};
    const rollback = [_]RollbackRecord{.{
        .publisher_id = "nihos.dev/system".*,
        .module_id = "nihos-rust-wasm1".*,
        .minimum_sequence = 7,
    }};
    var bytes: [512]u8 = undefined;
    const prepared = try prepare(&bytes, .{
        .algorithm = 1,
        .signature_bytes = 64,
        .epoch = 3,
        .root_key_id = "root-test-key-01".*,
        .authority = .normal,
        .keys = &keys,
        .rollback = &rollback,
    });
    @memset(prepared.signature, 0xa5);
    const parsed = try parse(prepared.snapshot, .{
        .max_snapshot_bytes = bytes.len,
        .max_signature_bytes = 64,
        .max_keys = 4,
        .max_rollback = 4,
    });
    try t.expectEqual(@as(u64, 3), parsed.epoch);
    try t.expectEqual(Authority.normal, parsed.authority);
    try t.expectEqual(package.KeyStatus.trusted, parsed.key(0).status);
    try t.expectEqual(@as(u64, 7), parsed.rollback(0).minimum_sequence);
    prepared.snapshot[Offset.authority] = 0;
    try t.expectError(error.InvalidRecord, parse(prepared.snapshot, .{
        .max_snapshot_bytes = bytes.len,
        .max_signature_bytes = 64,
        .max_keys = 4,
        .max_rollback = 4,
    }));
    prepared.snapshot[Offset.authority] = @backingInt(Authority.normal);
    var cut: usize = 0;
    while (cut < prepared.snapshot.len) : (cut += 1) {
        if (cut < header_bytes) {
            try t.expectError(error.TooShort, parse(prepared.snapshot[0..cut], .{
                .max_snapshot_bytes = bytes.len,
                .max_signature_bytes = 64,
                .max_keys = 4,
                .max_rollback = 4,
            }));
        } else {
            try t.expectError(error.LengthMismatch, parse(prepared.snapshot[0..cut], .{
                .max_snapshot_bytes = bytes.len,
                .max_signature_bytes = 64,
                .max_keys = 4,
                .max_rollback = 4,
            }));
        }
    }
    keys[0].status = .unknown;
    try t.expectError(error.InvalidRecord, prepare(&bytes, .{
        .algorithm = 1,
        .signature_bytes = 64,
        .epoch = 3,
        .root_key_id = "root-test-key-01".*,
        .authority = .normal,
        .keys = &keys,
        .rollback = &rollback,
    }));
    keys[0].status = .trusted;
    var duplicates = [_]KeyRecord{ keys[0], keys[0] };
    try t.expectError(error.UnsortedRecord, prepare(&bytes, .{
        .algorithm = 1,
        .signature_bytes = 64,
        .epoch = 3,
        .root_key_id = "root-test-key-01".*,
        .authority = .normal,
        .keys = &duplicates,
        .rollback = &rollback,
    }));
    duplicates[1].key_id[15] += 1;
    duplicates[0].public_key[63] = 1;
    try t.expectError(error.InvalidRecord, prepare(&bytes, .{
        .algorithm = 1,
        .signature_bytes = 64,
        .epoch = 3,
        .root_key_id = "root-test-key-01".*,
        .authority = .normal,
        .keys = &duplicates,
        .rollback = &rollback,
    }));
    try t.expectError(error.InvalidRecord, prepare(&bytes, .{
        .algorithm = 1,
        .signature_bytes = 64,
        .epoch = 3,
        .root_key_id = @splat(0),
        .authority = .normal,
        .keys = keys[0..1],
        .rollback = &rollback,
    }));
}
