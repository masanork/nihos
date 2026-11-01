//! Experimental Ed25519 trust-provider adapter for canonical nihos packages.
//! Public keys and rollback snapshots are borrowed; persistence and mutation
//! belong to a future installer/key service.
const std = @import("std");
const package = @import("app_package");

pub const algorithm_id: u16 = 1;
const Ed25519 = std.crypto.sign.Ed25519;

pub const KeyRecord = struct {
    publisher_id: [16]u8,
    key_id: [16]u8,
    public_key: [Ed25519.PublicKey.encoded_length]u8,
    status: package.KeyStatus,
};

pub const RollbackRecord = struct {
    publisher_id: [16]u8,
    module_id: [16]u8,
    minimum_sequence: u64,
};

pub const Store = struct {
    keys: []const KeyRecord,
    rollback: []const RollbackRecord,

    pub const SnapshotError = error{
        DuplicateKey,
        DuplicateRollback,
        UnknownKeyRecord,
        ZeroMinimumSequence,
    };

    pub fn trustProvider(self: *Store) SnapshotError!package.TrustProvider {
        try self.validate();
        return .{
            .context = self,
            .keyStatus = keyStatus,
            .minimumSequence = minimumSequence,
            .verifySignature = verifySignature,
        };
    }

    fn validate(self: Store) SnapshotError!void {
        for (self.keys, 0..) |record, index| {
            if (record.status == .unknown) return error.UnknownKeyRecord;
            for (self.keys[index + 1 ..]) |other| {
                if (std.mem.eql(u8, &record.publisher_id, &other.publisher_id) and
                    std.mem.eql(u8, &record.key_id, &other.key_id)) return error.DuplicateKey;
            }
        }
        for (self.rollback, 0..) |record, index| {
            if (record.minimum_sequence == 0) return error.ZeroMinimumSequence;
            for (self.rollback[index + 1 ..]) |other| {
                if (std.mem.eql(u8, &record.publisher_id, &other.publisher_id) and
                    std.mem.eql(u8, &record.module_id, &other.module_id))
                    return error.DuplicateRollback;
            }
        }
    }

    fn findKey(self: Store, publisher_id: [16]u8, key_id: [16]u8) ?KeyRecord {
        for (self.keys) |record| {
            if (std.mem.eql(u8, &record.publisher_id, &publisher_id) and
                std.mem.eql(u8, &record.key_id, &key_id)) return record;
        }
        return null;
    }
};

pub fn verifyDetached(
    public_key_bytes: [Ed25519.PublicKey.encoded_length]u8,
    message: []const u8,
    signature_bytes: []const u8,
) bool {
    if (signature_bytes.len != Ed25519.Signature.encoded_length) return false;
    const public_key = Ed25519.PublicKey.fromBytes(public_key_bytes) catch return false;
    const signature = Ed25519.Signature.fromBytes(
        signature_bytes[0..Ed25519.Signature.encoded_length].*,
    );
    signature.verifyStrict(message, public_key) catch return false;
    return true;
}

fn keyStatus(context: *anyopaque, publisher_id: [16]u8, key_id: [16]u8) package.KeyStatus {
    const store: *Store = @ptrCast(@alignCast(context));
    const record = store.findKey(publisher_id, key_id) orelse return .unknown;
    return record.status;
}

fn minimumSequence(
    context: *anyopaque,
    publisher_id: [16]u8,
    module_id: [16]u8,
) u64 {
    const store: *Store = @ptrCast(@alignCast(context));
    for (store.rollback) |record| {
        if (std.mem.eql(u8, &record.publisher_id, &publisher_id) and
            std.mem.eql(u8, &record.module_id, &module_id)) return record.minimum_sequence;
    }
    return 1;
}

fn verifySignature(
    context: *anyopaque,
    algorithm: u16,
    publisher_id: [16]u8,
    key_id: [16]u8,
    message: []const u8,
    signature: []const u8,
) package.SignatureStatus {
    if (algorithm != algorithm_id) return .unsupported_algorithm;
    const store: *Store = @ptrCast(@alignCast(context));
    const record = store.findKey(publisher_id, key_id) orelse return .invalid;
    if (record.status != .trusted) return .invalid;
    return if (verifyDetached(record.public_key, message, signature)) .verified else .invalid;
}

test "RFC 8032 Ed25519 test vector 1 verifies strictly" {
    const t = std.testing;
    var public_key: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(
        &public_key,
        "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a",
    );
    var signature: [64]u8 = undefined;
    _ = try std.fmt.hexToBytes(
        &signature,
        "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e06522490155" ++
            "5fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b",
    );
    try t.expect(verifyDetached(public_key, "", &signature));
    signature[0] ^= 1;
    try t.expect(!verifyDetached(public_key, "", &signature));
    try t.expect(!verifyDetached(public_key, "x", &signature));
}

test "trust snapshots reject ambiguous and invalid records" {
    const t = std.testing;
    const publisher = "nihos.dev/system".*;
    const key = "rfc8032-vector01".*;
    const module = "nihos-rust-wasm1".*;
    const base_key = KeyRecord{
        .publisher_id = publisher,
        .key_id = key,
        .public_key = @splat(1),
        .status = .trusted,
    };
    var keys = [_]KeyRecord{ base_key, base_key };
    var store = Store{ .keys = &keys, .rollback = &.{} };
    try t.expectError(error.DuplicateKey, store.trustProvider());
    keys[1].key_id[0] ^= 1;
    keys[0].status = .unknown;
    try t.expectError(error.UnknownKeyRecord, store.trustProvider());

    keys[0].status = .trusted;
    var rollback = [_]RollbackRecord{
        .{ .publisher_id = publisher, .module_id = module, .minimum_sequence = 1 },
        .{ .publisher_id = publisher, .module_id = module, .minimum_sequence = 1 },
    };
    store.rollback = &rollback;
    try t.expectError(error.DuplicateRollback, store.trustProvider());
    rollback[1].module_id[0] ^= 1;
    rollback[0].minimum_sequence = 0;
    try t.expectError(error.ZeroMinimumSequence, store.trustProvider());
}
