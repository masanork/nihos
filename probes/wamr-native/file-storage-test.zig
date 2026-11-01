//! Host-only file adapter conformance probe. fsync here is not device evidence.
const std = @import("std");
const package = @import("app_package");
const install = @import("app_install");
const policy = @import("app_policy");
const trust_store = @import("trust_snapshot_store");

const FileAdapter = struct {
    file: std.Io.File,
    io: std.Io,
    bytes: usize,
    sync_count: usize = 0,
    sync_attempts: usize = 0,
    written: usize = 0,
    fail_write_at: ?usize = null,
    fail_sync_at: ?usize = null,

    fn trust(self: *FileAdapter) trust_store.Storage {
        return .{ .context = self, .bytes = self.bytes, .readAt = readAt, .writeAt = writeAt, .sync = sync };
    }
    fn packages(self: *FileAdapter) install.Storage {
        return .{ .context = self, .bytes = self.bytes, .readAt = readAtInstall, .writeAt = writeAtInstall, .sync = syncInstall };
    }
    fn read(self: *FileAdapter, offset: usize, output: []u8) !void {
        const amount = self.file.readPositionalAll(self.io, output, offset) catch return error.Io;
        if (amount != output.len) return error.Io;
    }
    fn write(self: *FileAdapter, offset: usize, input: []const u8) !void {
        if (self.fail_write_at) |cut| {
            if (self.written >= cut) return error.Io;
            const allowed = @min(input.len, cut - self.written);
            self.file.writePositionalAll(self.io, input[0..allowed], offset) catch return error.Io;
            self.written += allowed;
            if (allowed != input.len) return error.Io;
            return;
        }
        self.file.writePositionalAll(self.io, input, offset) catch return error.Io;
        self.written += input.len;
    }
    fn flush(self: *FileAdapter) !void {
        if (self.fail_sync_at == self.sync_attempts) {
            self.sync_attempts += 1;
            return error.Io;
        }
        self.sync_attempts += 1;
        self.file.sync(self.io) catch return error.Io;
        self.sync_count += 1;
    }
    fn readAt(context: *anyopaque, offset: usize, output: []u8) trust_store.IoError!void {
        const self: *FileAdapter = @ptrCast(@alignCast(context));
        self.read(offset, output) catch return error.Io;
    }
    fn writeAt(context: *anyopaque, offset: usize, input: []const u8) trust_store.IoError!void {
        const self: *FileAdapter = @ptrCast(@alignCast(context));
        self.write(offset, input) catch return error.Io;
    }
    fn sync(context: *anyopaque) trust_store.IoError!void {
        const self: *FileAdapter = @ptrCast(@alignCast(context));
        self.flush() catch return error.Io;
    }
    fn readAtInstall(context: *anyopaque, offset: usize, output: []u8) install.IoError!void {
        const self: *FileAdapter = @ptrCast(@alignCast(context));
        self.read(offset, output) catch return error.Io;
    }
    fn writeAtInstall(context: *anyopaque, offset: usize, input: []const u8) install.IoError!void {
        const self: *FileAdapter = @ptrCast(@alignCast(context));
        self.write(offset, input) catch return error.Io;
    }
    fn syncInstall(context: *anyopaque) install.IoError!void {
        const self: *FileAdapter = @ptrCast(@alignCast(context));
        self.flush() catch return error.Io;
    }
};

const FileCounter = struct {
    file: std.Io.File,
    io: std.Io,
    sync_count: usize = 0,

    fn interface(self: *FileCounter) trust_store.Monotonic {
        return .{ .context = self, .read = read, .advance = advance };
    }
    fn read(context: *anyopaque) trust_store.IoError!u64 {
        const self: *FileCounter = @ptrCast(@alignCast(context));
        var bytes: [8]u8 = undefined;
        const amount = self.file.readPositionalAll(self.io, &bytes, 0) catch return error.Io;
        if (amount != bytes.len) return error.Io;
        return read64(&bytes, 0);
    }
    fn advance(context: *anyopaque, epoch: u64) trust_store.IoError!void {
        const self: *FileCounter = @ptrCast(@alignCast(context));
        const current = try read(context);
        if (epoch < current) return error.Io;
        var bytes: [8]u8 = undefined;
        write64(&bytes, 0, epoch);
        self.file.writePositionalAll(self.io, &bytes, 0) catch return error.Io;
        self.file.sync(self.io) catch return error.Io;
        self.sync_count += 1;
    }
};

