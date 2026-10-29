//! Deterministic, public test material. No entropy or target-security claim.
const std = @import("std");
const K = std.crypto.kem.ml_kem.MLKem768;
const testing = std.testing;
const Arena = extern struct {
    bytes: [*]u8,
    capacity: usize,
    used: usize = 0,
    peak: usize = 0,
    attempts: c_uint = 0,
    fail_at: c_uint = 0,
    allocs: c_uint = 0,
    frees: c_uint = 0,
    live: c_uint = 0,
    uncleared: c_uint = 0,
};
extern fn PQCP_MLKEM_NATIVE_MLKEM768_keypair_derand([*]u8, [*]u8, [*]const u8, *Arena) c_int;
extern fn PQCP_MLKEM_NATIVE_MLKEM768_enc_derand([*]u8, [*]u8, [*]const u8, [*]const u8, *Arena) c_int;
extern fn PQCP_MLKEM_NATIVE_MLKEM768_dec([*]u8, [*]const u8, [*]const u8, *Arena) c_int;
fn arena(buf: []u8, fail: u32) Arena {
    return .{ .bytes = buf.ptr, .capacity = buf.len, .fail_at = fail };
}
fn cleanup(a: Arena) !void {
    try testing.expectEqual(@as(u32, 0), a.live);
    try testing.expectEqual(a.allocs, a.frees);
    try testing.expectEqual(@as(u32, 0), a.uncleared);
}
test "custom allocator interoperability and every allocation failure" {
    var buf: [32768]u8 align(64) = undefined;
    var pk: [K.PublicKey.encoded_length]u8 = undefined;
    var sk: [K.SecretKey.encoded_length]u8 = undefined;
    var ct: [K.ciphertext_length]u8 = undefined;
    var shared: [K.shared_length]u8 = undefined;
    var recovered: [K.shared_length]u8 = undefined;
    const seed: [K.seed_length]u8 = @splat(0x42);
    const coins: [K.encaps_seed_length]u8 = @splat(0x24);
    var a = arena(&buf, 0);
    try testing.expectEqual(0, PQCP_MLKEM_NATIVE_MLKEM768_keypair_derand(&pk, &sk, &seed, &a));
    try cleanup(a);
    const key_attempts = a.attempts;
    std.debug.print("keygen payload_peak={} attempts={} allocs={} frees={} uncleared={}\n", .{ a.peak, a.attempts, a.allocs, a.frees, a.uncleared });
    const zig_keys = try K.KeyPair.generateDeterministic(seed);
    try testing.expectEqualSlices(u8, &pk, &zig_keys.public_key.toBytes());
    try testing.expectEqualSlices(u8, &sk, &zig_keys.secret_key.toBytes());
    a = arena(&buf, 0);
    try testing.expectEqual(0, PQCP_MLKEM_NATIVE_MLKEM768_enc_derand(&ct, &shared, &pk, &coins, &a));
    try cleanup(a);
    const enc_attempts = a.attempts;
    std.debug.print("encaps payload_peak={} attempts={} allocs={} frees={} uncleared={}\n", .{ a.peak, a.attempts, a.allocs, a.frees, a.uncleared });
    const zig_enc = zig_keys.public_key.encapsDeterministic(&coins);
    try testing.expectEqualSlices(u8, &ct, &zig_enc.ciphertext);
    try testing.expectEqualSlices(u8, &shared, &zig_enc.shared_secret);
    a = arena(&buf, 0);
    try testing.expectEqual(0, PQCP_MLKEM_NATIVE_MLKEM768_dec(&recovered, &ct, &sk, &a));
    try cleanup(a);
    const dec_attempts = a.attempts;
    std.debug.print("decaps payload_peak={} attempts={} allocs={} frees={} uncleared={}\n", .{ a.peak, a.attempts, a.allocs, a.frees, a.uncleared });
    try testing.expectEqualSlices(u8, &shared, &recovered);
    var altered = ct;
    altered[0] ^= 1;
    a = arena(&buf, 0);
    try testing.expectEqual(0, PQCP_MLKEM_NATIVE_MLKEM768_dec(&recovered, &altered, &sk, &a));
    try cleanup(a);
    const zig_rejected = try zig_keys.secret_key.decaps(&altered);
    try testing.expectEqualSlices(u8, &zig_rejected, &recovered);
    try testing.expect(!std.mem.eql(u8, &shared, &recovered));
    for (0..key_attempts) |i| {
        a = arena(&buf, @intCast(i + 1));
        var scratch_pk: [K.PublicKey.encoded_length]u8 = undefined;
        var scratch_sk: [K.SecretKey.encoded_length]u8 = undefined;
        try testing.expectEqual(-2, PQCP_MLKEM_NATIVE_MLKEM768_keypair_derand(&scratch_pk, &scratch_sk, &seed, &a));
        try cleanup(a);
    }
    for (0..enc_attempts) |i| {
        a = arena(&buf, @intCast(i + 1));
        var scratch_ct: [K.ciphertext_length]u8 = undefined;
        var scratch_ss: [K.shared_length]u8 = undefined;
        try testing.expectEqual(-2, PQCP_MLKEM_NATIVE_MLKEM768_enc_derand(&scratch_ct, &scratch_ss, &pk, &coins, &a));
        try cleanup(a);
    }
    for (0..dec_attempts) |i| {
        a = arena(&buf, @intCast(i + 1));
        try testing.expectEqual(-2, PQCP_MLKEM_NATIVE_MLKEM768_dec(&recovered, &ct, &sk, &a));
        try cleanup(a);
    }
    std.debug.print("oom_injections={}\n", .{key_attempts + enc_attempts + dec_attempts});
}
