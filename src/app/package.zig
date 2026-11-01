//! Canonical signed-package framing for nihos Wasm applications.
//!
//! This module deliberately does not choose a signature algorithm or key store.
//! It defines the exact signed bytes, parses them without alternate encodings,
//! and is the only package path that promotes an attestation to `verified`.
const std = @import("std");
const policy = @import("app_policy");

pub const magic = "NIHPKG01".*;
pub const format_version: u16 = 1;
pub const header_bytes: u16 = 144;

const Offset = struct {
    const magic = 0;
    const format = 8;
    const header = 10;
    const algorithm = 12;
    const signature_bytes = 14;
    const package_bytes = 16;
    const wasm_bytes = 20;
    const sequence = 24;
    const schema = 32;
    const sdk_abi = 34;
    const module_id = 36;
    const publisher_id = 52;
    const version = 68;
    const services = 72;
    const linear_pages = 76;
    const reserved_word = 78;
    const instruction_budget = 80;
    const wasm_sha256 = 84;
    const key_id = 116;
    const reserved = 132;
};

pub const ParseLimits = struct {
    max_package_bytes: u32,
    max_signature_bytes: u16,
};

pub const BuildInput = struct {
    algorithm: u16,
    signature_bytes: u16,
    sequence: u64,
    schema: u16,
    sdk_abi: u16,
    module_id: [16]u8,
    publisher_id: [16]u8,
    version: u32,
    services: u32,
    max_linear_pages: u16,
    instruction_budget: u32,
    key_id: [16]u8,
    wasm: []const u8,
};

pub const Prepared = struct {
    package: []u8,
    signed_bytes: []u8,
    signature: []u8,
};

pub const BuildError = error{
    ZeroPayload,
    ZeroSignature,
    ZeroSequence,
    PackageTooLarge,
    LengthOverflow,
    OutputTooSmall,
};

/// Build the canonical signed region and reserve the exact trailing signature
/// slice. The caller signs `signed_bytes`, fills `signature`, then persists only
/// `package`. Secret-key handling deliberately remains outside this module.
pub fn prepare(output: []u8, input: BuildInput) BuildError!Prepared {
    if (input.wasm.len == 0) return error.ZeroPayload;
    if (input.signature_bytes == 0) return error.ZeroSignature;
    if (input.sequence == 0) return error.ZeroSequence;
    const wasm_length = std.math.cast(u32, input.wasm.len) orelse return error.PackageTooLarge;
    const signed_length = std.math.add(usize, header_bytes, input.wasm.len) catch
        return error.LengthOverflow;
    const total_length = std.math.add(usize, signed_length, input.signature_bytes) catch
        return error.LengthOverflow;
    const package_length = std.math.cast(u32, total_length) orelse return error.PackageTooLarge;
    if (output.len < total_length) return error.OutputTooSmall;

    @memset(output[0..header_bytes], 0);
    @memcpy(output[Offset.magic..Offset.format], &magic);
    write16(output, Offset.format, format_version);
    write16(output, Offset.header, header_bytes);
    write16(output, Offset.algorithm, input.algorithm);
    write16(output, Offset.signature_bytes, input.signature_bytes);
    write32(output, Offset.package_bytes, package_length);
    write32(output, Offset.wasm_bytes, wasm_length);
    write64(output, Offset.sequence, input.sequence);
    write16(output, Offset.schema, input.schema);
    write16(output, Offset.sdk_abi, input.sdk_abi);
    @memcpy(output[Offset.module_id..Offset.publisher_id], &input.module_id);
    @memcpy(output[Offset.publisher_id..Offset.version], &input.publisher_id);
    write32(output, Offset.version, input.version);
    write32(output, Offset.services, input.services);
    write16(output, Offset.linear_pages, input.max_linear_pages);
    write32(output, Offset.instruction_budget, input.instruction_budget);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(input.wasm, &digest, .{});
    @memcpy(output[Offset.wasm_sha256..Offset.key_id], &digest);
    @memcpy(output[Offset.key_id..Offset.reserved], &input.key_id);
    @memcpy(output[header_bytes..signed_length], input.wasm);
    @memset(output[signed_length..total_length], 0);
    return .{
        .package = output[0..total_length],
        .signed_bytes = output[0..signed_length],
        .signature = output[signed_length..total_length],
    };
}

