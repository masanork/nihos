//! Experimental Ed25519 root adapter for canonical trust snapshots.
//! Test roots are public fixtures; production provisioning remains external.
const std = @import("std");
const package = @import("app_package");
const package_ed25519 = @import("package_ed25519");
const snapshot_format = @import("trust_snapshot");
const snapshot_store = @import("trust_snapshot_store");

pub const algorithm_id: u16 = package_ed25519.algorithm_id;
const Ed25519 = std.crypto.sign.Ed25519;

pub const RootStatus = enum { trusted, revoked };
pub const RootRole = enum { normal, recovery };
pub const RootRecord = struct {
    root_key_id: [16]u8,
    public_key: [Ed25519.PublicKey.encoded_length]u8,
    status: RootStatus,
    role: RootRole,
};

pub const RootStore = struct {
    roots: []const RootRecord,
    limits: snapshot_format.Limits,

    pub const Error = error{ DuplicateRoot, InvalidRootId };

    pub fn authenticator(self: *RootStore) Error!snapshot_store.Authenticator {
        try self.validate();
        return .{ .context = self, .authenticate = authenticate };
    }

    pub fn normalAuthenticator(self: *RootStore) Error!snapshot_store.Authenticator {
        try self.validate();
        return .{ .context = self, .authenticate = authenticateNormal };
    }

    pub fn recoveryAuthenticator(self: *RootStore) Error!snapshot_store.RecoveryAuthenticator {
        try self.validate();
        return .{ .context = self, .authenticate = authenticateRecovery };
    }

    fn validate(self: *RootStore) Error!void {
        for (self.roots, 0..) |root, index| {
            var nonzero = false;
            for (root.root_key_id) |byte| nonzero = nonzero or byte != 0;
            if (!nonzero) return error.InvalidRootId;
            for (self.roots[index + 1 ..]) |other| {
                if (std.mem.eql(u8, &root.root_key_id, &other.root_key_id))
                    return error.DuplicateRoot;
            }
        }
    }

    pub fn verify(self: *RootStore, bytes: []const u8) ?snapshot_format.Snapshot {
        const parsed = snapshot_format.parse(bytes, self.limits) catch return null;
        if (parsed.algorithm != algorithm_id) return null;
        const root = self.find(parsed.root_key_id) orelse return null;
        if (root.status != .trusted) return null;
        const expected_role: RootRole = switch (parsed.authority) {
            .normal => .normal,
            .recovery => .recovery,
        };
        if (root.role != expected_role) return null;
        if (!package_ed25519.verifyDetached(root.public_key, parsed.signed_bytes, parsed.signature))
            return null;
        return parsed;
    }

    fn find(self: RootStore, root_key_id: [16]u8) ?RootRecord {
        for (self.roots) |root| {
            if (std.mem.eql(u8, &root.root_key_id, &root_key_id)) return root;
        }
        return null;
    }
};

fn authenticate(context: *anyopaque, bytes: []const u8) ?u64 {
    const roots: *RootStore = @ptrCast(@alignCast(context));
    return (roots.verify(bytes) orelse return null).epoch;
}

fn authenticateNormal(context: *anyopaque, bytes: []const u8) ?u64 {
    const roots: *RootStore = @ptrCast(@alignCast(context));
    const parsed = roots.verify(bytes) orelse return null;
    return if (parsed.authority == .normal) parsed.epoch else null;
}

fn authenticateRecovery(context: *anyopaque, bytes: []const u8) ?u64 {
    const roots: *RootStore = @ptrCast(@alignCast(context));
    const parsed = roots.verify(bytes) orelse return null;
    return if (parsed.authority == .recovery) parsed.epoch else null;
}

pub const DecodeError = error{
    KeyOutputTooSmall,
    RollbackOutputTooSmall,
    UnsupportedKeyAlgorithm,
    InvalidKeySize,
};

pub fn decodePackageStore(
    parsed: snapshot_format.Snapshot,
    keys: []package_ed25519.KeyRecord,
    rollback: []package_ed25519.RollbackRecord,
) DecodeError!package_ed25519.Store {
    if (keys.len < parsed.key_count) return error.KeyOutputTooSmall;
    if (rollback.len < parsed.rollback_count) return error.RollbackOutputTooSmall;
    for (0..parsed.key_count) |index| {
        const source = parsed.key(index);
        if (source.algorithm != package_ed25519.algorithm_id)
            return error.UnsupportedKeyAlgorithm;
        if (source.public_key_bytes != Ed25519.PublicKey.encoded_length)
            return error.InvalidKeySize;
        keys[index] = .{
            .publisher_id = source.publisher_id,
            .key_id = source.key_id,
            .public_key = source.public_key[0..Ed25519.PublicKey.encoded_length].*,
            .status = source.status,
        };
    }
    for (0..parsed.rollback_count) |index| {
        const source = parsed.rollback(index);
        rollback[index] = .{
            .publisher_id = source.publisher_id,
            .module_id = source.module_id,
            .minimum_sequence = source.minimum_sequence,
        };
    }
    return .{
        .keys = keys[0..parsed.key_count],
        .rollback = rollback[0..parsed.rollback_count],
    };
}

fn paddedPublicKey(key: [32]u8) [snapshot_format.max_public_key_bytes]u8 {
    var result: [snapshot_format.max_public_key_bytes]u8 = @splat(0);
    @memcpy(result[0..key.len], &key);
    return result;
}

