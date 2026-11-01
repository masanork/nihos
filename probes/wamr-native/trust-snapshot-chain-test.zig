const std = @import("std");
const package = @import("app_package");
const package_ed25519 = @import("package_ed25519");
const policy = @import("app_policy");
const snapshot = @import("trust_snapshot");
const snapshot_ed25519 = @import("trust_snapshot_ed25519");
const snapshot_store = @import("trust_snapshot_store");

const Ed25519 = std.crypto.sign.Ed25519;
const max_snapshot = 512;
const storage_bytes = 2 * (max_snapshot + snapshot_store.record_bytes);
const publisher_id = "nihos.dev/system".*;
const module_id = "nihos-rust-wasm1".*;
const app_key_id = "rfc8032-vector01".*;
const root_id_1 = "root-test-key-01".*;
const root_id_2 = "root-test-key-02".*;
const recovery_root_id = "recovery-root-01".*;

const World = struct {
    data: [storage_bytes]u8 = @splat(0xff),
    floor: u64 = 0,
    events: usize = 0,
    fail_at: ?usize = null,

    fn storage(self: *World) snapshot_store.Storage {
        return .{ .context = self, .bytes = self.data.len, .readAt = readAt, .writeAt = writeAt, .sync = sync };
    }
    fn counter(self: *World) snapshot_store.Monotonic {
        return .{ .context = self, .read = readFloor, .advance = advance };
    }
    fn readAt(context: *anyopaque, offset: usize, output: []u8) snapshot_store.IoError!void {
        const self: *World = @ptrCast(@alignCast(context));
        const end = std.math.add(usize, offset, output.len) catch return error.Io;
        if (end > self.data.len) return error.Io;
        @memcpy(output, self.data[offset..end]);
    }
    fn writeAt(context: *anyopaque, offset: usize, input: []const u8) snapshot_store.IoError!void {
        const self: *World = @ptrCast(@alignCast(context));
        const end = std.math.add(usize, offset, input.len) catch return error.Io;
        if (end > self.data.len) return error.Io;
        for (input, 0..) |byte, index| {
            if (self.fail_at == self.events) return error.PowerLoss;
            self.data[offset + index] = byte;
            self.events += 1;
        }
    }
    fn sync(context: *anyopaque) snapshot_store.IoError!void {
        const self: *World = @ptrCast(@alignCast(context));
        if (self.fail_at == self.events) return error.PowerLoss;
        self.events += 1;
    }
    fn readFloor(context: *anyopaque) snapshot_store.IoError!u64 {
        const self: *World = @ptrCast(@alignCast(context));
        return self.floor;
    }
    fn advance(context: *anyopaque, epoch: u64) snapshot_store.IoError!void {
        const self: *World = @ptrCast(@alignCast(context));
        if (epoch < self.floor) return error.Io;
        if (self.fail_at == self.events) return error.PowerLoss;
        self.floor = epoch;
        self.events += 1;
    }
};

const BuiltPackage = struct {
    bytes: [512]u8 = undefined,
    length: usize = 0,
    fn slice(self: *const BuiltPackage) []const u8 {
        return self.bytes[0..self.length];
    }
};

const BuiltSnapshot = struct {
    bytes: [max_snapshot]u8 = undefined,
    length: usize = 0,
    fn slice(self: *const BuiltSnapshot) []const u8 {
        return self.bytes[0..self.length];
    }
};

fn padded(key: [32]u8) [snapshot.max_public_key_bytes]u8 {
    var result: [snapshot.max_public_key_bytes]u8 = @splat(0);
    @memcpy(result[0..key.len], &key);
    return result;
}

