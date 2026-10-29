const std = @import("std");
pub const panic = std.debug.no_panic;
const D = std.crypto.sign.mldsa.MLDSA65;
pub export fn pqc_verify(pk_bytes: *const [D.PublicKey.encoded_length]u8, sig_bytes: *const [D.Signature.encoded_length]u8, msg: [*]const u8, len: usize) callconv(.c) u32 {
    const pk = D.PublicKey.fromBytes(pk_bytes.*) catch return 1;
    const sig = D.Signature.fromBytes(sig_bytes.*) catch return 2;
    sig.verify(msg[0..len], pk) catch return 3;
    return 0;
}
