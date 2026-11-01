//! Pure admission policy for Wasm application metadata.
//! Signature parsing/verification is deliberately outside this module: only a
//! verifier may set `verified`, while the image builder owns `image_bound`.
const std = @import("std");

pub const current_schema: u16 = 1;
pub const current_sdk_abi: u16 = 1;

pub const Service = struct {
    pub const graphics: u32 = 1 << 0;
    pub const input: u32 = 1 << 1;
    pub const clock: u32 = 1 << 2;
    pub const storage_read: u32 = 1 << 3;
    pub const storage_write: u32 = 1 << 4;
    pub const network: u32 = 1 << 5;
    pub const known: u32 = graphics | input | clock | storage_read | storage_write | network;
};

pub const Origin = enum(u8) { built_in, signed_package, developer };
pub const Attestation = enum(u8) { absent, image_bound, verified, invalid };

pub const Manifest = struct {
    schema: u16,
    sdk_abi: u16,
    module_id: [16]u8,
    publisher_id: [16]u8,
    version: u32,
    services: u32,
    max_linear_pages: u16,
    instruction_budget: u32,
    wasm_bytes: u32,
    wasm_sha256: [32]u8,
    origin: Origin,
    attestation: Attestation,
};

pub const Limits = struct {
    sdk_abi: u16 = current_sdk_abi,
    granted_services: u32,
    max_linear_pages: u16,
    max_instruction_budget: u32,
    max_wasm_bytes: u32,
    allow_developer: bool = false,
};

pub const Decision = enum(u32) {
    accepted = 0,
    bad_schema,
    bad_sdk_abi,
    bad_identity,
    unknown_service,
    service_denied,
    linear_limit,
    instruction_limit,
    size_limit,
    length_mismatch,
    digest_mismatch,
    trust_denied,
};

pub fn evaluate(manifest: Manifest, actual_digest: [32]u8, actual_bytes: usize, limits: Limits) Decision {
    if (manifest.schema != current_schema) return .bad_schema;
    if (manifest.sdk_abi != limits.sdk_abi) return .bad_sdk_abi;
    if (!nonzero(&manifest.module_id) or !nonzero(&manifest.publisher_id) or manifest.version == 0)
        return .bad_identity;
    if (manifest.services & ~Service.known != 0) return .unknown_service;
    if (manifest.services & ~limits.granted_services != 0) return .service_denied;
    if (manifest.max_linear_pages == 0 or manifest.max_linear_pages > limits.max_linear_pages)
        return .linear_limit;
    if (manifest.instruction_budget == 0 or manifest.instruction_budget > limits.max_instruction_budget)
        return .instruction_limit;
    if (actual_bytes > limits.max_wasm_bytes or manifest.wasm_bytes > limits.max_wasm_bytes)
        return .size_limit;
    if (actual_bytes != manifest.wasm_bytes) return .length_mismatch;
    if (!std.mem.eql(u8, &manifest.wasm_sha256, &actual_digest)) return .digest_mismatch;
    return switch (manifest.origin) {
        .built_in => if (manifest.attestation == .image_bound) .accepted else .trust_denied,
        .signed_package => if (manifest.attestation == .verified) .accepted else .trust_denied,
        .developer => if (limits.allow_developer and manifest.attestation == .absent) .accepted else .trust_denied,
    };
}

fn nonzero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return true;
    return false;
}

fn fixture() Manifest {
    return .{
        .schema = current_schema,
        .sdk_abi = current_sdk_abi,
        .module_id = "nihos-rust-wasm1".*,
        .publisher_id = "nihos.dev/system".*,
        .version = 1,
        .services = Service.graphics,
        .max_linear_pages = 1,
        .instruction_budget = 10_000,
        .wasm_bytes = 3,
        .wasm_sha256 = @splat(0x5a),
        .origin = .built_in,
        .attestation = .image_bound,
    };
}

fn fixtureLimits() Limits {
    return .{
        .granted_services = Service.graphics,
        .max_linear_pages = 1,
        .max_instruction_budget = 10_000,
        .max_wasm_bytes = 4096,
    };
}

test "built-in and verified package trust are explicit" {
    const t = std.testing;
    const base = fixture();
    try t.expectEqual(Decision.accepted, evaluate(base, base.wasm_sha256, 3, fixtureLimits()));
    var signed = base;
    signed.origin = .signed_package;
    signed.attestation = .verified;
    try t.expectEqual(Decision.accepted, evaluate(signed, signed.wasm_sha256, 3, fixtureLimits()));
    signed.attestation = .image_bound;
    try t.expectEqual(Decision.trust_denied, evaluate(signed, signed.wasm_sha256, 3, fixtureLimits()));
    var developer = base;
    developer.origin = .developer;
    developer.attestation = .absent;
    try t.expectEqual(Decision.trust_denied, evaluate(developer, developer.wasm_sha256, 3, fixtureLimits()));
    var development = fixtureLimits();
    development.allow_developer = true;
    try t.expectEqual(Decision.accepted, evaluate(developer, developer.wasm_sha256, 3, development));
    developer.attestation = .invalid;
    try t.expectEqual(Decision.trust_denied, evaluate(developer, developer.wasm_sha256, 3, development));
}

test "identity ABI services quotas and digest fail closed" {
    const t = std.testing;
    const base = fixture();
    var changed = base;
    changed.schema += 1;
    try t.expectEqual(Decision.bad_schema, evaluate(changed, changed.wasm_sha256, 3, fixtureLimits()));
    changed = base;
    changed.sdk_abi += 1;
    try t.expectEqual(Decision.bad_sdk_abi, evaluate(changed, changed.wasm_sha256, 3, fixtureLimits()));
    changed = base;
    changed.module_id = @splat(0);
    try t.expectEqual(Decision.bad_identity, evaluate(changed, changed.wasm_sha256, 3, fixtureLimits()));
    changed = base;
    changed.publisher_id = @splat(0);
    try t.expectEqual(Decision.bad_identity, evaluate(changed, changed.wasm_sha256, 3, fixtureLimits()));
    changed = base;
    changed.version = 0;
    try t.expectEqual(Decision.bad_identity, evaluate(changed, changed.wasm_sha256, 3, fixtureLimits()));
    changed = base;
    changed.services |= 1 << 31;
    try t.expectEqual(Decision.unknown_service, evaluate(changed, changed.wasm_sha256, 3, fixtureLimits()));
    changed = base;
    changed.services |= Service.network;
    try t.expectEqual(Decision.service_denied, evaluate(changed, changed.wasm_sha256, 3, fixtureLimits()));
    changed = base;
    changed.max_linear_pages = 2;
    try t.expectEqual(Decision.linear_limit, evaluate(changed, changed.wasm_sha256, 3, fixtureLimits()));
    changed = base;
    changed.instruction_budget = 10_001;
    try t.expectEqual(Decision.instruction_limit, evaluate(changed, changed.wasm_sha256, 3, fixtureLimits()));
    changed = base;
    changed.wasm_bytes = 4097;
    try t.expectEqual(Decision.size_limit, evaluate(changed, changed.wasm_sha256, 4097, fixtureLimits()));
    changed = base;
    changed.wasm_bytes = 4;
    try t.expectEqual(Decision.length_mismatch, evaluate(changed, changed.wasm_sha256, 3, fixtureLimits()));
    var digest = base.wasm_sha256;
    digest[0] ^= 1;
    try t.expectEqual(Decision.digest_mismatch, evaluate(base, digest, 3, fixtureLimits()));
}
