const std = @import("std");
pub const panic = std.debug.no_panic;
const K = std.crypto.kem.ml_kem.MLKem768;
pub export fn pqc_keygen(seed: *const [K.seed_length]u8, pk: *[K.PublicKey.encoded_length]u8, sk: *[K.SecretKey.encoded_length]u8) callconv(.c) u32 {
    const pair = K.KeyPair.generateDeterministic(seed.*) catch return 1;
    pk.* = pair.public_key.toBytes();
    sk.* = pair.secret_key.toBytes();
    return 0;
}