fn snapshot(epoch: u64, marker: u8) [64]u8 {
    var bytes: [64]u8 = @splat(0);
    @memcpy(bytes[0..8], "FILETEST");
    write64(&bytes, 8, epoch);
    bytes[16] = marker;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes[0..32], &digest, .{});
    @memcpy(bytes[32..64], &digest);
    return bytes;
}

fn authenticate(_: *anyopaque, bytes: []const u8) ?u64 {
    if (bytes.len != 64 or !std.mem.eql(u8, bytes[0..8], "FILETEST")) return null;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes[0..32], &digest, .{});
    if (!std.mem.eql(u8, &digest, bytes[32..64])) return null;
    const epoch = read64(bytes, 8);
    return if (epoch == 0) null else epoch;
}

const MockTrust = struct { minimum_sequence: u64 = 1 };
fn provider(mock: *MockTrust) package.TrustProvider {
    return .{ .context = mock, .keyStatus = keyStatus, .minimumSequence = minimumSequence, .verifySignature = verifySignature };
}
fn keyStatus(_: *anyopaque, _: [16]u8, _: [16]u8) package.KeyStatus {
    return .trusted;
}
fn minimumSequence(context: *anyopaque, _: [16]u8, _: [16]u8) u64 {
    const mock: *MockTrust = @ptrCast(@alignCast(context));
    return mock.minimum_sequence;
}
fn verifySignature(_: *anyopaque, _: u16, _: [16]u8, _: [16]u8, _: []const u8, signature: []const u8) package.SignatureStatus {
    return if (signature.len == 64 and signature[0] == 0xa5) .verified else .invalid;
}

fn buildPackage(bytes: []u8, sequence: u64, marker: u8) ![]u8 {
    const wasm = [_]u8{ 0x00, 0x61, 0x73, 0x6d, marker };
    const prepared = try package.prepare(bytes, .{
        .algorithm = 7,
        .signature_bytes = 64,
        .sequence = sequence,
        .schema = policy.current_schema,
        .sdk_abi = policy.current_sdk_abi,
        .module_id = "nihos-rust-wasm1".*,
        .publisher_id = "nihos.dev/system".*,
        .version = @intCast(sequence),
        .services = policy.Service.graphics,
        .max_linear_pages = 1,
        .instruction_budget = 10_000,
        .key_id = "publisher-key-01".*,
        .wasm = &wasm,
    });
    @memset(prepared.signature, 0xa5);
    return prepared.package;
}

test "fsync file adapters reopen exact trust snapshot and package" {
    const t = std.testing;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const trust_layout = trust_store.Layout{ .max_snapshot_bytes = 128 };
    const trust_bytes = try trust_layout.requiredBytes();
    var trust_file = try tmp.dir.createFile(io, "trust.bin", .{ .read = true });
    try trust_file.setLength(io, trust_bytes);
    var counter_file = try tmp.dir.createFile(io, "counter.bin", .{ .read = true });
    try counter_file.setLength(io, 8);
    var trust_adapter = FileAdapter{ .file = trust_file, .io = io, .bytes = trust_bytes };
    var counter = FileCounter{ .file = counter_file, .io = io };
    const auth_context = struct {
        var byte: u8 = 0;
    };
    const auth = trust_store.Authenticator{ .context = &auth_context.byte, .authenticate = authenticate };
    const first = snapshot(1, 1);
    const second = snapshot(2, 2);
    var trust_scratch: [128]u8 = undefined;
    _ = try trust_store.update(trust_adapter.trust(), counter.interface(), auth, trust_layout, &first, &trust_scratch);
    _ = try trust_store.update(trust_adapter.trust(), counter.interface(), auth, trust_layout, &second, &trust_scratch);
    try t.expectEqual(@as(usize, 6), trust_adapter.sync_count);
    try t.expectEqual(@as(usize, 2), counter.sync_count);
    trust_file.close(io);
    counter_file.close(io);

    trust_file = try tmp.dir.openFile(io, "trust.bin", .{ .mode = .read_write });
    counter_file = try tmp.dir.openFile(io, "counter.bin", .{ .mode = .read_write });
    defer trust_file.close(io);
    defer counter_file.close(io);
    trust_adapter = .{ .file = trust_file, .io = io, .bytes = trust_bytes };
    counter = .{ .file = counter_file, .io = io };
    const recovered = (try trust_store.recoverAndSeal(
        trust_adapter.trust(),
        counter.interface(),
        auth,
        trust_layout,
        &trust_scratch,
    )).?;
    try t.expectEqual(@as(u64, 2), recovered.epoch);
    try t.expectEqualSlices(u8, &second, try trust_store.readSnapshot(
        trust_adapter.trust(),
        trust_layout,
        recovered,
        &trust_scratch,
    ));

    const package_layout = install.Layout{ .max_package_bytes = 512 };
    const package_bytes = try package_layout.requiredBytes();
    var package_file = try tmp.dir.createFile(io, "package.bin", .{ .read = true });
    try package_file.setLength(io, package_bytes);
    var package_adapter = FileAdapter{ .file = package_file, .io = io, .bytes = package_bytes };
    var encoded: [512]u8 = undefined;
    const app = try buildPackage(&encoded, 1, 1);
    var install_scratch: [512]u8 = undefined;
    var mock = MockTrust{};
    const verification = install.Verification{
        .trust_epoch = 2,
        .max_signature_bytes = 64,
        .trust = provider(&mock),
        .limits = .{ .granted_services = policy.Service.graphics, .max_linear_pages = 1, .max_instruction_budget = 10_000, .max_wasm_bytes = 512 },
    };
    _ = try install.install(package_adapter.packages(), package_layout, app, verification, &install_scratch);
    try t.expectEqual(@as(usize, 3), package_adapter.sync_count);
    package_file.close(io);
    package_file = try tmp.dir.openFile(io, "package.bin", .{ .mode = .read_write });
    defer package_file.close(io);
    package_adapter = .{ .file = package_file, .io = io, .bytes = package_bytes };
    const installed = (try install.recover(
        package_adapter.packages(),
        package_layout,
        verification,
        &install_scratch,
    )).?;
    try t.expectEqual(@as(u64, 1), installed.sequence);
    try t.expectEqualSlices(u8, app, try install.readInstalled(
        package_adapter.packages(),
        package_layout,
        installed,
        &install_scratch,
    ));
    std.debug.print(
        "NIHOS_FILE_ADAPTER trust_epoch=2 package_sequence=1 reopen=1 fsync_trust=6 fsync_counter=2 fsync_package=3\n",
        .{},
    );
}

