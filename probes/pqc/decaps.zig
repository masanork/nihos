const std = @import("std");
pub const panic = std.debug.no_panic;
const K = std.crypto.kem.ml_kem.MLKem768;
pub export fn pqc_decaps(sk_bytes: *const [K.SecretKey.encoded_length]u8, ct: *const [K.ciphertext_length]u8, ss: *[K.shared_length]u8) callconv(.c) u32 {
    const sk = K.SecretKey.fromBytes(sk_bytes) catch return 1;
    ss.* = sk.decaps(ct) catch return 2;
    return 0;
}