fn buildSnapshot(
    epoch: u64,
    root_id: [16]u8,
    authority: snapshot.Authority,
    root_pair: Ed25519.KeyPair,
    app_public_key: [32]u8,
    key_status: package.KeyStatus,
    minimum_sequence: u64,
) !BuiltSnapshot {
    const keys = [_]snapshot.KeyRecord{.{
        .publisher_id = publisher_id,
        .key_id = app_key_id,
        .algorithm = package_ed25519.algorithm_id,
        .status = key_status,
        .public_key_bytes = Ed25519.PublicKey.encoded_length,
        .public_key = padded(app_public_key),
    }};
    const rollback = [_]snapshot.RollbackRecord{.{
        .publisher_id = publisher_id,
        .module_id = module_id,
        .minimum_sequence = minimum_sequence,
    }};
    var result = BuiltSnapshot{};
    const prepared = try snapshot.prepare(&result.bytes, .{
        .algorithm = snapshot_ed25519.algorithm_id,
        .signature_bytes = Ed25519.Signature.encoded_length,
        .epoch = epoch,
        .root_key_id = root_id,
        .authority = authority,
        .keys = &keys,
        .rollback = &rollback,
    });
    const signature = try root_pair.sign(prepared.signed_bytes, null);
    @memcpy(prepared.signature, &signature.toBytes());
    result.length = prepared.snapshot.len;
    return result;
}

fn buildPackage(app_pair: Ed25519.KeyPair) !BuiltPackage {
    const wasm = [_]u8{ 0x00, 0x61, 0x73, 0x6d };
    var result = BuiltPackage{};
    const prepared = try package.prepare(&result.bytes, .{
        .algorithm = package_ed25519.algorithm_id,
        .signature_bytes = Ed25519.Signature.encoded_length,
        .sequence = 1,
        .schema = policy.current_schema,
        .sdk_abi = policy.current_sdk_abi,
        .module_id = module_id,
        .publisher_id = publisher_id,
        .version = 1,
        .services = policy.Service.graphics,
        .max_linear_pages = 1,
        .instruction_budget = 10_000,
        .key_id = app_key_id,
        .wasm = &wasm,
    });
    const signature = try app_pair.sign(prepared.signed_bytes, null);
    @memcpy(prepared.signature, &signature.toBytes());
    result.length = prepared.package.len;
    return result;
}

fn rootLimits() snapshot.Limits {
    return .{
        .max_snapshot_bytes = max_snapshot,
        .max_signature_bytes = Ed25519.Signature.encoded_length,
        .max_keys = 8,
        .max_rollback = 8,
    };
}

fn packageDecision(
    root_store: *snapshot_ed25519.RootStore,
    snapshot_bytes: []const u8,
    app: []const u8,
) !package.TrustDecision {
    const parsed_snapshot = root_store.verify(snapshot_bytes) orelse return error.InvalidSnapshot;
    var keys: [8]package_ed25519.KeyRecord = undefined;
    var rollback: [8]package_ed25519.RollbackRecord = undefined;
    var trust = try snapshot_ed25519.decodePackageStore(parsed_snapshot, &keys, &rollback);
    const provider = try trust.trustProvider();
    const envelope = try package.parse(app, .{
        .max_package_bytes = 512,
        .max_signature_bytes = Ed25519.Signature.encoded_length,
    });
    return package.admit(envelope, provider, .{
        .granted_services = policy.Service.graphics,
        .max_linear_pages = 1,
        .max_instruction_budget = 10_000,
        .max_wasm_bytes = 512,
    }).trust;
}