test "partial writes sync errors and short files never expose partial state" {
    const t = std.testing;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const auth_context = struct {
        var byte: u8 = 0;
    };
    const auth = trust_store.Authenticator{ .context = &auth_context.byte, .authenticate = authenticate };
    const trust_layout = trust_store.Layout{ .max_snapshot_bytes = 128 };
    const trust_bytes = try trust_layout.requiredBytes();
    try t.expectEqual(@as(usize, 448), trust_bytes);
    const first = snapshot(1, 1);
    const second = snapshot(2, 2);
    var trust_scratch: [128]u8 = undefined;

    var trust_file = try tmp.dir.createFile(io, "fault-trust.bin", .{ .read = true });
    try trust_file.setLength(io, trust_bytes);
    var counter_file = try tmp.dir.createFile(io, "fault-counter.bin", .{ .read = true });
    try counter_file.setLength(io, 8);
    var trust_adapter = FileAdapter{ .file = trust_file, .io = io, .bytes = trust_bytes };
    var counter = FileCounter{ .file = counter_file, .io = io };
    _ = try trust_store.update(
        trust_adapter.trust(),
        counter.interface(),
        auth,
        trust_layout,
        &first,
        &trust_scratch,
    );
    var trust_baseline: [448]u8 = undefined;
    try t.expectEqual(trust_baseline.len, try trust_file.readPositionalAll(io, &trust_baseline, 0));
    var counter_baseline: [8]u8 = undefined;
    try t.expectEqual(counter_baseline.len, try counter_file.readPositionalAll(io, &counter_baseline, 0));
    trust_file.close(io);
    counter_file.close(io);

    const write_cuts = [_]usize{ 0, 1, 95, 96, 100, 159, 160, 200, 255 };
    const sync_cuts = [_]usize{ 0, 1, 2 };
    for (write_cuts) |cut| {
        trust_file = try tmp.dir.openFile(io, "fault-trust.bin", .{ .mode = .read_write });
        counter_file = try tmp.dir.openFile(io, "fault-counter.bin", .{ .mode = .read_write });
        try trust_file.writePositionalAll(io, &trust_baseline, 0);
        try trust_file.sync(io);
        try counter_file.writePositionalAll(io, &counter_baseline, 0);
        try counter_file.sync(io);
        trust_adapter = .{ .file = trust_file, .io = io, .bytes = trust_bytes, .fail_write_at = cut };
        counter = .{ .file = counter_file, .io = io };
        try t.expectError(error.Io, trust_store.update(
            trust_adapter.trust(),
            counter.interface(),
            auth,
            trust_layout,
            &second,
            &trust_scratch,
        ));
        trust_file.close(io);
        counter_file.close(io);
        trust_file = try tmp.dir.openFile(io, "fault-trust.bin", .{ .mode = .read_write });
        counter_file = try tmp.dir.openFile(io, "fault-counter.bin", .{ .mode = .read_write });
        trust_adapter = .{ .file = trust_file, .io = io, .bytes = trust_bytes };
        counter = .{ .file = counter_file, .io = io };
        const recovered = (try trust_store.recoverAndSeal(
            trust_adapter.trust(),
            counter.interface(),
            auth,
            trust_layout,
            &trust_scratch,
        )).?;
        try t.expect(recovered.epoch == 1 or recovered.epoch == 2);
        const recovered_snapshot = try trust_store.readSnapshot(
            trust_adapter.trust(),
            trust_layout,
            recovered,
            &trust_scratch,
        );
        try t.expect(if (recovered.epoch == 1)
            std.mem.eql(u8, recovered_snapshot, &first)
        else
            std.mem.eql(u8, recovered_snapshot, &second));
        trust_file.close(io);
        counter_file.close(io);
    }
    for (sync_cuts) |cut| {
        trust_file = try tmp.dir.openFile(io, "fault-trust.bin", .{ .mode = .read_write });
        counter_file = try tmp.dir.openFile(io, "fault-counter.bin", .{ .mode = .read_write });
        try trust_file.writePositionalAll(io, &trust_baseline, 0);
        try trust_file.sync(io);
        try counter_file.writePositionalAll(io, &counter_baseline, 0);
        try counter_file.sync(io);
        trust_adapter = .{ .file = trust_file, .io = io, .bytes = trust_bytes, .fail_sync_at = cut };
        counter = .{ .file = counter_file, .io = io };
        try t.expectError(error.Io, trust_store.update(
            trust_adapter.trust(),
            counter.interface(),
            auth,
            trust_layout,
            &second,
            &trust_scratch,
        ));
        trust_file.close(io);
        counter_file.close(io);
        trust_file = try tmp.dir.openFile(io, "fault-trust.bin", .{ .mode = .read_write });
        counter_file = try tmp.dir.openFile(io, "fault-counter.bin", .{ .mode = .read_write });
        trust_adapter = .{ .file = trust_file, .io = io, .bytes = trust_bytes };
        counter = .{ .file = counter_file, .io = io };
        const recovered = (try trust_store.recoverAndSeal(
            trust_adapter.trust(),
            counter.interface(),
            auth,
            trust_layout,
            &trust_scratch,
        )).?;
        try t.expect(recovered.epoch == 1 or recovered.epoch == 2);
        const recovered_snapshot = try trust_store.readSnapshot(
            trust_adapter.trust(),
            trust_layout,
            recovered,
            &trust_scratch,
        );
        try t.expect(if (recovered.epoch == 1)
            std.mem.eql(u8, recovered_snapshot, &first)
        else
            std.mem.eql(u8, recovered_snapshot, &second));
        trust_file.close(io);
        counter_file.close(io);
    }

    trust_file = try tmp.dir.openFile(io, "fault-trust.bin", .{ .mode = .read_write });
    counter_file = try tmp.dir.openFile(io, "fault-counter.bin", .{ .mode = .read_write });
    try trust_file.writePositionalAll(io, &trust_baseline, 0);
    try trust_file.setLength(io, trust_bytes - 1);
    try counter_file.writePositionalAll(io, &counter_baseline, 0);
    trust_adapter = .{ .file = trust_file, .io = io, .bytes = trust_bytes };
    counter = .{ .file = counter_file, .io = io };
    try t.expectError(error.Io, trust_store.recoverAndSeal(
        trust_adapter.trust(),
        counter.interface(),
        auth,
        trust_layout,
        &trust_scratch,
    ));
    trust_file.close(io);
    counter_file.close(io);

    const package_layout = install.Layout{ .max_package_bytes = 512 };
    const package_bytes = try package_layout.requiredBytes();
    try t.expectEqual(@as(usize, 1312), package_bytes);
    var package_file = try tmp.dir.createFile(io, "fault-package.bin", .{ .read = true });
    try package_file.setLength(io, package_bytes);
    var package_adapter = FileAdapter{ .file = package_file, .io = io, .bytes = package_bytes };
    var first_encoded: [512]u8 = undefined;
    var second_encoded: [512]u8 = undefined;
    const first_app = try buildPackage(&first_encoded, 1, 1);
    const second_app = try buildPackage(&second_encoded, 2, 2);
    var install_scratch: [512]u8 = undefined;
    var mock = MockTrust{};
    const verification = install.Verification{
        .trust_epoch = 2,
        .max_signature_bytes = 64,
        .trust = provider(&mock),
        .limits = .{ .granted_services = policy.Service.graphics, .max_linear_pages = 1, .max_instruction_budget = 10_000, .max_wasm_bytes = 512 },
    };
    _ = try install.install(
        package_adapter.packages(),
        package_layout,
        first_app,
        verification,
        &install_scratch,
    );
    var package_baseline: [1312]u8 = undefined;
    try t.expectEqual(package_baseline.len, try package_file.readPositionalAll(io, &package_baseline, 0));
    package_file.close(io);
    const package_write_cuts = [_]usize{ 0, 1, 143, 144, 200, 356, 400, 499 };
    for (package_write_cuts) |cut| {
        package_file = try tmp.dir.openFile(io, "fault-package.bin", .{ .mode = .read_write });
        try package_file.writePositionalAll(io, &package_baseline, 0);
        try package_file.sync(io);
        package_adapter = .{ .file = package_file, .io = io, .bytes = package_bytes, .fail_write_at = cut };
        try t.expectError(error.Io, install.install(
            package_adapter.packages(),
            package_layout,
            second_app,
            verification,
            &install_scratch,
        ));
        package_file.close(io);
        package_file = try tmp.dir.openFile(io, "fault-package.bin", .{ .mode = .read_write });
        package_adapter = .{ .file = package_file, .io = io, .bytes = package_bytes };
        const recovered = (try install.recover(
            package_adapter.packages(),
            package_layout,
            verification,
            &install_scratch,
        )).?;
        try t.expect(recovered.sequence == 1 or recovered.sequence == 2);
        const recovered_package = try install.readInstalled(
            package_adapter.packages(),
            package_layout,
            recovered,
            &install_scratch,
        );
        try t.expect(if (recovered.sequence == 1)
            std.mem.eql(u8, recovered_package, first_app)
        else
            std.mem.eql(u8, recovered_package, second_app));
        package_file.close(io);
    }
    for (sync_cuts) |cut| {
        package_file = try tmp.dir.openFile(io, "fault-package.bin", .{ .mode = .read_write });
        try package_file.writePositionalAll(io, &package_baseline, 0);
        try package_file.sync(io);
        package_adapter = .{ .file = package_file, .io = io, .bytes = package_bytes, .fail_sync_at = cut };
        try t.expectError(error.Io, install.install(
            package_adapter.packages(),
            package_layout,
            second_app,
            verification,
            &install_scratch,
        ));
        package_file.close(io);
        package_file = try tmp.dir.openFile(io, "fault-package.bin", .{ .mode = .read_write });
        package_adapter = .{ .file = package_file, .io = io, .bytes = package_bytes };
        const recovered = (try install.recover(
            package_adapter.packages(),
            package_layout,
            verification,
            &install_scratch,
        )).?;
        try t.expect(recovered.sequence == 1 or recovered.sequence == 2);
        const recovered_package = try install.readInstalled(
            package_adapter.packages(),
            package_layout,
            recovered,
            &install_scratch,
        );
        try t.expect(if (recovered.sequence == 1)
            std.mem.eql(u8, recovered_package, first_app)
        else
            std.mem.eql(u8, recovered_package, second_app));
        package_file.close(io);
    }

    package_file = try tmp.dir.openFile(io, "fault-package.bin", .{ .mode = .read_write });
    try package_file.writePositionalAll(io, &package_baseline, 0);
    try package_file.setLength(io, package_bytes - 1);
    package_adapter = .{ .file = package_file, .io = io, .bytes = package_bytes };
    try t.expectError(error.Io, install.recover(
        package_adapter.packages(),
        package_layout,
        verification,
        &install_scratch,
    ));
    package_file.close(io);
    std.debug.print(
        "NIHOS_FILE_FAULTS trust_write_cuts={d} package_write_cuts={d} sync_cuts_each={d} exact_old_or_new=1 short_files_rejected=2\n",
        .{ write_cuts.len, package_write_cuts.len, sync_cuts.len },
    );
}

fn read64(bytes: []const u8, offset: usize) u64 {
    var result: u64 = 0;
    for (0..8) |index| result |= @as(u64, bytes[offset + index]) << @intCast(index * 8);
    return result;
}
fn write64(bytes: []u8, offset: usize, value: u64) void {
    for (0..8) |index| bytes[offset + index] = @truncate(value >> @intCast(index * 8));
}