pub const ParseError = error{
    TooShort,
    BadMagic,
    BadFormat,
    BadHeaderSize,
    ReservedNonzero,
    ZeroPayload,
    ZeroSignature,
    ZeroSequence,
    PackageTooLarge,
    SignatureTooLarge,
    LengthOverflow,
    LengthMismatch,
};

pub const Envelope = struct {
    algorithm: u16,
    sequence: u64,
    schema: u16,
    sdk_abi: u16,
    module_id: [16]u8,
    publisher_id: [16]u8,
    version: u32,
    services: u32,
    max_linear_pages: u16,
    instruction_budget: u32,
    wasm_sha256: [32]u8,
    key_id: [16]u8,
    signed_bytes: []const u8,
    wasm: []const u8,
    signature: []const u8,
};

pub fn parse(bytes: []const u8, limits: ParseLimits) ParseError!Envelope {
    if (bytes.len < header_bytes) return error.TooShort;
    if (!std.mem.eql(u8, bytes[Offset.magic..Offset.format], &magic)) return error.BadMagic;
    if (read16(bytes, Offset.format) != format_version) return error.BadFormat;
    if (read16(bytes, Offset.header) != header_bytes) return error.BadHeaderSize;
    if (read16(bytes, Offset.reserved_word) != 0 or !allZero(bytes[Offset.reserved..header_bytes]))
        return error.ReservedNonzero;

    const declared_package = read32(bytes, Offset.package_bytes);
    const wasm_length = read32(bytes, Offset.wasm_bytes);
    const signature_length = read16(bytes, Offset.signature_bytes);
    if (wasm_length == 0) return error.ZeroPayload;
    if (signature_length == 0) return error.ZeroSignature;
    if (read64(bytes, Offset.sequence) == 0) return error.ZeroSequence;
    if (declared_package > limits.max_package_bytes) return error.PackageTooLarge;
    if (signature_length > limits.max_signature_bytes) return error.SignatureTooLarge;

    const signed_length = std.math.add(usize, header_bytes, wasm_length) catch
        return error.LengthOverflow;
    const total_length = std.math.add(usize, signed_length, signature_length) catch
        return error.LengthOverflow;
    if (declared_package != total_length or bytes.len != total_length)
        return error.LengthMismatch;

    return .{
        .algorithm = read16(bytes, Offset.algorithm),
        .sequence = read64(bytes, Offset.sequence),
        .schema = read16(bytes, Offset.schema),
        .sdk_abi = read16(bytes, Offset.sdk_abi),
        .module_id = bytes[Offset.module_id..Offset.publisher_id].*,
        .publisher_id = bytes[Offset.publisher_id..Offset.version].*,
        .version = read32(bytes, Offset.version),
        .services = read32(bytes, Offset.services),
        .max_linear_pages = read16(bytes, Offset.linear_pages),
        .instruction_budget = read32(bytes, Offset.instruction_budget),
        .wasm_sha256 = bytes[Offset.wasm_sha256..Offset.key_id].*,
        .key_id = bytes[Offset.key_id..Offset.reserved].*,
        .signed_bytes = bytes[0..signed_length],
        .wasm = bytes[header_bytes..signed_length],
        .signature = bytes[signed_length..total_length],
    };
}

pub const KeyStatus = enum { trusted, unknown, revoked };
pub const SignatureStatus = enum { verified, unsupported_algorithm, invalid };

pub const TrustProvider = struct {
    context: *anyopaque,
    keyStatus: *const fn (*anyopaque, [16]u8, [16]u8) KeyStatus,
    minimumSequence: *const fn (*anyopaque, [16]u8, [16]u8) u64,
    verifySignature: *const fn (*anyopaque, u16, [16]u8, [16]u8, []const u8, []const u8) SignatureStatus,
};

pub const TrustDecision = enum(u32) {
    accepted = 0,
    unknown_key,
    revoked_key,
    rollback,
    unsupported_algorithm,
    bad_signature,
};

pub const Admission = struct {
    trust: TrustDecision,
    policy_decision: policy.Decision,
    manifest: policy.Manifest,

    pub fn accepted(self: Admission) bool {
        return self.trust == .accepted and self.policy_decision == .accepted;
    }
};

