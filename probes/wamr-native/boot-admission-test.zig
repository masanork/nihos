const std = @import("std");
const app_boot = @import("app_boot");
const install = @import("app_install");
const package = @import("app_package");
const package_ed25519 = @import("package_ed25519");
const policy = @import("app_policy");
const snapshot = @import("trust_snapshot");
const snapshot_ed25519 = @import("trust_snapshot_ed25519");
const snapshot_store = @import("trust_snapshot_store");

const Ed25519 = std.crypto.sign.Ed25519;
const max_snapshot = 512;
const max_package = 512;
const trust_layout = snapshot_store.Layout{ .max_snapshot_bytes = max_snapshot };
const package_layout = install.Layout{ .max_package_bytes = max_package };
const trust_storage_bytes = 2 * (max_snapshot + snapshot_store.record_bytes);
const package_storage_bytes = 2 * (max_package + install.record_bytes);
const publisher_id = "nihos.dev/system".*;
const module_id = "nihos-rust-wasm1".*;
const app_key_id = "rfc8032-vector01".*;
const normal_root_id = "root-test-key-01".*;
const recovery_root_id = "recovery-root-01".*;

const Memory = struct {
    data: [package_storage_bytes]u8 = @splat(0xff),
    bytes: usize,
    pause_once: std.atomic.Value(bool) = .init(false),
    entered: std.atomic.Value(bool) = .init(false),
    proceed: std.atomic.Value(bool) = .init(false),

    fn trust(self: *Memory) snapshot_store.Storage {
        return .{ .context = self, .bytes = self.bytes, .readAt = readAt, .writeAt = writeAt, .sync = sync };
    }

    fn packages(self: *Memory) install.Storage {
        return .{ .context = self, .bytes = self.bytes, .readAt = readAt, .writeAt = writeAt, .sync = sync };
    }

    fn readAt(context: *anyopaque, offset: usize, output: []u8) snapshot_store.IoError!void {
        const self: *Memory = @ptrCast(@alignCast(context));
        if (self.pause_once.swap(false, .acq_rel)) {
            self.entered.store(true, .release);
            while (!self.proceed.load(.acquire)) std.atomic.spinLoopHint();
        }
        const end = std.math.add(usize, offset, output.len) catch return error.Io;
        if (end > self.bytes) return error.Io;
        @memcpy(output, self.data[offset..end]);
    }

    fn writeAt(context: *anyopaque, offset: usize, input: []const u8) snapshot_store.IoError!void {
        const self: *Memory = @ptrCast(@alignCast(context));
        const end = std.math.add(usize, offset, input.len) catch return error.Io;
        if (end > self.bytes) return error.Io;
        @memcpy(self.data[offset..end], input);
    }

    fn sync(_: *anyopaque) snapshot_store.IoError!void {}
};

const Counter = struct {
    floor: u64 = 0,

    fn interface(self: *Counter) snapshot_store.Monotonic {
        return .{ .context = self, .read = read, .advance = advance };
    }

    fn read(context: *anyopaque) snapshot_store.IoError!u64 {
        const self: *Counter = @ptrCast(@alignCast(context));
        return self.floor;
    }

    fn advance(context: *anyopaque, epoch: u64) snapshot_store.IoError!void {
        const self: *Counter = @ptrCast(@alignCast(context));
        if (epoch < self.floor) return error.Io;
        self.floor = epoch;
    }
};

const BuiltSnapshot = struct {
    bytes: [max_snapshot]u8 = undefined,
    length: usize = 0,

    fn slice(self: *const BuiltSnapshot) []const u8 {
        return self.bytes[0..self.length];
    }
};

const BuiltPackage = struct {
    bytes: [max_package]u8 = undefined,
    length: usize = 0,

    fn slice(self: *const BuiltPackage) []const u8 {
        return self.bytes[0..self.length];
    }
};

const WorkBuffers = struct {
    snapshot_bytes: [max_snapshot]u8 = undefined,
    package_bytes: [max_package]u8 = undefined,
    keys: [8]package_ed25519.KeyRecord = undefined,
    rollback: [8]package_ed25519.RollbackRecord = undefined,

    fn workspace(self: *WorkBuffers) app_boot.Workspace {
        return .{
            .snapshot_bytes = &self.snapshot_bytes,
            .package_bytes = &self.package_bytes,
            .package_keys = &self.keys,
            .rollback = &self.rollback,
        };
    }
};

