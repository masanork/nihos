//! Host-only deterministic builder for the native boot-media fixture.
//! Both private seeds are public test material and must never provision a device.
const std = @import("std");
const install = @import("app_install");
const package = @import("app_package");
const package_ed25519 = @import("package_ed25519");
const policy = @import("app_policy");
const snapshot = @import("trust_snapshot");
const snapshot_ed25519 = @import("trust_snapshot_ed25519");
const snapshot_store = @import("trust_snapshot_store");

const Ed25519 = std.crypto.sign.Ed25519;
const max_snapshot = 512;
const max_package = 4096;
const trust_layout = snapshot_store.Layout{ .max_snapshot_bytes = max_snapshot };
const package_layout = install.Layout{ .max_package_bytes = max_package };
const trust_bytes = 2 * (max_snapshot + snapshot_store.record_bytes);
const package_bytes = 2 * (max_package + install.record_bytes);

const Memory = struct {
    bytes: []u8,

    fn trust(self: *Memory) snapshot_store.Storage {
        return .{ .context = self, .bytes = self.bytes.len, .readAt = readAt, .writeAt = writeAt, .sync = sync };
    }

    fn packages(self: *Memory) install.Storage {
        return .{ .context = self, .bytes = self.bytes.len, .readAt = readAt, .writeAt = writeAt, .sync = sync };
    }

    fn readAt(context: *anyopaque, offset: usize, output: []u8) snapshot_store.IoError!void {
        const self: *Memory = @ptrCast(@alignCast(context));
        const end = std.math.add(usize, offset, output.len) catch return error.Io;
        if (end > self.bytes.len) return error.Io;
        @memcpy(output, self.bytes[offset..end]);
    }

    fn writeAt(context: *anyopaque, offset: usize, input: []const u8) snapshot_store.IoError!void {
        const self: *Memory = @ptrCast(@alignCast(context));
        const end = std.math.add(usize, offset, input.len) catch return error.Io;
        if (end > self.bytes.len) return error.Io;
        @memcpy(self.bytes[offset..end], input);
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

fn padded(key: [32]u8) [snapshot.max_public_key_bytes]u8 {
    var result: [snapshot.max_public_key_bytes]u8 = @splat(0);
    @memcpy(result[0..key.len], &key);
    return result;
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 6) return error.ExpectedPackageAndFourOutputs;
    const app = try std.Io.Dir.cwd().readFileAlloc(
        init.io,
        args[1],
        init.gpa,
        .limited(max_package),
    );
    defer init.gpa.free(app);

    var app_seed: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(
        &app_seed,
        "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60",
    );
    const app_pair = try Ed25519.KeyPair.generateDeterministic(app_seed);
    const root_pair = try Ed25519.KeyPair.generateDeterministic(@splat(0x31));
    const keys = [_]snapshot.KeyRecord{.{
        .publisher_id = "nihos.dev/system".*,
        .key_id = "rfc8032-vector01".*,
        .algorithm = package_ed25519.algorithm_id,
        .status = .trusted,
        .public_key_bytes = Ed25519.PublicKey.encoded_length,
        .public_key = padded(app_pair.public_key.toBytes()),
    }};
    const rollback = [_]snapshot.RollbackRecord{.{
        .publisher_id = "nihos.dev/system".*,
        .module_id = "nihos-rust-wasm1".*,
        .minimum_sequence = 1,
    }};
    var snapshot_buffer: [max_snapshot]u8 = undefined;
    const prepared = try snapshot.prepare(&snapshot_buffer, .{
        .algorithm = snapshot_ed25519.algorithm_id,
        .signature_bytes = Ed25519.Signature.encoded_length,
        .epoch = 1,
        .root_key_id = "root-test-key-01".*,
        .authority = .normal,
        .keys = &keys,
        .rollback = &rollback,
    });
    const root_signature = try root_pair.sign(prepared.signed_bytes, null);
    @memcpy(prepared.signature, &root_signature.toBytes());

    var root_records = [_]snapshot_ed25519.RootRecord{.{
        .root_key_id = "root-test-key-01".*,
        .public_key = root_pair.public_key.toBytes(),
        .status = .trusted,
        .role = .normal,
    }};
    var roots = snapshot_ed25519.RootStore{
        .roots = &root_records,
        .limits = .{
            .max_snapshot_bytes = max_snapshot,
            .max_signature_bytes = Ed25519.Signature.encoded_length,
            .max_keys = 8,
            .max_rollback = 8,
        },
    };
    var trust_image: [trust_bytes]u8 = @splat(0xff);
    var trust_memory = Memory{ .bytes = &trust_image };
    var counter = Counter{};
    var snapshot_scratch: [max_snapshot]u8 = undefined;
    _ = try snapshot_store.update(
        trust_memory.trust(),
        counter.interface(),
        try roots.authenticator(),
        trust_layout,
        prepared.snapshot,
        &snapshot_scratch,
    );

    const parsed = roots.verify(prepared.snapshot) orelse return error.InvalidSnapshot;
    var package_keys: [8]package_ed25519.KeyRecord = undefined;
    var package_rollback: [8]package_ed25519.RollbackRecord = undefined;
    var package_trust = try snapshot_ed25519.decodePackageStore(
        parsed,
        &package_keys,
        &package_rollback,
    );
    var package_image: [package_bytes]u8 = @splat(0xff);
    var package_memory = Memory{ .bytes = &package_image };
    var package_scratch: [max_package]u8 = undefined;
    _ = try install.install(package_memory.packages(), package_layout, app, .{
        .trust_epoch = 1,
        .max_signature_bytes = Ed25519.Signature.encoded_length,
        .trust = try package_trust.trustProvider(),
        .limits = .{
            .granted_services = policy.Service.graphics,
            .max_linear_pages = 1,
            .max_instruction_budget = 10_000,
            .max_wasm_bytes = max_package,
        },
    }, &package_scratch);

    var counter_bytes: [8]u8 = undefined;
    for (0..8) |index| counter_bytes[index] = @truncate(counter.floor >> @intCast(index * 8));
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = args[2], .data = &trust_image });
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = args[3], .data = &package_image });
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = args[4], .data = &counter_bytes });
    try std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = args[5],
        .data = &root_pair.public_key.toBytes(),
    });
}