fn limits(max_bytes: u32) snapshot_format.Limits {
    return .{
        .max_snapshot_bytes = max_bytes,
        .max_signature_bytes = Ed25519.Signature.encoded_length,
        .max_keys = 8,
        .max_rollback = 8,
    };
}

test "root-signed snapshot creates package trust provider and supports overlap" {
    const t = std.testing;
    const publisher_id = "nihos.dev/system".*;
    const module_id = "nihos-rust-wasm1".*;
    const key_id = "rfc8032-vector01".*;
    const root_id_1 = "root-test-key-01".*;
    const root_id_2 = "root-test-key-02".*;

    var app_seed: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(
        &app_seed,
        "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60",
    );
    const app_pair = try Ed25519.KeyPair.generateDeterministic(app_seed);
    const root_pair_1 = try Ed25519.KeyPair.generateDeterministic(@splat(0x31));
    const root_pair_2 = try Ed25519.KeyPair.generateDeterministic(@splat(0x32));

    const keys = [_]snapshot_format.KeyRecord{.{
        .publisher_id = publisher_id,
        .key_id = key_id,
        .algorithm = package_ed25519.algorithm_id,
        .status = .trusted,
        .public_key_bytes = Ed25519.PublicKey.encoded_length,
        .public_key = paddedPublicKey(app_pair.public_key.toBytes()),
    }};
    const rollback = [_]snapshot_format.RollbackRecord{.{
        .publisher_id = publisher_id,
        .module_id = module_id,
        .minimum_sequence = 1,
    }};
    var snapshot_bytes: [512]u8 = undefined;
    const prepared = try snapshot_format.prepare(&snapshot_bytes, .{
        .algorithm = algorithm_id,
        .signature_bytes = Ed25519.Signature.encoded_length,
        .epoch = 7,
        .root_key_id = root_id_2,
        .authority = .normal,
        .keys = &keys,
        .rollback = &rollback,
    });
    const root_signature = try root_pair_2.sign(prepared.signed_bytes, null);
    @memcpy(prepared.signature, &root_signature.toBytes());

    var roots = [_]RootRecord{
        .{ .root_key_id = root_id_1, .public_key = root_pair_1.public_key.toBytes(), .status = .trusted, .role = .normal },
        .{ .root_key_id = root_id_2, .public_key = root_pair_2.public_key.toBytes(), .status = .trusted, .role = .normal },
    };
    var root_store = RootStore{ .roots = &roots, .limits = limits(snapshot_bytes.len) };
    const root_auth = try root_store.authenticator();
    try t.expectEqual(@as(?u64, 7), root_auth.authenticate(root_auth.context, prepared.snapshot));
    const parsed = root_store.verify(prepared.snapshot).?;

    var package_keys: [1]package_ed25519.KeyRecord = undefined;
    var package_rollback: [1]package_ed25519.RollbackRecord = undefined;
    var trust_store = try decodePackageStore(parsed, &package_keys, &package_rollback);
    const provider = try trust_store.trustProvider();

    const wasm = [_]u8{ 0x00, 0x61, 0x73, 0x6d };
    var package_bytes: [512]u8 = undefined;
    const app = try package.prepare(&package_bytes, .{
        .algorithm = package_ed25519.algorithm_id,
        .signature_bytes = Ed25519.Signature.encoded_length,
        .sequence = 1,
        .schema = 1,
        .sdk_abi = 1,
        .module_id = module_id,
        .publisher_id = publisher_id,
        .version = 1,
        .services = 1,
        .max_linear_pages = 1,
        .instruction_budget = 10_000,
        .key_id = key_id,
        .wasm = &wasm,
    });
    const app_signature = try app_pair.sign(app.signed_bytes, null);
    @memcpy(app.signature, &app_signature.toBytes());
    const envelope = try package.parse(app.package, .{
        .max_package_bytes = package_bytes.len,
        .max_signature_bytes = Ed25519.Signature.encoded_length,
    });
    const admitted = package.admit(envelope, provider, .{
        .granted_services = 1,
        .max_linear_pages = 1,
        .max_instruction_budget = 10_000,
        .max_wasm_bytes = package_bytes.len,
    });
    try t.expect(admitted.accepted());

    roots[1].role = .recovery;
    try t.expect(root_store.verify(prepared.snapshot) == null);
    var recovery_bytes: [512]u8 = undefined;
    const recovery = try snapshot_format.prepare(&recovery_bytes, .{
        .algorithm = algorithm_id,
        .signature_bytes = Ed25519.Signature.encoded_length,
        .epoch = 8,
        .root_key_id = root_id_2,
        .authority = .recovery,
        .keys = &keys,
        .rollback = &rollback,
    });
    const recovery_signature = try root_pair_2.sign(recovery.signed_bytes, null);
    @memcpy(recovery.signature, &recovery_signature.toBytes());
    try t.expectEqual(@as(u64, 8), root_store.verify(recovery.snapshot).?.epoch);
    roots[1].role = .normal;
    try t.expect(root_store.verify(recovery.snapshot) == null);

    roots[1].status = .revoked;
    try t.expect(root_store.verify(prepared.snapshot) == null);
    roots[1].status = .trusted;
    prepared.signature[0] ^= 1;
    try t.expect(root_store.verify(prepared.snapshot) == null);
    roots[1] = roots[0];
    try t.expectError(error.DuplicateRoot, root_store.authenticator());
    std.debug.print(
        "NIHOS_TRUST_ROOT epoch=7 roots=2 package_keys=1 rollback=1 package_admitted=1 authority_separated=1 recovery_epoch=8\n",
        .{},
    );
}