/// Authenticate the canonical envelope, then apply the normal app policy.
/// `minimumSequence` is inclusive so the currently installed version may run;
/// a lower sequence is a rollback. Persistence/commit of a newer sequence is
/// owned by the installer, not by this read-only decision function.
pub fn admit(envelope: Envelope, trust: TrustProvider, limits: policy.Limits) Admission {
    var trust_decision: TrustDecision = switch (trust.keyStatus(
        trust.context,
        envelope.publisher_id,
        envelope.key_id,
    )) {
        .trusted => .accepted,
        .unknown => .unknown_key,
        .revoked => .revoked_key,
    };
    if (trust_decision == .accepted and envelope.sequence < trust.minimumSequence(
        trust.context,
        envelope.publisher_id,
        envelope.module_id,
    )) trust_decision = .rollback;
    if (trust_decision == .accepted) {
        trust_decision = switch (trust.verifySignature(
            trust.context,
            envelope.algorithm,
            envelope.publisher_id,
            envelope.key_id,
            envelope.signed_bytes,
            envelope.signature,
        )) {
            .verified => .accepted,
            .unsupported_algorithm => .unsupported_algorithm,
            .invalid => .bad_signature,
        };
    }

    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(envelope.wasm, &digest, .{});
    const manifest = policy.Manifest{
        .schema = envelope.schema,
        .sdk_abi = envelope.sdk_abi,
        .module_id = envelope.module_id,
        .publisher_id = envelope.publisher_id,
        .version = envelope.version,
        .services = envelope.services,
        .max_linear_pages = envelope.max_linear_pages,
        .instruction_budget = envelope.instruction_budget,
        .wasm_bytes = @intCast(envelope.wasm.len),
        .wasm_sha256 = envelope.wasm_sha256,
        .origin = .signed_package,
        .attestation = if (trust_decision == .accepted) .verified else .invalid,
    };
    return .{
        .trust = trust_decision,
        .policy_decision = policy.evaluate(manifest, digest, envelope.wasm.len, limits),
        .manifest = manifest,
    };
}

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}

fn read16(bytes: []const u8, offset: usize) u16 {
    return @as(u16, bytes[offset]) | (@as(u16, bytes[offset + 1]) << 8);
}

fn read32(bytes: []const u8, offset: usize) u32 {
    return @as(u32, bytes[offset]) |
        (@as(u32, bytes[offset + 1]) << 8) |
        (@as(u32, bytes[offset + 2]) << 16) |
        (@as(u32, bytes[offset + 3]) << 24);
}

fn read64(bytes: []const u8, offset: usize) u64 {
    return @as(u64, read32(bytes, offset)) | (@as(u64, read32(bytes, offset + 4)) << 32);
}

const TestPackage = struct {
    bytes: [512]u8 = @splat(0),
    length: usize = 0,

    fn slice(self: *TestPackage) []u8 {
        return self.bytes[0..self.length];
    }
};

fn testPackage() TestPackage {
    const wasm = [_]u8{ 0x00, 0x61, 0x73, 0x6d };
    var result = TestPackage{};
    const prepared = prepare(&result.bytes, .{
        .algorithm = 7,
        .signature_bytes = 64,
        .sequence = 9,
        .schema = policy.current_schema,
        .sdk_abi = policy.current_sdk_abi,
        .module_id = "nihos-rust-wasm1".*,
        .publisher_id = "nihos.dev/system".*,
        .version = 1,
        .services = policy.Service.graphics,
        .max_linear_pages = 1,
        .instruction_budget = 10_000,
        .key_id = "publisher-key-01".*,
        .wasm = &wasm,
    }) catch @panic("invalid package test fixture");
    @memset(prepared.signature, 0xa5);
    result.length = prepared.package.len;
    return result;
}

fn testParse(bytes: []const u8) ParseError!Envelope {
    return parse(bytes, .{ .max_package_bytes = 4096, .max_signature_bytes = 512 });
}

fn write16(bytes: []u8, offset: usize, value: anytype) void {
    const cast: u16 = @intCast(value);
    bytes[offset] = @truncate(cast);
    bytes[offset + 1] = @truncate(cast >> 8);
}

fn write32(bytes: []u8, offset: usize, value: anytype) void {
    const cast: u32 = @intCast(value);
    bytes[offset] = @truncate(cast);
    bytes[offset + 1] = @truncate(cast >> 8);
    bytes[offset + 2] = @truncate(cast >> 16);
    bytes[offset + 3] = @truncate(cast >> 24);
}

