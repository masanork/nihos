//! Freestanding C ABI entry for canonical-package admission on RV32.
const std = @import("std");
const package = @import("app_package");
const ed25519 = @import("package_ed25519");
const policy = @import("app_policy");

pub const AdmissionReport = extern struct {
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
};

const public_key = [32]u8{
    0xd7, 0x5a, 0x98, 0x01, 0x82, 0xb1, 0x0a, 0xb7,
    0xd5, 0x4b, 0xfe, 0xd3, 0xc9, 0x64, 0x07, 0x3a,
    0x0e, 0xe1, 0x72, 0xf3, 0xda, 0xa6, 0x23, 0x25,
    0xaf, 0x02, 0x1a, 0x68, 0xf7, 0x07, 0x51, 0x1a,
};

export fn nih_package_ed25519_admit(
    bytes: [*]const u8,
    byte_length: u32,
    report: *AdmissionReport,
) callconv(.c) c_int {
    report.* = .{};
    const source = bytes[0..byte_length];
    const envelope = package.parse(source, .{
        .max_package_bytes = 4096,
        .max_signature_bytes = 64,
    }) catch return 1;
    var keys = [_]ed25519.KeyRecord{.{
        .publisher_id = "nihos.dev/system".*,
        .key_id = "rfc8032-vector01".*,
        .public_key = public_key,
        .status = .trusted,
    }};
    var rollback = [_]ed25519.RollbackRecord{.{
        .publisher_id = "nihos.dev/system".*,
        .module_id = "nihos-rust-wasm1".*,
        .minimum_sequence = 1,
    }};
    var store = ed25519.Store{ .keys = &keys, .rollback = &rollback };
    const provider = store.trustProvider() catch return 2;
    const admission = package.admit(envelope, provider, .{
        .granted_services = policy.Service.graphics,
        .max_linear_pages = 1,
        .max_instruction_budget = 10_000,
        .max_wasm_bytes = 4096,
        .allow_developer = false,
    });
    report.trust_status = @backingInt(admission.trust);
    report.policy_status = @backingInt(admission.policy_decision);
    report.services = admission.manifest.services;
    report.sdk_abi = admission.manifest.sdk_abi;
    report.origin = @backingInt(admission.manifest.origin);
    report.attestation = @backingInt(admission.manifest.attestation);
    report.module_tag = tag(admission.manifest.module_id[0..4].*);
    report.digest_tag = tag(admission.manifest.wasm_sha256[0..4].*);
    report.instruction_budget = admission.manifest.instruction_budget;
    report.sequence_low = @truncate(envelope.sequence);
    report.sequence_high = @truncate(envelope.sequence >> 32);
    if (!admission.accepted()) return 3;
    const offset = @intFromPtr(envelope.wasm.ptr) - @intFromPtr(bytes);
    report.wasm_offset = std.math.cast(u32, offset) orelse return 4;
    report.wasm_length = std.math.cast(u32, envelope.wasm.len) orelse return 4;
    return 0;
}

fn tag(bytes: [4]u8) u32 {
    return @as(u32, bytes[0]) |
        (@as(u32, bytes[1]) << 8) |
        (@as(u32, bytes[2]) << 16) |
        (@as(u32, bytes[3]) << 24);
}
