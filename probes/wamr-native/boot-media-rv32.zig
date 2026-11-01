//! Native emulator adapter from linked journal fixtures to mutable private media.
//! The media and root are deterministic fixtures, not production provisioning or
//! persistent Flash. A fresh coordinator models a restart after installation.
const std = @import("std");
const app_boot = @import("app_boot");
const install = @import("app_install");
const package = @import("app_package");
const package_ed25519 = @import("package_ed25519");
const policy = @import("app_policy");
const snapshot = @import("trust_snapshot");
const snapshot_ed25519 = @import("trust_snapshot_ed25519");
const snapshot_store = @import("trust_snapshot_store");

const max_snapshot = 512;
const max_package = 4096;
const trust_layout = snapshot_store.Layout{ .max_snapshot_bytes = max_snapshot };
const package_layout = install.Layout{ .max_package_bytes = max_package };

extern const _binary_boot_trust_bin_start: u8;
extern const _binary_boot_trust_bin_end: u8;
extern const _binary_boot_package_bin_start: u8;
extern const _binary_boot_package_bin_end: u8;
extern const _binary_boot_counter_bin_start: u8;
extern const _binary_boot_counter_bin_end: u8;
extern const _binary_boot_root_pub_start: u8;
extern const _binary_boot_root_pub_end: u8;
extern const _binary_boot_update_bin_start: u8;
extern const _binary_boot_update_bin_end: u8;

pub const BootReport = extern struct {
    trust_status: u32 = std.math.maxInt(u32),
    policy_status: u32 = std.math.maxInt(u32),
    wasm_offset: u32 = 0,
    wasm_length: u32 = 0,
    services: u32 = 0,
    sdk_abi: u32 = 0,
    origin: u32 = 0,
    attestation: u32 = 0,
    module_tag: u32 = 0,
    digest_tag: u32 = 0,
    instruction_budget: u32 = 0,
    sequence_low: u32 = 0,
    sequence_high: u32 = 0,
    package_length: u32 = 0,
    trust_epoch_low: u32 = 0,
    trust_epoch_high: u32 = 0,
    boot_recovered: u32 = 0,
    initial_sequence_low: u32 = 0,
    initial_sequence_high: u32 = 0,
    installed_sequence_low: u32 = 0,
    installed_sequence_high: u32 = 0,
    package_syncs: u32 = 0,
    simulated_reboot: u32 = 0,
    interrupted_update_recovered: u32 = 0,
};

const Mutable = struct {
    bytes: []u8,
    sync_count: u32 = 0,
    write_count: u32 = 0,
    fail_write: u32 = 0,

    fn trust(self: *Mutable) snapshot_store.Storage {
        return .{ .context = self, .bytes = self.bytes.len, .readAt = readAt, .writeAt = writeAt, .sync = sync };
    }

    fn packages(self: *Mutable) install.Storage {
        return .{ .context = self, .bytes = self.bytes.len, .readAt = readAt, .writeAt = writeAt, .sync = sync };
    }

    fn readAt(context: *anyopaque, offset: usize, output: []u8) snapshot_store.IoError!void {
        const self: *Mutable = @ptrCast(@alignCast(context));
        const end = std.math.add(usize, offset, output.len) catch return error.Io;
        if (end > self.bytes.len) return error.Io;
        @memcpy(output, self.bytes[offset..end]);
    }

    fn writeAt(context: *anyopaque, offset: usize, input: []const u8) snapshot_store.IoError!void {
        const self: *Mutable = @ptrCast(@alignCast(context));
        const end = std.math.add(usize, offset, input.len) catch return error.Io;
        if (end > self.bytes.len) return error.Io;
        self.write_count +%= 1;
        if (self.fail_write != 0 and self.write_count == self.fail_write) {
            self.fail_write = 0;
            return error.PowerLoss;
        }
        @memcpy(self.bytes[offset..end], input);
    }

    fn sync(context: *anyopaque) snapshot_store.IoError!void {
        const self: *Mutable = @ptrCast(@alignCast(context));
        self.sync_count +%= 1;
    }
};

