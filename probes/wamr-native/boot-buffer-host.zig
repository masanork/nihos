//! Host fixture: immutable journal snapshots -> admitted private Wasm buffer.
const std = @import("std");
const boot = @import("app_boot");
const package = @import("app_package");
const keys = @import("package_ed25519");
const policy = @import("app_policy");
const roots_module = @import("trust_snapshot_ed25519");
const trust_store = @import("trust_snapshot_store");

const ReadOnly = struct {
    bytes: []const u8,
    fn read(context: *anyopaque, offset: usize, output: []u8) trust_store.IoError!void {
        const self: *ReadOnly = @ptrCast(@alignCast(context));
        const end = std.math.add(usize, offset, output.len) catch return error.Io;
        if (end > self.bytes.len) return error.Io;
        @memcpy(output, self.bytes[offset..end]);
    }
    fn write(_: *anyopaque, _: usize, _: []const u8) trust_store.IoError!void {
        return error.Io;
    }
    fn sync(_: *anyopaque) trust_store.IoError!void {
        return error.Io;
    }
};

const Counter = struct {
    floor: u64,
    fn read(context: *anyopaque) trust_store.IoError!u64 {
        const self: *Counter = @ptrCast(@alignCast(context));
        return self.floor;
    }
    // This read-only load fixture requires the persisted counter already
    // sealed. Repairs belong to the separately tested writable file owner.
    fn advance(_: *anyopaque, _: u64) trust_store.IoError!void {
        return error.Io;
    }
};

export fn nih_boot_buffer_admit(
    trust_ptr: [*]const u8,
    trust_len: usize,
    counter_ptr: [*]const u8,
    counter_len: usize,
    package_ptr: [*]const u8,
    package_len: usize,
    root_ptr: [*]const u8,
    root_len: usize,
    granted_services: u32,
    output: [*]u8,
    capacity: usize,
    output_len: *u32,
    effective_services: *u32,
) callconv(.c) c_int {
    output_len.* = 0;
    effective_services.* = 0;
    if (trust_len != 1216 or counter_len != 8 or package_len != 8480 or
        root_len != 32 or capacity < 4096 or granted_services & ~policy.Service.known != 0) return 1;
    var trust = ReadOnly{ .bytes = trust_ptr[0..trust_len] };
    var packages = ReadOnly{ .bytes = package_ptr[0..package_len] };
    var floor: u64 = 0;
    for (0..8) |i| floor |= @as(u64, counter_ptr[i]) << @intCast(i * 8);
    var counter = Counter{ .floor = floor };
    var root_records = [_]roots_module.RootRecord{.{
        .root_key_id = "root-test-key-01".*,
        .public_key = root_ptr[0..32].*,
        .status = .trusted,
        .role = .normal,
    }};
    var roots = roots_module.RootStore{ .roots = &root_records, .limits = .{
        .max_snapshot_bytes = 512,
        .max_signature_bytes = 64,
        .max_keys = 8,
        .max_rollback = 8,
    } };
    var snapshot_scratch: [512]u8 = undefined;
    var package_scratch: [4096]u8 = undefined;
    var package_keys: [8]keys.KeyRecord = undefined;
    var rollback: [8]keys.RollbackRecord = undefined;
    var coordinator = boot.Coordinator{};
    const result = coordinator.recover(.{
        .trust_storage = .{ .context = &trust, .bytes = trust_len, .readAt = ReadOnly.read, .writeAt = ReadOnly.write, .sync = ReadOnly.sync },
        .monotonic = .{ .context = &counter, .read = Counter.read, .advance = Counter.advance },
        .trust_layout = .{ .max_snapshot_bytes = 512 },
        .roots = &roots,
        .package_storage = .{ .context = &packages, .bytes = package_len, .readAt = ReadOnly.read, .writeAt = ReadOnly.write, .sync = ReadOnly.sync },
        .package_layout = .{ .max_package_bytes = 4096 },
        .max_signature_bytes = 64,
        .limits = .{ .granted_services = granted_services, .max_linear_pages = 1, .max_instruction_budget = 10_000, .max_wasm_bytes = 4096 },
    }, .{ .snapshot_bytes = &snapshot_scratch, .package_bytes = &package_scratch, .package_keys = &package_keys, .rollback = &rollback }) catch return 2;
    const ready = switch (result) {
        .ready => |value| value,
        else => return 3,
    };
    const envelope = package.parse(ready.package_bytes, .{ .max_package_bytes = 4096, .max_signature_bytes = 64 }) catch return 4;
    @memcpy(output[0..envelope.wasm.len], envelope.wasm);
    output_len.* = @intCast(envelope.wasm.len);
    effective_services.* = envelope.services;
    return 0;
}
