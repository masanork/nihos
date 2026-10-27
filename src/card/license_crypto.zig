//! Public-key operation only. NPA 010 sections 2-11 / 3-6 specify the exact
//! 00 01 FF...FF 00 SHA256 block (no ASN.1 DigestInfo). No private keys here.
const std = @import("std");
pub const Request = extern struct {
    modulus: *const [256]u8,
    exponent: u32,
    signature: *const [256]u8,
    data: [*]const u8,
    length: usize,
};
pub const Error = error{ InvalidKey, InvalidSignature, TooLarge };
const M = std.crypto.ff.Modulus(2048);
noinline fn exponentiate(comptime squares: usize, modulus: *const M, signature: *const M.Fe, output: *[256]u8) Error!void {
    var base = signature.*;
    modulus.toMontgomery(&base) catch return error.InvalidKey;
    var result = base;
    // e=3 or e=65537. Use the standard-library Montgomery primitives without
    // its generic exponent precomputation table on the isolated small stack.
    for (0..squares) |_| result = modulus.sq(result);
    result = modulus.mul(result, base);
    modulus.fromMontgomery(&result) catch return error.InvalidKey;
    result.toBytes(output, .big) catch return error.InvalidSignature;
}
noinline fn publicOperation(request: *const Request, output: *[256]u8) Error!void {
    const modulus = M.fromBytes(request.modulus, .big) catch return error.InvalidKey;
    const signature = M.Fe.fromBytes(modulus, request.signature, .big) catch return error.InvalidSignature;
    if (request.exponent == 65537) try exponentiate(16, &modulus, &signature, output) else try exponentiate(1, &modulus, &signature, output);
}
pub fn verify(request: *const Request) Error!void {
    if (request.length > 5845) return error.TooLarge;
    if ((request.exponent != 3 and request.exponent != 65537) or request.modulus[0] & 128 == 0 or request.modulus[255] & 1 == 0) return error.InvalidKey;
    var decoded: [256]u8 = undefined;
    defer std.crypto.secureZero(u8, &decoded);
    try publicOperation(request, &decoded);
    var expected: [256]u8 = @splat(255);
    defer std.crypto.secureZero(u8, &expected);
    expected[0] = 0;
    expected[1] = 1;
    expected[223] = 0;
    std.crypto.hash.sha2.Sha256.hash(request.data[0..request.length], expected[224..256], .{});
    if (!std.crypto.timing_safe.eql([256]u8, expected, decoded)) return error.InvalidSignature;
}
pub fn selftest() bool {
    const vector = @embedFile("fixtures/license-rsa.bin");
    var request = Request{ .modulus = vector[0..256], .exponent = 65537, .signature = vector[256..512], .data = "nihOS synthetic licence".ptr, .length = "nihOS synthetic licence".len };
    verify(&request) catch return false;
    request.signature = vector[512..768]; // Standard DigestInfo is a different protocol.
    if (verify(&request)) |_| return false else |_| {}
    request.signature = vector[768..1024]; // Malformed padding, same digest.
    if (verify(&request)) |_| return false else |_| {}
    request.modulus = vector[1024..1280];
    request.signature = vector[1280..1536];
    request.exponent = 3;
    verify(&request) catch return false;
    return true;
}
test "independent synthetic RSA known-answer and strict NPA padding" {
    try std.testing.expect(selftest());
    const vector = @embedFile("fixtures/license-rsa.bin");
    var request = Request{ .modulus = vector[0..256], .exponent = 65537, .signature = vector[256..512], .data = "changed".ptr, .length = 7 };
    try std.testing.expectError(error.InvalidSignature, verify(&request));
    request.exponent = 2;
    try std.testing.expectError(error.InvalidKey, verify(&request));
}