fn write64(bytes: []u8, offset: usize, value: u64) void {
    write32(bytes, offset, @as(u32, @truncate(value)));
    write32(bytes, offset + 4, @as(u32, @truncate(value >> 32)));
}

test "canonical envelope exposes one exact signed region" {
    const t = std.testing;
    var package = testPackage();
    const envelope = try testParse(package.slice());
    try t.expectEqual(@as(u16, 7), envelope.algorithm);
    try t.expectEqual(@as(u64, 9), envelope.sequence);
    try t.expectEqual(@as(usize, header_bytes + 4), envelope.signed_bytes.len);
    try t.expectEqualSlices(u8, &.{ 0x00, 0x61, 0x73, 0x6d }, envelope.wasm);
    try t.expectEqual(@as(usize, 64), envelope.signature.len);
    try t.expectEqual(@as(u8, 0xa5), envelope.signature[0]);
    try t.expectEqualStrings("nihos-rust-wasm1", &envelope.module_id);
    try t.expectEqualStrings("publisher-key-01", &envelope.key_id);
}

test "parser rejects alternate framing and noncanonical bytes" {
    const t = std.testing;
    var package = testPackage();
    var cut: usize = 0;
    while (cut < package.length) : (cut += 1) {
        if (cut < header_bytes) {
            try t.expectError(error.TooShort, testParse(package.slice()[0..cut]));
        } else {
            try t.expectError(error.LengthMismatch, testParse(package.slice()[0..cut]));
        }
    }

    package = testPackage();
    package.bytes[0] ^= 1;
    try t.expectError(error.BadMagic, testParse(package.slice()));
    package = testPackage();
    write16(&package.bytes, Offset.format, 2);
    try t.expectError(error.BadFormat, testParse(package.slice()));
    package = testPackage();
    write16(&package.bytes, Offset.header, header_bytes + 1);
    try t.expectError(error.BadHeaderSize, testParse(package.slice()));
    package = testPackage();
    package.bytes[Offset.reserved] = 1;
    try t.expectError(error.ReservedNonzero, testParse(package.slice()));
    package = testPackage();
    write16(&package.bytes, Offset.reserved_word, 1);
    try t.expectError(error.ReservedNonzero, testParse(package.slice()));
    package = testPackage();
    write32(&package.bytes, Offset.wasm_bytes, 0);
    try t.expectError(error.ZeroPayload, testParse(package.slice()));
    package = testPackage();
    write16(&package.bytes, Offset.signature_bytes, 0);
    try t.expectError(error.ZeroSignature, testParse(package.slice()));
    package = testPackage();
    write64(&package.bytes, Offset.sequence, 0);
    try t.expectError(error.ZeroSequence, testParse(package.slice()));
    package = testPackage();
    try t.expectError(error.PackageTooLarge, parse(package.slice(), .{
        .max_package_bytes = 100,
        .max_signature_bytes = 512,
    }));
    try t.expectError(error.SignatureTooLarge, parse(package.slice(), .{
        .max_package_bytes = 4096,
        .max_signature_bytes = 32,
    }));
    package = testPackage();
    package.length += 1;
    try t.expectError(error.LengthMismatch, testParse(package.slice()));
}

const MockTrust = struct {
    key_status: KeyStatus = .trusted,
    minimum_sequence: u64 = 9,
    signature_status: SignatureStatus = .verified,
    verify_calls: u32 = 0,
    saw_exact_message: bool = false,
    expected_message: usize = 0,
    expected_message_bytes: usize = 0,
};

fn mockProvider(mock: *MockTrust) TrustProvider {
    return .{
        .context = mock,
        .keyStatus = mockKeyStatus,
        .minimumSequence = mockMinimumSequence,
        .verifySignature = mockVerifySignature,
    };
}

fn mockKeyStatus(context: *anyopaque, publisher: [16]u8, key: [16]u8) KeyStatus {
    const mock: *MockTrust = @ptrCast(@alignCast(context));
    std.debug.assert(std.mem.eql(u8, &publisher, "nihos.dev/system"));
    std.debug.assert(std.mem.eql(u8, &key, "publisher-key-01"));
    return mock.key_status;
}

