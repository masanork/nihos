//! Host-only process-boundary probe for the full trust/package boot closure.
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
const max_package = if (@hasDecl(@import("root"), "boot_process_max_package"))
    @import("root").boot_process_max_package
else
    512;
const trust_layout = snapshot_store.Layout{ .max_snapshot_bytes = max_snapshot };
const package_layout = install.Layout{ .max_package_bytes = max_package };
const publisher_id = "nihos.dev/system".*;
const module_id = "nihos-rust-wasm1".*;
const app_key_id = "rfc8032-vector01".*;
const root_id = "root-test-key-01".*;
const Cut = enum { none, clear, payload, record, committed };

pub const FileAdapter = struct {
    file: std.Io.File,
    io: std.Io,
    bytes: usize,
    write_count: u32 = 0,
    sync_count: u32 = 0,
    pause_before_commit: bool = false,
    read_count: u32 = 0,
    cut: Cut = .none,

    fn checkpoint(self: *FileAdapter, partial: usize) noreturn {
        std.debug.print("NIHOS_PACKAGE_CUT phase=cut-{s} package_syncs={d} partial_bytes={d} pid={d}\n", .{ @tagName(self.cut), self.sync_count, partial, std.c.getpid() });
        while (true) std.atomic.spinLoopHint();
    }

    pub fn trust(self: *FileAdapter) snapshot_store.Storage {
        return .{ .context = self, .bytes = self.bytes, .readAt = readAtTrust, .writeAt = writeAtTrust, .sync = syncTrust };
    }
    pub fn packages(self: *FileAdapter) install.Storage {
        return .{ .context = self, .bytes = self.bytes, .readAt = readAtInstall, .writeAt = writeAtInstall, .sync = syncInstall };
    }
    fn read(self: *FileAdapter, offset: usize, output: []u8) !void {
        self.read_count +%= 1;
        const amount = self.file.readPositionalAll(self.io, output, offset) catch return error.Io;
        if (amount != output.len) return error.Io;
    }
    fn write(self: *FileAdapter, offset: usize, input: []const u8) !void {
        self.write_count +%= 1;
        if ((self.cut == .payload and self.write_count == 2) or
            (self.cut == .record and self.write_count == 3))
        {
            const partial = input.len / 2;
            self.file.writePositionalAll(self.io, input[0..partial], offset) catch return error.Io;
            self.checkpoint(partial);
        }
        if (self.pause_before_commit and self.write_count == 3) {
            if (self.sync_count != 2) return error.Io;
            std.debug.print("NIHOS_BOOT_PROCESS phase=interrupt trust_epoch=1 sequence=1 package_syncs=2 await_sigkill=1 pid={d}\n", .{std.c.getpid()});
            // The parent owns this child and kills it after seeing the marker.
            // Never return to the installer or issue the commit-record write.
            while (true) std.atomic.spinLoopHint();
        }
        self.file.writePositionalAll(self.io, input, offset) catch return error.Io;
    }
    fn flush(self: *FileAdapter) !void {
        self.file.sync(self.io) catch return error.Io;
        self.sync_count +%= 1;
        if ((self.cut == .clear and self.sync_count == 1) or
            (self.cut == .committed and self.sync_count == 3)) self.checkpoint(0);
    }
    fn readAtTrust(context: *anyopaque, offset: usize, output: []u8) snapshot_store.IoError!void {
        const self: *FileAdapter = @ptrCast(@alignCast(context));
        self.read(offset, output) catch return error.Io;
    }
    fn writeAtTrust(context: *anyopaque, offset: usize, input: []const u8) snapshot_store.IoError!void {
        const self: *FileAdapter = @ptrCast(@alignCast(context));
        self.write(offset, input) catch |err| return if (err == error.PowerLoss) error.PowerLoss else error.Io;
    }
    fn syncTrust(context: *anyopaque) snapshot_store.IoError!void {
        const self: *FileAdapter = @ptrCast(@alignCast(context));
        self.flush() catch return error.Io;
    }
    fn readAtInstall(context: *anyopaque, offset: usize, output: []u8) install.IoError!void {
        const self: *FileAdapter = @ptrCast(@alignCast(context));
        self.read(offset, output) catch return error.Io;
    }
    fn writeAtInstall(context: *anyopaque, offset: usize, input: []const u8) install.IoError!void {
        const self: *FileAdapter = @ptrCast(@alignCast(context));
        self.write(offset, input) catch |err| return if (err == error.PowerLoss) error.PowerLoss else error.Io;
    }
    fn syncInstall(context: *anyopaque) install.IoError!void {
        const self: *FileAdapter = @ptrCast(@alignCast(context));
        self.flush() catch return error.Io;
    }
};

