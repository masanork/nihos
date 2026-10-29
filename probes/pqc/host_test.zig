const std = @import("std");
const D = std.crypto.sign.mldsa.MLDSA65;
const K = std.crypto.kem.ml_kem.MLKem768;
const verify = @import("verify.zig").pqc_verify;
const keygen = @import("keygen.zig").pqc_keygen;
const encaps = @import("encaps.zig").pqc_encaps;
const decaps = @import("decaps.zig").pqc_decaps;

test "isolated operations interoperate and reject tampering" {
    var pk: [K.PublicKey.encoded_length]u8 = undefined;
    var sk: [K.SecretKey.encoded_length]u8 = undefined;
    var ct: [K.ciphertext_length]u8 = undefined;
    var a: [K.shared_length]u8 = undefined;
    var b: [K.shared_length]u8 = undefined;
    try std.testing.expectEqual(0, keygen(&@splat(0x42), &pk, &sk));
    try std.testing.expectEqual(0, encaps(&pk, &@splat(0x24), &ct, &a));
    try std.testing.expectEqual(0, decaps(&sk, &ct, &b));
    try std.testing.expectEqualSlices(u8, &a, &b);
    ct[0] ^= 1;
    try std.testing.expectEqual(0, decaps(&sk, &ct, &b));
    try std.testing.expect(!std.mem.eql(u8, &a, &b));
    const pair = try D.KeyPair.generateDeterministic(@splat(0x18));
    const sig = try pair.sign("pqc probe", null);
    const dpk = pair.public_key.toBytes();
    const dsig = sig.toBytes();
    try std.testing.expectEqual(0, verify(&dpk, &dsig, "pqc probe", 9));
    try std.testing.expect(verify(&dpk, &dsig, "Pqc probe", 9) != 0);
}
