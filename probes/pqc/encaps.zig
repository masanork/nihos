const std = @import("std");
pub const panic = std.debug.no_panic;
const K = std.crypto.kem.ml_kem.MLKem768;
pub export fn pqc_encaps(pk_bytes: *const [K.PublicKey.encoded_length]u8, seed: *const [K.encaps_seed_length]u8, ct: *[K.ciphertext_length]u8, ss: *[K.shared_length]u8) callconv(.c) u32 {
    const pk = K.PublicKey.fromBytes(pk_bytes) catch return 1;
    const out = pk.encapsDeterministic(seed);
    ct.* = out.ciphertext;
    ss.* = out.shared_secret;
    return 0;
}