fn padded(key: [32]u8) [snapshot.max_public_key_bytes]u8 {
    var result: [snapshot.max_public_key_bytes]u8 = @splat(0);
    @memcpy(result[0..key.len], &key);
    return result;
}

fn buildSnapshot(
    epoch: u64,
    authority: snapshot.Authority,
    root_id: [16]u8,
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

fn buildPackage(sequence: u64, app_pair: Ed25519.KeyPair) !BuiltPackage {
    const wasm = [_]u8{ 0x00, 0x61, 0x73, 0x6d, @truncate(sequence) };
    var result = BuiltPackage{};
    const prepared = try package.prepare(&result.bytes, .{
        .algorithm = package_ed25519.algorithm_id,
        .signature_bytes = Ed25519.Signature.encoded_length,
        .sequence = sequence,
        .schema = policy.current_schema,
        .sdk_abi = policy.current_sdk_abi,
        .module_id = module_id,
        .publisher_id = publisher_id,
        .version = @intCast(sequence),
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

fn appLimits() policy.Limits {
    return .{
        .granted_services = policy.Service.graphics,
        .max_linear_pages = 1,
        .max_instruction_budget = 10_000,
        .max_wasm_bytes = max_package,
    };
}

fn inputs(
    trust_memory: *Memory,
    counter: *Counter,
    roots: *snapshot_ed25519.RootStore,
    package_memory: *Memory,
) app_boot.Inputs {
    return .{
        .trust_storage = trust_memory.trust(),
        .monotonic = counter.interface(),
        .trust_layout = trust_layout,
        .roots = roots,
        .package_storage = package_memory.packages(),
        .package_layout = package_layout,
        .max_signature_bytes = Ed25519.Signature.encoded_length,
        .limits = appLimits(),
    };
}

fn provisionTrust(
    memory: *Memory,
    counter: *Counter,
    roots: *snapshot_ed25519.RootStore,
    bytes: []const u8,
) !void {
    var scratch: [max_snapshot]u8 = undefined;
    _ = try snapshot_store.update(
        memory.trust(),
        counter.interface(),
        try roots.authenticator(),
        trust_layout,
        bytes,
        &scratch,
    );
}

fn installFixture(
    memory: *Memory,
    roots: *snapshot_ed25519.RootStore,
    snapshot_bytes: []const u8,
    app: []const u8,
    recorded_trust_epoch: u64,
) !void {
    const parsed = roots.verify(snapshot_bytes) orelse return error.InvalidSnapshot;
    var keys: [8]package_ed25519.KeyRecord = undefined;
    var rollback: [8]package_ed25519.RollbackRecord = undefined;
    var trust = try snapshot_ed25519.decodePackageStore(parsed, &keys, &rollback);
    var scratch: [max_package]u8 = undefined;
    _ = try install.install(memory.packages(), package_layout, app, .{
        .trust_epoch = recorded_trust_epoch,
        .max_signature_bytes = Ed25519.Signature.encoded_length,
        .trust = try trust.trustProvider(),
        .limits = appLimits(),
    }, &scratch);
}

test "boot admission composes sealed trust and package recovery" {
    const t = std.testing;
    var app_seed: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(
        &app_seed,
        "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60",
    );
    const app_pair = try Ed25519.KeyPair.generateDeterministic(app_seed);
    const normal_pair = try Ed25519.KeyPair.generateDeterministic(@splat(0x31));
    var root_records = [_]snapshot_ed25519.RootRecord{.{
        .root_key_id = normal_root_id,
        .public_key = normal_pair.public_key.toBytes(),
        .status = .trusted,
        .role = .normal,
    }};
    var roots = snapshot_ed25519.RootStore{ .roots = &root_records, .limits = rootLimits() };
    const epoch_1 = try buildSnapshot(
        1,
        .normal,
        normal_root_id,
        normal_pair,
        app_pair.public_key.toBytes(),
        .trusted,
        1,
    );
    const app = try buildPackage(1, app_pair);
    const app_2 = try buildPackage(2, app_pair);
    var trust_memory = Memory{ .bytes = trust_storage_bytes };
    var package_memory = Memory{ .bytes = package_storage_bytes };
    var counter = Counter{};
    try provisionTrust(&trust_memory, &counter, &roots, epoch_1.slice());
    try installFixture(&package_memory, &roots, epoch_1.slice(), app.slice(), 1);

    var coordinator = app_boot.Coordinator{};
    var work = WorkBuffers{};
    const ready = switch (try coordinator.recover(
        inputs(&trust_memory, &counter, &roots, &package_memory),
        work.workspace(),
    )) {
        .ready => |value| value,
        else => return error.ExpectedReady,
    };
    try t.expectEqual(@as(u64, 1), ready.trust_epoch);
    try t.expectEqual(@as(u64, 1), ready.installed.sequence);
    try t.expectEqualSlices(u8, app.slice(), ready.package_bytes);

    const ready_again = switch (try coordinator.recover(
        inputs(&trust_memory, &counter, &roots, &package_memory),
        work.workspace(),
    )) {
        .ready => |value| value,
        else => return error.ExpectedReady,
    };
    try t.expectEqualSlices(u8, app.slice(), ready_again.package_bytes);

    const installed = try coordinator.installPackage(
        inputs(&trust_memory, &counter, &roots, &package_memory),
        work.workspace(),
        app_2.slice(),
    );
    try t.expectEqual(install.Disposition.installed, installed.disposition);
    try t.expectEqual(@as(u64, 2), installed.ready.installed.sequence);
    try t.expectEqualSlices(u8, app_2.slice(), installed.ready.package_bytes);

    var rebooted = app_boot.Coordinator{};
    const after_reboot = switch (try rebooted.recover(
        inputs(&trust_memory, &counter, &roots, &package_memory),
        work.workspace(),
    )) {
        .ready => |value| value,
        else => return error.ExpectedReady,
    };
    try t.expectEqual(@as(u64, 2), after_reboot.installed.sequence);
    try t.expectEqualSlices(u8, app_2.slice(), after_reboot.package_bytes);

    const epoch_2 = try buildSnapshot(
        2,
        .normal,
        normal_root_id,
        normal_pair,
        app_pair.public_key.toBytes(),
        .revoked,
        2,
    );
    try provisionTrust(&trust_memory, &counter, &roots, epoch_2.slice());
    try t.expectError(error.ActivePackageRejected, coordinator.recover(
        inputs(&trust_memory, &counter, &roots, &package_memory),
        work.workspace(),
    ));
    try t.expectError(error.ActivePackageRejected, coordinator.recover(
        inputs(&trust_memory, &counter, &roots, &package_memory),
        work.workspace(),
    ));
    std.debug.print(
        "NIHOS_BOOT_ADMISSION ready=1 idempotent=1 install_sequence2=1 simulated_reboot=1 revocation=1 gate_released_after_error=1\n",
        .{},
    );
}

test "boot admission exposes explicit empty maintenance and future-trust states" {
    const t = std.testing;
    const app_pair = try Ed25519.KeyPair.generateDeterministic(@splat(0x21));
    const normal_pair = try Ed25519.KeyPair.generateDeterministic(@splat(0x31));
    const recovery_pair = try Ed25519.KeyPair.generateDeterministic(@splat(0x41));
    var root_records = [_]snapshot_ed25519.RootRecord{
        .{ .root_key_id = normal_root_id, .public_key = normal_pair.public_key.toBytes(), .status = .trusted, .role = .normal },
        .{ .root_key_id = recovery_root_id, .public_key = recovery_pair.public_key.toBytes(), .status = .trusted, .role = .recovery },
    };
    var roots = snapshot_ed25519.RootStore{ .roots = &root_records, .limits = rootLimits() };
    const normal = try buildSnapshot(
        1,
        .normal,
        normal_root_id,
        normal_pair,
        app_pair.public_key.toBytes(),
        .trusted,
        1,
    );
    const recovery = try buildSnapshot(
        2,
        .recovery,
        recovery_root_id,
        recovery_pair,
        app_pair.public_key.toBytes(),
        .trusted,
        1,
    );
    var trust_memory = Memory{ .bytes = trust_storage_bytes };
    var package_memory = Memory{ .bytes = package_storage_bytes };
    var counter = Counter{};
    var coordinator = app_boot.Coordinator{};
    var work = WorkBuffers{};
    switch (try coordinator.recover(
        inputs(&trust_memory, &counter, &roots, &package_memory),
        work.workspace(),
    )) {
        .unprovisioned => {},
        else => return error.ExpectedUnprovisioned,
    }
    const app = try buildPackage(1, app_pair);
    try t.expectError(error.TrustNotProvisioned, coordinator.installPackage(
        inputs(&trust_memory, &counter, &roots, &package_memory),
        work.workspace(),
        app.slice(),
    ));
    try provisionTrust(&trust_memory, &counter, &roots, normal.slice());
    switch (try coordinator.recover(
        inputs(&trust_memory, &counter, &roots, &package_memory),
        work.workspace(),
    )) {
        .no_package => |epoch| try t.expectEqual(@as(u64, 1), epoch),
        else => return error.ExpectedNoPackage,
    }

    const WorkerContext = struct {
        coordinator: *app_boot.Coordinator,
        inputs_value: app_boot.Inputs,
        workspace_value: app_boot.Workspace,
        passed: std.atomic.Value(bool) = .init(false),

        fn run(self: *@This()) void {
            const result = self.coordinator.recover(
                self.inputs_value,
                self.workspace_value,
            ) catch return;
            if (result == .no_package) self.passed.store(true, .release);
        }
    };
    var thread_work = WorkBuffers{};
    var thread_context = WorkerContext{
        .coordinator = &coordinator,
        .inputs_value = inputs(&trust_memory, &counter, &roots, &package_memory),
        .workspace_value = thread_work.workspace(),
    };
    trust_memory.proceed.store(false, .release);
    trust_memory.entered.store(false, .release);
    trust_memory.pause_once.store(true, .release);
    const thread = try std.Thread.spawn(.{}, WorkerContext.run, .{&thread_context});
    var observed = false;
    for (0..1_000_000) |_| {
        if (trust_memory.entered.load(.acquire)) {
            observed = true;
            break;
        }
        std.atomic.spinLoopHint();
    }
    try t.expect(observed);
    try t.expectError(error.Busy, coordinator.recover(
        inputs(&trust_memory, &counter, &roots, &package_memory),
        work.workspace(),
    ));
    trust_memory.proceed.store(true, .release);
    thread.join();
    try t.expect(thread_context.passed.load(.acquire));

    try provisionTrust(&trust_memory, &counter, &roots, recovery.slice());
    switch (try coordinator.recover(
        inputs(&trust_memory, &counter, &roots, &package_memory),
        work.workspace(),
    )) {
        .recovery_maintenance => |epoch| try t.expectEqual(@as(u64, 2), epoch),
        else => return error.ExpectedRecoveryMaintenance,
    }
    try t.expectError(error.RecoveryAuthorityActive, coordinator.installPackage(
        inputs(&trust_memory, &counter, &roots, &package_memory),
        work.workspace(),
        app.slice(),
    ));

    var future_trust_memory = Memory{ .bytes = trust_storage_bytes };
    var future_package_memory = Memory{ .bytes = package_storage_bytes };
    var future_counter = Counter{};
    try provisionTrust(&future_trust_memory, &future_counter, &roots, normal.slice());
    try installFixture(&future_package_memory, &roots, normal.slice(), app.slice(), 2);
    try t.expectError(error.TrustSnapshotTooOld, coordinator.recover(
        inputs(&future_trust_memory, &future_counter, &roots, &future_package_memory),
        work.workspace(),
    ));
    std.debug.print(
        "NIHOS_BOOT_STATES unprovisioned=1 install_without_trust_rejected=1 no_package=1 owner_busy=1 recovery_maintenance=1 recovery_install_rejected=1 future_trust_rejected=1\n",
        .{},
    );
}
