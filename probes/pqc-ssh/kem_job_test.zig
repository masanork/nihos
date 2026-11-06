//! Host-only ownership and C/Zig ML-KEM interoperability tests.
const std = @import("std");
const K = std.crypto.kem.ml_kem.MLKem768;
const Job = extern struct { secret_key: [2400]u8, epoch: u32, phase: c_int, arena_peak: usize };
extern fn nih_kem_init(*Job) void;
extern fn nih_kem_begin(*Job, u32, [*]u8, usize, *const [64]u8, *[1184]u8) c_int;
extern fn nih_kem_decaps(*Job, u32, [*]u8, usize, *const [1088]u8, *[32]u8) c_int;
extern fn nih_kem_cancel(*Job, u32) c_int;
extern fn nih_kem_retire(*Job, u32) c_int;
export var nih_kem_test_fail_at: c_uint = 0;
test "one-shot job binds epochs, erases memory and interoperates" {
    var job: Job = undefined;
    var arena: [32768]u8 align(64) = @splat(0xaa);
    var pk: [1184]u8 = undefined;
    var secret: [32]u8 = @splat(0xaa);
    const seed: [64]u8 = @splat(0x37);
    const coins: [32]u8 = @splat(0x48);
    nih_kem_init(&job);
    try std.testing.expectEqual(@as(c_int, -3), nih_kem_begin(&job, 0, &arena, arena.len, &seed, &pk));
    try std.testing.expectEqual(@as(c_int, -3), nih_kem_begin(&job, 1, &arena, arena.len - 1, &seed, &pk));
    try std.testing.expectEqual(@as(c_int, 0), nih_kem_begin(&job, 1, &arena, arena.len, &seed, &pk));
    try std.testing.expect(std.mem.allEqual(u8, &arena, 0));
    try std.testing.expectEqual(@as(c_int, -1), nih_kem_begin(&job, 2, &arena, arena.len, &seed, &pk));
    const zig_key = try K.KeyPair.generateDeterministic(seed);
    try std.testing.expectEqualSlices(u8, &zig_key.public_key.toBytes(), &pk);
    const encaps = zig_key.public_key.encapsDeterministic(&coins);
    try std.testing.expectEqual(@as(c_int, -1), nih_kem_decaps(&job, 2, &arena, arena.len, &encaps.ciphertext, &secret));
    try std.testing.expect(std.mem.allEqual(u8, &secret, 0xaa));
    try std.testing.expectEqual(@as(c_int, -1), nih_kem_cancel(&job, 2));
    try std.testing.expectEqual(@as(c_int, 0), nih_kem_decaps(&job, 1, &arena, arena.len, &encaps.ciphertext, &secret));
    try std.testing.expectEqualSlices(u8, &encaps.shared_secret, &secret);
    try std.testing.expect(std.mem.allEqual(u8, &job.secret_key, 0));
    try std.testing.expect(std.mem.allEqual(u8, &arena, 0));
    try std.testing.expectEqual(@as(c_int, -1), nih_kem_decaps(&job, 1, &arena, arena.len, &encaps.ciphertext, &secret));
    try std.testing.expectEqual(@as(c_int, 0), nih_kem_retire(&job, 1));
    try std.testing.expectEqual(@as(c_int, -1), nih_kem_begin(&job, 1, &arena, arena.len, &seed, &pk));
    try std.testing.expectEqual(@as(c_int, 0), nih_kem_begin(&job, 2, &arena, arena.len, &seed, &pk));
    try std.testing.expectEqual(@as(c_int, -1), nih_kem_retire(&job, 2));
    try std.testing.expectEqual(@as(c_int, 0), nih_kem_cancel(&job, 2));
    try std.testing.expect(std.mem.allEqual(u8, &job.secret_key, 0));
    try std.testing.expectEqual(@as(c_int, 0), nih_kem_retire(&job, 2));
}

test "each backend allocation failure clears and retires the job" {
    var job: Job = undefined;
    var arena: [32768]u8 align(64) = undefined;
    var pk: [1184]u8 = undefined;
    var secret: [32]u8 = undefined;
    const seed: [64]u8 = @splat(0x37);
    const coins: [32]u8 = @splat(0x48);
    const zig_key = try K.KeyPair.generateDeterministic(seed);
    const encaps = zig_key.public_key.encapsDeterministic(&coins);
    nih_kem_init(&job);
    var epoch: u32 = 1;
    for (1..8) |fail| {
        nih_kem_test_fail_at = @intCast(fail);
        @memset(&pk, 0xaa);
        @memset(&arena, 0xaa);
        try std.testing.expectEqual(@as(c_int, -2), nih_kem_begin(&job, epoch, &arena, arena.len, &seed, &pk));
        try std.testing.expect(std.mem.allEqual(u8, &arena, 0));
        try std.testing.expect(std.mem.allEqual(u8, &pk, 0));
        try std.testing.expect(std.mem.allEqual(u8, &job.secret_key, 0));
        try std.testing.expectEqual(@as(c_int, 0), nih_kem_retire(&job, epoch));
        epoch += 1;
    }
    for (1..20) |fail| {
        nih_kem_test_fail_at = 0;
        try std.testing.expectEqual(@as(c_int, 0), nih_kem_begin(&job, epoch, &arena, arena.len, &seed, &pk));
        nih_kem_test_fail_at = @intCast(fail);
        @memset(&secret, 0xaa);
        try std.testing.expectEqual(@as(c_int, -2), nih_kem_decaps(&job, epoch, &arena, arena.len, &encaps.ciphertext, &secret));
        try std.testing.expect(std.mem.allEqual(u8, &arena, 0));
        try std.testing.expect(std.mem.allEqual(u8, &secret, 0));
        try std.testing.expect(std.mem.allEqual(u8, &job.secret_key, 0));
        try std.testing.expectEqual(@as(c_int, 0), nih_kem_retire(&job, epoch));
        epoch += 1;
    }
    nih_kem_test_fail_at = 0;
}