fn mockMinimumSequence(context: *anyopaque, publisher: [16]u8, module: [16]u8) u64 {
    const mock: *MockTrust = @ptrCast(@alignCast(context));
    std.debug.assert(std.mem.eql(u8, &publisher, "nihos.dev/system"));
    std.debug.assert(std.mem.eql(u8, &module, "nihos-rust-wasm1"));
    return mock.minimum_sequence;
}

fn mockVerifySignature(
    context: *anyopaque,
    algorithm: u16,
    publisher: [16]u8,
    key: [16]u8,
    message: []const u8,
    signature: []const u8,
) SignatureStatus {
    const mock: *MockTrust = @ptrCast(@alignCast(context));
    mock.verify_calls += 1;
    mock.saw_exact_message = algorithm == 7 and
        std.mem.eql(u8, &publisher, "nihos.dev/system") and
        std.mem.eql(u8, &key, "publisher-key-01") and
        @intFromPtr(message.ptr) == mock.expected_message and
        message.len == mock.expected_message_bytes and
        message.len == header_bytes + 4 and
        signature.len == 64 and
        signature[0] == 0xa5;
    return mock.signature_status;
}

fn testPolicyLimits() policy.Limits {
    return .{
        .granted_services = policy.Service.graphics,
        .max_linear_pages = 1,
        .max_instruction_budget = 10_000,
        .max_wasm_bytes = 4096,
    };
}

test "only trust provider success promotes a signed package to verified" {
    const t = std.testing;
    var package = testPackage();
    const envelope = try testParse(package.slice());
    var mock = MockTrust{
        .expected_message = @intFromPtr(envelope.signed_bytes.ptr),
        .expected_message_bytes = envelope.signed_bytes.len,
    };
    const result = admit(envelope, mockProvider(&mock), testPolicyLimits());
    try t.expect(result.accepted());
    try t.expectEqual(TrustDecision.accepted, result.trust);
    try t.expectEqual(policy.Decision.accepted, result.policy_decision);
    try t.expectEqual(policy.Origin.signed_package, result.manifest.origin);
    try t.expectEqual(policy.Attestation.verified, result.manifest.attestation);
    try t.expectEqual(@as(u32, 1), mock.verify_calls);
    try t.expect(mock.saw_exact_message);
}

test "key lifecycle rollback signature and app policy reject independently" {
    const t = std.testing;
    var package = testPackage();
    var envelope = try testParse(package.slice());
    var mock = MockTrust{ .key_status = .unknown };
    var result = admit(envelope, mockProvider(&mock), testPolicyLimits());
    try t.expectEqual(TrustDecision.unknown_key, result.trust);
    try t.expectEqual(@as(u32, 0), mock.verify_calls);
    try t.expectEqual(policy.Attestation.invalid, result.manifest.attestation);

    mock = .{ .key_status = .revoked };
    result = admit(envelope, mockProvider(&mock), testPolicyLimits());
    try t.expectEqual(TrustDecision.revoked_key, result.trust);
    try t.expectEqual(@as(u32, 0), mock.verify_calls);
    mock = .{ .minimum_sequence = 10 };
    result = admit(envelope, mockProvider(&mock), testPolicyLimits());
    try t.expectEqual(TrustDecision.rollback, result.trust);
    try t.expectEqual(@as(u32, 0), mock.verify_calls);
    mock = .{ .signature_status = .unsupported_algorithm };
    result = admit(envelope, mockProvider(&mock), testPolicyLimits());
    try t.expectEqual(TrustDecision.unsupported_algorithm, result.trust);
    mock = .{ .signature_status = .invalid };
    result = admit(envelope, mockProvider(&mock), testPolicyLimits());
    try t.expectEqual(TrustDecision.bad_signature, result.trust);

    mock = .{};
    var denied = testPolicyLimits();
    denied.granted_services = 0;
    result = admit(envelope, mockProvider(&mock), denied);
    try t.expectEqual(TrustDecision.accepted, result.trust);
    try t.expectEqual(policy.Decision.service_denied, result.policy_decision);

    package = testPackage();
    package.bytes[header_bytes] ^= 1;
    envelope = try testParse(package.slice());
    mock = .{};
    result = admit(envelope, mockProvider(&mock), testPolicyLimits());
    try t.expectEqual(TrustDecision.accepted, result.trust);
    try t.expectEqual(policy.Decision.digest_mismatch, result.policy_decision);
}