test "root rotation and package revocation survive every persistent cut" {
    const t = std.testing;
    var app_seed: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(
        &app_seed,
        "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60",
    );
    const app_pair = try Ed25519.KeyPair.generateDeterministic(app_seed);
    const root_pair_1 = try Ed25519.KeyPair.generateDeterministic(@splat(0x31));
    const root_pair_2 = try Ed25519.KeyPair.generateDeterministic(@splat(0x32));
    const epoch_1 = try buildSnapshot(1, root_id_1, .normal, root_pair_1, app_pair.public_key.toBytes(), .trusted, 1);
    const epoch_2 = try buildSnapshot(2, root_id_2, .normal, root_pair_2, app_pair.public_key.toBytes(), .revoked, 2);
    const app = try buildPackage(app_pair);
    try t.expectEqual(@as(usize, 272), epoch_1.length);
    try t.expectEqual(epoch_1.length, epoch_2.length);

    var roots = [_]snapshot_ed25519.RootRecord{
        .{ .root_key_id = root_id_1, .public_key = root_pair_1.public_key.toBytes(), .status = .trusted, .role = .normal },
        .{ .root_key_id = root_id_2, .public_key = root_pair_2.public_key.toBytes(), .status = .trusted, .role = .normal },
    };
    var root_store = snapshot_ed25519.RootStore{ .roots = &roots, .limits = rootLimits() };
    const authenticator = try root_store.authenticator();
    const layout = snapshot_store.Layout{ .max_snapshot_bytes = max_snapshot };
    var scratch: [max_snapshot]u8 = undefined;
    var base = World{};
    _ = try snapshot_store.update(
        base.storage(),
        base.counter(),
        authenticator,
        layout,
        epoch_1.slice(),
        &scratch,
    );
    try t.expectEqual(package.TrustDecision.accepted, try packageDecision(&root_store, epoch_1.slice(), app.slice()));

    var successful = base;
    successful.events = 0;
    _ = try snapshot_store.update(
        successful.storage(),
        successful.counter(),
        authenticator,
        layout,
        epoch_2.slice(),
        &scratch,
    );
    const event_count = successful.events;
    try t.expectEqual(@as(usize, 468), event_count);
    try t.expectEqual(@as(u64, 2), successful.floor);

    var cut: usize = 0;
    while (cut < event_count) : (cut += 1) {
        var crashed = base;
        crashed.events = 0;
        crashed.fail_at = cut;
        try t.expectError(error.PowerLoss, snapshot_store.update(
            crashed.storage(),
            crashed.counter(),
            authenticator,
            layout,
            epoch_2.slice(),
            &scratch,
        ));
        crashed.fail_at = null;
        const recovered = (try snapshot_store.recoverAndSeal(
            crashed.storage(),
            crashed.counter(),
            authenticator,
            layout,
            &scratch,
        )).?;
        const recovered_bytes = try snapshot_store.readSnapshot(crashed.storage(), layout, recovered, &scratch);
        const decision = try packageDecision(&root_store, recovered_bytes, app.slice());
        if (recovered.epoch == 1) {
            try t.expectEqual(package.TrustDecision.accepted, decision);
        } else {
            try t.expectEqual(@as(u64, 2), recovered.epoch);
            try t.expectEqual(package.TrustDecision.revoked_key, decision);
        }
        try t.expectEqual(recovered.epoch, crashed.floor);
    }

    var root_2_only = [_]snapshot_ed25519.RootRecord{roots[1]};
    var retired = snapshot_ed25519.RootStore{ .roots = &root_2_only, .limits = rootLimits() };
    const retired_auth = try retired.authenticator();
    const current = (try snapshot_store.recoverAndSeal(
        successful.storage(),
        successful.counter(),
        retired_auth,
        layout,
        &scratch,
    )).?;
    try t.expectEqual(@as(u64, 2), current.epoch);

    var restored = base;
    restored.floor = 2;
    try t.expectError(error.InvalidActiveSnapshot, snapshot_store.recoverAndSeal(
        restored.storage(),
        restored.counter(),
        retired_auth,
        layout,
        &scratch,
    ));

    const recovery_pair = try Ed25519.KeyPair.generateDeterministic(@splat(0x41));
    const emergency = try buildSnapshot(
        3,
        recovery_root_id,
        .recovery,
        recovery_pair,
        app_pair.public_key.toBytes(),
        .revoked,
        2,
    );
    var emergency_roots = [_]snapshot_ed25519.RootRecord{
        .{ .root_key_id = root_id_1, .public_key = root_pair_1.public_key.toBytes(), .status = .revoked, .role = .normal },
        .{ .root_key_id = root_id_2, .public_key = root_pair_2.public_key.toBytes(), .status = .trusted, .role = .normal },
        .{ .root_key_id = recovery_root_id, .public_key = recovery_pair.public_key.toBytes(), .status = .trusted, .role = .recovery },
    };
    var emergency_store = snapshot_ed25519.RootStore{ .roots = &emergency_roots, .limits = rootLimits() };
    const emergency_auth = try emergency_store.authenticator();
    const recovery_auth = try emergency_store.recoveryAuthenticator();
    const normal_auth = try emergency_store.normalAuthenticator();
    var blocked = base;
    try t.expectError(error.InvalidActiveSnapshot, snapshot_store.update(
        blocked.storage(),
        blocked.counter(),
        emergency_auth,
        layout,
        emergency.slice(),
        &scratch,
    ));

    var recovered_base = base;
    recovered_base.events = 0;
    _ = try snapshot_store.recoveryReplace(
        recovered_base.storage(),
        recovered_base.counter(),
        recovery_auth,
        layout,
        emergency.slice(),
        &scratch,
    );
    const recovery_events = recovered_base.events;
    try t.expectEqual(@as(usize, 468), recovery_events);
    try t.expectEqual(@as(u64, 3), recovered_base.floor);
    try t.expectEqual(snapshot_store.Disposition.already_current, (try snapshot_store.recoveryReplace(
        recovered_base.storage(),
        recovered_base.counter(),
        recovery_auth,
        layout,
        emergency.slice(),
        &scratch,
    )).disposition);
    var recovery_cut: usize = 0;
    while (recovery_cut < recovery_events) : (recovery_cut += 1) {
        var crashed = base;
        crashed.events = 0;
        crashed.fail_at = recovery_cut;
        try t.expectError(error.PowerLoss, snapshot_store.recoveryReplace(
            crashed.storage(),
            crashed.counter(),
            recovery_auth,
            layout,
            emergency.slice(),
            &scratch,
        ));
        crashed.fail_at = null;
        const retried = try snapshot_store.recoveryReplace(
            crashed.storage(),
            crashed.counter(),
            recovery_auth,
            layout,
            emergency.slice(),
            &scratch,
        );
        try t.expectEqual(@as(u64, 3), retried.state.epoch);
        try t.expectEqual(@as(u64, 3), crashed.floor);
        const bytes = try snapshot_store.readSnapshot(crashed.storage(), layout, retried.state, &scratch);
        try t.expectEqual(package.TrustDecision.revoked_key, try packageDecision(
            &emergency_store,
            bytes,
            app.slice(),
        ));
    }

    const normal_handoff = try buildSnapshot(
        4,
        root_id_2,
        .normal,
        root_pair_2,
        app_pair.public_key.toBytes(),
        .revoked,
        2,
    );
    var handed_off = recovered_base;
    handed_off.events = 0;
    _ = try snapshot_store.transition(
        handed_off.storage(),
        handed_off.counter(),
        emergency_auth,
        normal_auth,
        layout,
        normal_handoff.slice(),
        &scratch,
    );
    const handoff_events = handed_off.events;
    try t.expectEqual(@as(usize, 468), handoff_events);
    var handoff_cut: usize = 0;
    while (handoff_cut < handoff_events) : (handoff_cut += 1) {
        var crashed = recovered_base;
        crashed.events = 0;
        crashed.fail_at = handoff_cut;
        try t.expectError(error.PowerLoss, snapshot_store.transition(
            crashed.storage(),
            crashed.counter(),
            emergency_auth,
            normal_auth,
            layout,
            normal_handoff.slice(),
            &scratch,
        ));
        crashed.fail_at = null;
        const recovered = (try snapshot_store.recoverAndSeal(
            crashed.storage(),
            crashed.counter(),
            emergency_auth,
            layout,
            &scratch,
        )).?;
        try t.expect(recovered.epoch == 3 or recovered.epoch == 4);
        try t.expectEqual(recovered.epoch, crashed.floor);
    }

    var final_roots = [_]snapshot_ed25519.RootRecord{emergency_roots[1]};
    var final_store = snapshot_ed25519.RootStore{ .roots = &final_roots, .limits = rootLimits() };
    const final_auth = try final_store.normalAuthenticator();
    const final = (try snapshot_store.recoverAndSeal(
        handed_off.storage(),
        handed_off.counter(),
        final_auth,
        layout,
        &scratch,
    )).?;
    try t.expectEqual(@as(u64, 4), final.epoch);
    std.debug.print(
        "NIHOS_TRUST_CHAIN crash_cuts={d} recovery_cuts={d} handoff_cuts={d} roots_overlap=2 retired_root1=1 revoke_package_key=1 rollback_rejected=1 recovery_replace=1 normal_handoff=1\n",
        .{ event_count, recovery_events, handoff_events },
    );
}