pub const FileCounter = struct {
    file: std.Io.File,
    io: std.Io,
    sync_count: u32 = 0,
    fail_advance: bool = false,
    exit_after_trust: ?*FileAdapter = null,

    pub fn interface(self: *FileCounter) snapshot_store.Monotonic {
        return .{ .context = self, .read = read, .advance = advance };
    }
    fn read(context: *anyopaque) snapshot_store.IoError!u64 {
        const self: *FileCounter = @ptrCast(@alignCast(context));
        var bytes: [8]u8 = undefined;
        const amount = self.file.readPositionalAll(self.io, &bytes, 0) catch return error.Io;
        if (amount != bytes.len) return error.Io;
        return read64(&bytes);
    }
    fn advance(context: *anyopaque, epoch: u64) snapshot_store.IoError!void {
        const self: *FileCounter = @ptrCast(@alignCast(context));
        if (self.exit_after_trust) |trust| {
            if (epoch != 2 or try read(context) != 1 or trust.sync_count != 3 or
                self.sync_count != 0) return error.Io;
            std.debug.print("NIHOS_BOOT_PROCESS phase=interrupt-trust trust_epoch=2 counter_floor=1 trust_syncs=3 counter_syncs=0 abrupt_exit=86 pid={d}\n", .{std.c.getpid()});
            // Deliberately bypass Zig defers and file close paths. Only the
            // three completed trust fsync calls precede this process exit.
            std.c._exit(86);
        }
        if (self.fail_advance) return error.PowerLoss;
        if (epoch < try read(context)) return error.Io;
        var bytes: [8]u8 = undefined;
        write64(&bytes, epoch);
        self.file.writePositionalAll(self.io, &bytes, 0) catch return error.Io;
        self.file.sync(self.io) catch return error.Io;
        self.sync_count +%= 1;
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
pub const Work = struct {
    snapshot_bytes: [max_snapshot]u8 = undefined,
    package_bytes: [max_package]u8 = undefined,
    keys: [8]package_ed25519.KeyRecord = undefined,
    rollback: [8]package_ed25519.RollbackRecord = undefined,
    pub fn workspace(self: *Work) app_boot.Workspace {
        return .{ .snapshot_bytes = &self.snapshot_bytes, .package_bytes = &self.package_bytes, .package_keys = &self.keys, .rollback = &self.rollback };
    }
};

fn padded(key: [32]u8) [snapshot.max_public_key_bytes]u8 {
    var result: [snapshot.max_public_key_bytes]u8 = @splat(0);
    @memcpy(result[0..key.len], &key);
    return result;
}
fn buildSnapshot(root_pair: Ed25519.KeyPair, app_public_key: [32]u8, epoch: u64, status: package.KeyStatus) !BuiltSnapshot {
    const keys = [_]snapshot.KeyRecord{.{ .publisher_id = publisher_id, .key_id = app_key_id, .algorithm = package_ed25519.algorithm_id, .status = status, .public_key_bytes = Ed25519.PublicKey.encoded_length, .public_key = padded(app_public_key) }};
    const rollback = [_]snapshot.RollbackRecord{.{ .publisher_id = publisher_id, .module_id = module_id, .minimum_sequence = 1 }};
    var result = BuiltSnapshot{};
    const prepared = try snapshot.prepare(&result.bytes, .{ .algorithm = snapshot_ed25519.algorithm_id, .signature_bytes = Ed25519.Signature.encoded_length, .epoch = epoch, .root_key_id = root_id, .authority = .normal, .keys = &keys, .rollback = &rollback });
    const signature = try root_pair.sign(prepared.signed_bytes, null);
    @memcpy(prepared.signature, &signature.toBytes());
    result.length = prepared.snapshot.len;
    return result;
}
fn buildPackage(sequence: u64, app_pair: Ed25519.KeyPair) !BuiltPackage {
    const wasm = [_]u8{ 0x00, 0x61, 0x73, 0x6d, @truncate(sequence) };
    var result = BuiltPackage{};
    const prepared = try package.prepare(&result.bytes, .{ .algorithm = package_ed25519.algorithm_id, .signature_bytes = Ed25519.Signature.encoded_length, .sequence = sequence, .schema = policy.current_schema, .sdk_abi = policy.current_sdk_abi, .module_id = module_id, .publisher_id = publisher_id, .version = @intCast(sequence), .services = policy.Service.graphics, .max_linear_pages = 1, .instruction_budget = 10_000, .key_id = app_key_id, .wasm = &wasm });
    const signature = try app_pair.sign(prepared.signed_bytes, null);
    @memcpy(prepared.signature, &signature.toBytes());
    result.length = prepared.package.len;
    return result;
}
pub fn bootInputs(trust: *FileAdapter, counter: *FileCounter, roots: *snapshot_ed25519.RootStore, packages: *FileAdapter) app_boot.Inputs {
    return .{ .trust_storage = trust.trust(), .monotonic = counter.interface(), .trust_layout = trust_layout, .roots = roots, .package_storage = packages.packages(), .package_layout = package_layout, .max_signature_bytes = 64, .limits = .{ .granted_services = policy.Service.graphics, .max_linear_pages = 1, .max_instruction_budget = 10_000, .max_wasm_bytes = max_package } };
}
fn expectReady(result: app_boot.Result, sequence: u64, expected: []const u8) !void {
    const ready = switch (result) {
        .ready => |value| value,
        else => return error.ExpectedReady,
    };
    if (ready.trust_epoch != 1 or ready.installed.sequence != sequence or !std.mem.eql(u8, ready.package_bytes, expected)) return error.RecoveredBytesDiffer;
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 5) return error.ExpectedPhaseAndThreeMediaPaths;
    const phase = args[1];
    const provisioning = std.mem.eql(u8, phase, "provision");
    const trust_bytes = try trust_layout.requiredBytes();
    const package_bytes = try package_layout.requiredBytes();
    var trust_file = if (provisioning) try std.Io.Dir.cwd().createFile(init.io, args[2], .{ .read = true }) else try std.Io.Dir.cwd().openFile(init.io, args[2], .{ .mode = .read_write });
    defer trust_file.close(init.io);
    var counter_file = if (provisioning) try std.Io.Dir.cwd().createFile(init.io, args[3], .{ .read = true }) else try std.Io.Dir.cwd().openFile(init.io, args[3], .{ .mode = .read_write });
    defer counter_file.close(init.io);
    var package_file = if (provisioning) try std.Io.Dir.cwd().createFile(init.io, args[4], .{ .read = true }) else try std.Io.Dir.cwd().openFile(init.io, args[4], .{ .mode = .read_write });
    defer package_file.close(init.io);
    if (provisioning) {
        try trust_file.setLength(init.io, trust_bytes);
        try counter_file.setLength(init.io, 8);
        try package_file.setLength(init.io, package_bytes);
    }
    var trust = FileAdapter{ .file = trust_file, .io = init.io, .bytes = trust_bytes };
    var counter = FileCounter{ .file = counter_file, .io = init.io };
    var packages = FileAdapter{ .file = package_file, .io = init.io, .bytes = package_bytes };
    var app_seed: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&app_seed, "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60");
    const app_pair = try Ed25519.KeyPair.generateDeterministic(app_seed);
    const root_pair = try Ed25519.KeyPair.generateDeterministic(@splat(0x31));
    var root_records = [_]snapshot_ed25519.RootRecord{.{ .root_key_id = root_id, .public_key = root_pair.public_key.toBytes(), .status = .trusted, .role = .normal }};
    var roots = snapshot_ed25519.RootStore{ .roots = &root_records, .limits = .{ .max_snapshot_bytes = max_snapshot, .max_signature_bytes = 64, .max_keys = 8, .max_rollback = 8 } };
    const trust_snapshot = try buildSnapshot(root_pair, app_pair.public_key.toBytes(), 1, .trusted);
    const first = try buildPackage(1, app_pair);
    const second = try buildPackage(2, app_pair);
    var work = Work{};
    var coordinator = app_boot.Coordinator{};
    const inputs = bootInputs(&trust, &counter, &roots, &packages);
    const pid = std.c.getpid();
    if (std.mem.eql(u8, phase, "reject-corrupt")) {
        if (coordinator.recover(inputs, work.workspace())) |_| {
            return error.ExpectedCorruptHead;
        } else |err| {
            if (err != error.ActivePackageInvalid) return err;
        }
        if (coordinator.installPackage(inputs, work.workspace(), second.slice())) |_| {
            return error.ExpectedCorruptHead;
        } else |err| {
            if (err != error.ActivePackageInvalid) return err;
        }
        if (trust.write_count != 0 or packages.write_count != 0 or
            counter.sync_count != 0) return error.UnexpectedMutation;
        std.debug.print("NIHOS_BOOT_PROCESS phase=reject-corrupt boot_rejected=ActivePackageInvalid install_rejected=ActivePackageInvalid writes=0 pid={d}\n", .{pid});
        return;
    }
    if (std.mem.eql(u8, phase, "reject-rollback")) {
        if (coordinator.recover(inputs, work.workspace())) |_| {
            return error.ExpectedRollback;
        } else |err| {
            if (err != error.Rollback) return err;
        }
        if (try FileCounter.read(&counter) != 2 or trust.write_count != 0 or
            packages.write_count != 0 or counter.sync_count != 0) return error.UnexpectedMutation;
        std.debug.print("NIHOS_BOOT_PROCESS phase=reject-rollback trust_epoch=1 counter_floor=2 rejected=Rollback writes=0 pid={d}\n", .{pid});
        return;
    }
    if (std.mem.eql(u8, phase, "reject-revoked")) {
        if (coordinator.recover(inputs, work.workspace())) |_| {
            return error.ExpectedRevocation;
        } else |err| {
            if (err != error.ActivePackageRejected) return err;
        }
        if (coordinator.installPackage(inputs, work.workspace(), second.slice())) |_| {
            return error.ExpectedInstallRejection;
        } else |err| {
            if (err != error.RejectedPackage) return err;
        }
        if (try FileCounter.read(&counter) != 2 or trust.write_count != 0 or
            packages.write_count != 0 or counter.sync_count != 0) return error.UnexpectedMutation;
        std.debug.print("NIHOS_BOOT_PROCESS phase=reject-revoked trust_epoch=2 sequence=2 boot_rejected=1 install_rejected=1 writes=0 pid={d}\n", .{pid});
        return;
    }
    if (std.mem.eql(u8, phase, "reject-unsealed")) {
        if (try FileCounter.read(&counter) != 1) return error.ExpectedLaggingCounter;
        counter.fail_advance = true;
        if (coordinator.recover(inputs, work.workspace())) |_| {
            return error.ExpectedPowerLoss;
        } else |err| {
            if (err != error.PowerLoss) return err;
        }
        if (try FileCounter.read(&counter) != 1 or trust.write_count != 0 or
            packages.read_count != 0 or packages.write_count != 0 or
            counter.sync_count != 0) return error.UnexpectedMutation;
        std.debug.print("NIHOS_BOOT_PROCESS phase=reject-unsealed trust_epoch=2 counter_floor=1 seal_failed=1 package_reads=0 pid={d}\n", .{pid});
        return;
    }
    if (std.mem.eql(u8, phase, "seal-revoked")) {
        if (try FileCounter.read(&counter) != 1) return error.ExpectedLaggingCounter;
        if (coordinator.recover(inputs, work.workspace())) |_| {
            return error.ExpectedRevocation;
        } else |err| {
            if (err != error.ActivePackageRejected) return err;
        }
        if (try FileCounter.read(&counter) != 2 or counter.sync_count != 1 or
            trust.write_count != 0 or packages.write_count != 0)
            return error.SealingFailed;
        std.debug.print("NIHOS_BOOT_PROCESS phase=seal-revoked trust_epoch=2 counter_floor=2 counter_syncs=1 boot_rejected=1 pid={d}\n", .{pid});
        return;
    }
    if (std.mem.eql(u8, phase, "interrupt-trust")) {
        try expectReady(try coordinator.recover(inputs, work.workspace()), 2, second.slice());
        const revoked = try buildSnapshot(root_pair, app_pair.public_key.toBytes(), 2, .revoked);
        counter.exit_after_trust = &trust;
        _ = try snapshot_store.update(trust.trust(), counter.interface(), try roots.authenticator(), trust_layout, revoked.slice(), &work.snapshot_bytes);
        return error.ExpectedAbruptExit;
    }
    if (provisioning) {
        _ = try snapshot_store.update(trust.trust(), counter.interface(), try roots.authenticator(), trust_layout, trust_snapshot.slice(), &work.snapshot_bytes);
        const installed = try coordinator.installPackage(inputs, work.workspace(), first.slice());
        if (installed.ready.installed.sequence != 1 or trust.sync_count != 3 or counter.sync_count != 1 or packages.sync_count != 3) return error.ProvisionFailed;
        std.debug.print("NIHOS_BOOT_PROCESS phase=provision trust_epoch=1 sequence=1 trust_syncs=3 counter_syncs=1 package_syncs=3 pid={d}\n", .{pid});
        return;
    }
    if (std.mem.eql(u8, phase, "recover-new")) {
        try expectReady(try coordinator.recover(inputs, work.workspace()), 2, second.slice());
        std.debug.print("NIHOS_BOOT_PROCESS phase=recover-new trust_epoch=1 sequence=2 process_reopen=1 pid={d}\n", .{pid});
        return;
    }
    try expectReady(try coordinator.recover(inputs, work.workspace()), 1, first.slice());
    if (std.mem.startsWith(u8, phase, "cut-")) {
        packages.cut = std.meta.stringToEnum(Cut, phase[4..]) orelse return error.UnknownCut;
        if (packages.cut == .none) return error.UnknownCut;
        _ = try coordinator.installPackage(inputs, work.workspace(), second.slice());
        return error.ExpectedParentKill;
    }
    if (std.mem.eql(u8, phase, "interrupt")) {
        packages.pause_before_commit = true;
        _ = try coordinator.installPackage(inputs, work.workspace(), second.slice());
        return error.ExpectedParentKill;
    }
    if (std.mem.eql(u8, phase, "recover-old")) {
        std.debug.print("NIHOS_BOOT_PROCESS phase=recover-old trust_epoch=1 sequence=1 process_reopen=1 pid={d}\n", .{pid});
        return;
    }
    if (std.mem.eql(u8, phase, "install")) {
        const installed = try coordinator.installPackage(inputs, work.workspace(), second.slice());
        if (installed.ready.installed.sequence != 2 or packages.sync_count != 3) return error.InstallFailed;
        std.debug.print("NIHOS_BOOT_PROCESS phase=install trust_epoch=1 sequence=2 package_syncs=3 pid={d}\n", .{pid});
        return;
    }
    return error.UnknownPhase;
}
fn read64(bytes: *const [8]u8) u64 {
    var result: u64 = 0;
    for (0..8) |index| result |= @as(u64, bytes[index]) << @intCast(index * 8);
    return result;
}
fn write64(bytes: *[8]u8, value: u64) void {
    for (0..8) |index| bytes[index] = @truncate(value >> @intCast(index * 8));
}