const Counter = struct {
    floor: u64,

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

export fn nih_package_boot_recover(
    destination: [*]u8,
    destination_capacity: u32,
    report: *BootReport,
) callconv(.c) c_int {
    report.* = .{};
    const trust_image = blob(
        &_binary_boot_trust_bin_start,
        &_binary_boot_trust_bin_end,
    ) orelse return 1;
    const package_image = blob(
        &_binary_boot_package_bin_start,
        &_binary_boot_package_bin_end,
    ) orelse return 2;
    const counter_image = blob(
        &_binary_boot_counter_bin_start,
        &_binary_boot_counter_bin_end,
    ) orelse return 3;
    const root_public = blob(
        &_binary_boot_root_pub_start,
        &_binary_boot_root_pub_end,
    ) orelse return 4;
    const update_package = blob(
        &_binary_boot_update_bin_start,
        &_binary_boot_update_bin_end,
    ) orelse return 5;
    if (trust_image.len != trust_layout.requiredBytes() catch return 6) return 6;
    if (package_image.len != package_layout.requiredBytes() catch return 7) return 7;
    if (counter_image.len != 8 or root_public.len != 32) return 8;
    if (destination_capacity < max_package or update_package.len > max_package) return 9;

    var trust_bytes: [2 * (max_snapshot + snapshot_store.record_bytes)]u8 = undefined;
    var package_bytes: [2 * (max_package + install.record_bytes)]u8 = undefined;
    @memcpy(&trust_bytes, trust_image);
    @memcpy(&package_bytes, package_image);
    var trust_storage = Mutable{ .bytes = &trust_bytes };
    var package_storage = Mutable{ .bytes = &package_bytes };
    var counter = Counter{ .floor = read64(counter_image) };
    var root_records = [_]snapshot_ed25519.RootRecord{.{
        .root_key_id = "root-test-key-01".*,
        .public_key = root_public[0..32].*,
        .status = .trusted,
        .role = .normal,
    }};
    var roots = snapshot_ed25519.RootStore{
        .roots = &root_records,
        .limits = .{
            .max_snapshot_bytes = max_snapshot,
            .max_signature_bytes = 64,
            .max_keys = 8,
            .max_rollback = 8,
        },
    };
    var snapshot_scratch: [max_snapshot]u8 = undefined;
    var package_keys: [8]package_ed25519.KeyRecord = undefined;
    var rollback: [8]package_ed25519.RollbackRecord = undefined;
    const boot_inputs = app_boot.Inputs{
        .trust_storage = trust_storage.trust(),
        .monotonic = counter.interface(),
        .trust_layout = trust_layout,
        .roots = &roots,
        .package_storage = package_storage.packages(),
        .package_layout = package_layout,
        .max_signature_bytes = 64,
        .limits = .{
            .granted_services = policy.Service.graphics,
            .max_linear_pages = 1,
            .max_instruction_budget = 10_000,
            .max_wasm_bytes = max_package,
        },
    };
    const boot_workspace = app_boot.Workspace{
        .snapshot_bytes = &snapshot_scratch,
        .package_bytes = destination[0..destination_capacity],
        .package_keys = &package_keys,
        .rollback = &rollback,
    };
    var coordinator = app_boot.Coordinator{};
    const initial = switch (coordinator.recover(boot_inputs, boot_workspace) catch return 10) {
        .ready => |value| value,
        else => return 11,
    };
    if (initial.installed.sequence != 1) return 12;
    report.initial_sequence_low = @truncate(initial.installed.sequence);
    report.initial_sequence_high = @truncate(initial.installed.sequence >> 32);

    // Drop the commit-record write after the inactive record and payload have
    // both been synced. A fresh coordinator must still select sequence 1.
    package_storage.fail_write = 3;
    if (coordinator.installPackage(
        boot_inputs,
        boot_workspace,
        update_package,
    )) |_| {
        return 13;
    } else |err| {
        if (err != error.PowerLoss) return 13;
    }
    if (package_storage.write_count != 3 or package_storage.sync_count != 2)
        return 14;
    var after_interruption = app_boot.Coordinator{};
    const old_ready = switch (after_interruption.recover(boot_inputs, boot_workspace) catch return 15) {
        .ready => |value| value,
        else => return 16,
    };
    if (old_ready.installed.sequence != 1) return 17;
    report.interrupted_update_recovered = 1;

    package_storage.write_count = 0;
    package_storage.sync_count = 0;
    const installed = after_interruption.installPackage(
        boot_inputs,
        boot_workspace,
        update_package,
    ) catch return 18;
    if (installed.disposition != .installed or installed.ready.installed.sequence != 2)
        return 19;
    report.installed_sequence_low = @truncate(installed.ready.installed.sequence);
    report.installed_sequence_high = @truncate(installed.ready.installed.sequence >> 32);
    report.package_syncs = package_storage.sync_count;

    var restarted = app_boot.Coordinator{};
    const ready = switch (restarted.recover(boot_inputs, boot_workspace) catch return 20) {
        .ready => |value| value,
        else => return 21,
    };
    if (ready.installed.sequence != 2) return 22;
    report.simulated_reboot = 1;
    const envelope = package.parse(ready.package_bytes, .{
        .max_package_bytes = max_package,
        .max_signature_bytes = 64,
    }) catch return 23;
    const offset = @intFromPtr(envelope.wasm.ptr) - @intFromPtr(destination);
    report.trust_status = @backingInt(package.TrustDecision.accepted);
    report.policy_status = @backingInt(policy.Decision.accepted);
    report.wasm_offset = std.math.cast(u32, offset) orelse return 24;
    report.wasm_length = std.math.cast(u32, envelope.wasm.len) orelse return 24;
    report.services = envelope.services;
    report.sdk_abi = envelope.sdk_abi;
    report.origin = @backingInt(policy.Origin.signed_package);
    report.attestation = @backingInt(policy.Attestation.verified);
    report.module_tag = tag(envelope.module_id[0..4].*);
    report.digest_tag = tag(envelope.wasm_sha256[0..4].*);
    report.instruction_budget = envelope.instruction_budget;
    report.sequence_low = @truncate(envelope.sequence);
    report.sequence_high = @truncate(envelope.sequence >> 32);
    report.package_length = @intCast(ready.package_bytes.len);
    report.trust_epoch_low = @truncate(ready.trust_epoch);
    report.trust_epoch_high = @truncate(ready.trust_epoch >> 32);
    report.boot_recovered = 1;
    return 0;
}

fn blob(start: *const u8, end: *const u8) ?[]const u8 {
    const first = @intFromPtr(start);
    const last = @intFromPtr(end);
    if (last <= first) return null;
    return @as([*]const u8, @ptrFromInt(first))[0 .. last - first];
}

fn read64(bytes: []const u8) u64 {
    var result: u64 = 0;
    for (0..8) |index| result |= @as(u64, bytes[index]) << @intCast(index * 8);
    return result;
}

fn tag(bytes: [4]u8) u32 {
    return @as(u32, bytes[0]) |
        (@as(u32, bytes[1]) << 8) |
        (@as(u32, bytes[2]) << 16) |
        (@as(u32, bytes[3]) << 24);
}
