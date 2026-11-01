const std = @import("std");
const package = @import("app_package");
const ed25519 = @import("package_ed25519");
const installer = @import("app_install");
const policy = @import("app_policy");

const wasm = @import("wasm_blob").bytes;
const publisher_id = "nihos.dev/system".*;
const module_id = "nihos-rust-wasm1".*;
const key_id = "rfc8032-vector01".*;

const TestStorage = struct {
    const bytes = 2 * (4096 + installer.record_bytes);
    data: [bytes]u8 = @splat(0xff),

    fn interface(self: *TestStorage) installer.Storage {
        return .{
            .context = self,
            .bytes = self.data.len,
            .readAt = readAt,
            .writeAt = writeAt,
            .sync = sync,
        };
    }

    fn readAt(context: *anyopaque, offset: usize, output: []u8) installer.IoError!void {
        const self: *TestStorage = @ptrCast(@alignCast(context));
        const end = std.math.add(usize, offset, output.len) catch return error.Io;
        if (end > self.data.len) return error.Io;
        @memcpy(output, self.data[offset..end]);
    }

    fn writeAt(context: *anyopaque, offset: usize, input: []const u8) installer.IoError!void {
        const self: *TestStorage = @ptrCast(@alignCast(context));
        const end = std.math.add(usize, offset, input.len) catch return error.Io;
        if (end > self.data.len) return error.Io;
        @memcpy(self.data[offset..end], input);
    }

    fn sync(_: *anyopaque) installer.IoError!void {}
};

fn limits() policy.Limits {
    return .{
        .granted_services = policy.Service.graphics,
        .max_linear_pages = 1,
        .max_instruction_budget = 10_000,
        .max_wasm_bytes = 4096,
    };
}

test "actual Rust Wasm signs parses and authenticates as one canonical package" {
    const t = std.testing;
    const Ed25519 = std.crypto.sign.Ed25519;
    var seed: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(
        &seed,
        "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60",
    );
    const key_pair = try Ed25519.KeyPair.generateDeterministic(seed);
    var expected_public: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(
        &expected_public,
        "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a",
    );
    try t.expectEqualSlices(u8, &expected_public, &key_pair.public_key.toBytes());

    var bytes: [4096]u8 = undefined;
    const prepared = try package.prepare(&bytes, .{
        .algorithm = ed25519.algorithm_id,
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
        .key_id = key_id,
        .wasm = wasm,
    });
    const signature = try key_pair.sign(prepared.signed_bytes, null);
    @memcpy(prepared.signature, &signature.toBytes());
    const envelope = try package.parse(prepared.package, .{
        .max_package_bytes = bytes.len,
        .max_signature_bytes = Ed25519.Signature.encoded_length,
    });

    var keys = [_]ed25519.KeyRecord{.{
        .publisher_id = publisher_id,
        .key_id = key_id,
        .public_key = key_pair.public_key.toBytes(),
        .status = .trusted,
    }};
    var rollback = [_]ed25519.RollbackRecord{.{
        .publisher_id = publisher_id,
        .module_id = module_id,
        .minimum_sequence = 1,
    }};
    var store = ed25519.Store{ .keys = &keys, .rollback = &rollback };
    const provider = try store.trustProvider();
    var result = package.admit(envelope, provider, limits());
    try t.expect(result.accepted());
    try t.expectEqual(policy.Attestation.verified, result.manifest.attestation);
    try t.expectEqualSlices(u8, wasm, envelope.wasm);

    var package_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(prepared.package, &package_digest, .{});
    const digest_hex = std.fmt.bytesToHex(package_digest, .lower);
    std.debug.print(
        "NIHOS_PACKAGE_ED25519 bytes={d} wasm={d} sha256={s}\n",
        .{ prepared.package.len, wasm.len, &digest_hex },
    );

    var install_storage = TestStorage{};
    var install_scratch: [4096]u8 = undefined;
    const layout = installer.Layout{ .max_package_bytes = install_scratch.len };
    const verification = installer.Verification{
        .trust_epoch = 1,
        .max_signature_bytes = Ed25519.Signature.encoded_length,
        .trust = provider,
        .limits = limits(),
    };
    const installed = try installer.install(
        install_storage.interface(),
        layout,
        prepared.package,
        verification,
        &install_scratch,
    );
    try t.expectEqual(@as(u64, 1), installed.state.sequence);
    const recovered = (try installer.recover(
        install_storage.interface(),
        layout,
        verification,
        &install_scratch,
    )).?;
    const stored = try installer.readInstalled(
        install_storage.interface(),
        layout,
        recovered,
        &install_scratch,
    );
    try t.expectEqualSlices(u8, prepared.package, stored);
    std.debug.print(
        "NIHOS_PACKAGE_INSTALL_ED25519 sequence={d} trust_epoch={d} readback=exact\n",
        .{ recovered.sequence, recovered.trust_epoch },
    );

    prepared.signature[0] ^= 1;
    const bad_signature = try package.parse(prepared.package, .{
        .max_package_bytes = bytes.len,
        .max_signature_bytes = Ed25519.Signature.encoded_length,
    });
    result = package.admit(bad_signature, provider, limits());
    try t.expectEqual(package.TrustDecision.bad_signature, result.trust);
    prepared.signature[0] ^= 1;

    bytes[package.header_bytes] ^= 1;
    const bad_payload = try package.parse(prepared.package, .{
        .max_package_bytes = bytes.len,
        .max_signature_bytes = Ed25519.Signature.encoded_length,
    });
    result = package.admit(bad_payload, provider, limits());
    try t.expectEqual(package.TrustDecision.bad_signature, result.trust);
    bytes[package.header_bytes] ^= 1;

    keys[0].public_key[0] ^= 1;
    result = package.admit(envelope, provider, limits());
    try t.expectEqual(package.TrustDecision.bad_signature, result.trust);
    keys[0].public_key[0] ^= 1;
    keys[0].key_id[0] ^= 1;
    result = package.admit(envelope, provider, limits());
    try t.expectEqual(package.TrustDecision.unknown_key, result.trust);
    keys[0].key_id[0] ^= 1;
    keys[0].status = .revoked;
    result = package.admit(envelope, provider, limits());
    try t.expectEqual(package.TrustDecision.revoked_key, result.trust);
    keys[0].status = .trusted;
    rollback[0].minimum_sequence = 2;
    result = package.admit(envelope, provider, limits());
    try t.expectEqual(package.TrustDecision.rollback, result.trust);
}
