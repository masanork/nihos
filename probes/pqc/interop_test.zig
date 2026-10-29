const std = @import("std");
const D = std.crypto.sign.mldsa.MLDSA65;
const K = std.crypto.kem.ml_kem.MLKem768;
extern fn PQCP_MLDSA_NATIVE_MLDSA65_verify([*]const u8, [*]const u8, usize, [*]const u8, usize, [*]const u8) c_int;
extern fn PQCP_MLKEM_NATIVE_MLKEM768_keypair_derand([*]u8, [*]u8, [*]const u8) c_int;
extern fn PQCP_MLKEM_NATIVE_MLKEM768_enc_derand([*]u8, [*]u8, [*]const u8, [*]const u8) c_int;
extern fn PQCP_MLKEM_NATIVE_MLKEM768_dec([*]u8, [*]const u8, [*]const u8) c_int;

test "Zig and PQ Code Package interoperability" {
    const msg = "nihos pqc interop";
    const keys = try D.KeyPair.generateDeterministic(@splat(0x18));
    const sig = try keys.sign(msg, null);
    const pk = keys.public_key.toBytes();
    const signature = sig.toBytes();
    try std.testing.expectEqual(0, PQCP_MLDSA_NATIVE_MLDSA65_verify(&signature, msg, msg.len, "", 0, &pk));
    try std.testing.expect(PQCP_MLDSA_NATIVE_MLDSA65_verify(&signature, "Nihos pqc interop", msg.len, "", 0, &pk) != 0);
    var c_pk: [K.PublicKey.encoded_length]u8 = undefined;
    var c_sk: [K.SecretKey.encoded_length]u8 = undefined;
    const seed: [K.seed_length]u8 = @splat(0x42);
    try std.testing.expectEqual(0, PQCP_MLKEM_NATIVE_MLKEM768_keypair_derand(&c_pk, &c_sk, &seed));
    const zkeys = try K.KeyPair.generateDeterministic(seed);
    try std.testing.expectEqualSlices(u8, &c_pk, &zkeys.public_key.toBytes());
    try std.testing.expectEqualSlices(u8, &c_sk, &zkeys.secret_key.toBytes());
    var ct: [K.ciphertext_length]u8 = undefined;
    var shared: [K.shared_length]u8 = undefined;
    const coins: [K.encaps_seed_length]u8 = @splat(0x24);
    try std.testing.expectEqual(0, PQCP_MLKEM_NATIVE_MLKEM768_enc_derand(&ct, &shared, &c_pk, &coins));
    const zout = zkeys.public_key.encapsDeterministic(&coins);
    try std.testing.expectEqualSlices(u8, &ct, &zout.ciphertext);
    try std.testing.expectEqualSlices(u8, &shared, &zout.shared_secret);
    const recovered = try zkeys.secret_key.decaps(&ct);
    try std.testing.expectEqualSlices(u8, &shared, &recovered);
    var c_shared: [K.shared_length]u8 = undefined;
    try std.testing.expectEqual(0, PQCP_MLKEM_NATIVE_MLKEM768_dec(&c_shared, &zout.ciphertext, &c_sk));
    try std.testing.expectEqualSlices(u8, &zout.shared_secret, &c_shared);
}
