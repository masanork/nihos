//! Bounded SSH randomness derived from a qualified external seed source.
//! This module does not provide or qualify hardware entropy. The caller owns
//! a stable instance and must wipe it when the session or boot epoch ends.
const std = @import("std");
const Generator = std.Random.DefaultCsprng;

pub const seed_bytes = Generator.secret_seed_length;
pub const max_request_bytes = 256;
pub const max_generated_bytes = 16 * 1024 * 1024;

/// Uses Zig's ChaCha-based CSPRNG. The source must independently guarantee a
/// fresh, uniform, secret 256-bit seed and provide bounded, nonblocking calls.
/// A successful seed permits later output even if the source is disabled.
/// Do not copy a seeded instance or alias its internal state with an output.
pub const Entropy = struct {
    generator: Generator = std.mem.zeroes(Generator),
    generated: usize = 0,
    seeded: bool = false,

    pub fn seedFrom(self: *Entropy, source: anytype) !void {
        self.clear();
        if (!source.qualified()) return error.EntropyUnavailable;
        var seed: [seed_bytes]u8 = @splat(0);
        defer std.crypto.secureZero(u8, &seed);
        try source.fillSeed(&seed);
        // Check again: a source that lost its exclusive entitlement while
        // reading is not permitted to authorize this seed.
        if (!source.qualified()) return error.EntropyUnavailable;
        self.generator = Generator.init(seed);
        self.seeded = true;
    }
    pub fn available(self: *const Entropy) bool {
        return self.seeded;
    }
    pub fn fill(self: *Entropy, out: []u8) !void {
        if (!self.seeded or out.len > max_request_bytes or self.generated > max_generated_bytes or out.len > max_generated_bytes - self.generated) {
            std.crypto.secureZero(u8, out);
            self.clear();
            return error.EntropyUnavailable;
        }
        self.generator.fill(out);
        self.generated += out.len;
        if (self.generated == max_generated_bytes) self.clear();
    }
    pub fn clear(self: *Entropy) void {
        std.crypto.secureZero(u8, std.mem.asBytes(&self.generator));
        self.generated = 0;
        self.seeded = false;
    }
};

const TestSource = struct {
    ready: bool = true,
    fail: bool = false,
    revoke_after_fill: bool = false,
    value: u8 = 1,
    fn qualified(self: *@This()) bool {
        return self.ready;
    }
    fn fillSeed(self: *@This(), out: *[seed_bytes]u8) !void {
        @memset(out, self.value);
        if (self.revoke_after_fill) self.ready = false;
        if (self.fail) return error.SourceFailure;
    }
};

test "seeded output matches a ChaCha8 reference block" {
    const Source = struct {
        fn qualified(_: *@This()) bool {
            return true;
        }
        fn fillSeed(_: *@This(), out: *[seed_bytes]u8) !void {
            for (out, 0..) |*byte, i| byte.* = @intCast(i);
        }
    };
    var source: Source = .{};
    var entropy: Entropy = .{};
    defer entropy.clear();
    try entropy.seedFrom(&source);
    var output: [32]u8 = undefined;
    try entropy.fill(&output);
    const expected = [_]u8{ 0xff, 0x9e, 0xad, 0x36, 0x5f, 0x89, 0xce, 0x3b, 0x6f, 0x40, 0x55, 0xbc, 0x75, 0x9d, 0x90, 0xfd, 0x8f, 0x83, 0x1d, 0x27, 0xc7, 0xb0, 0xdf, 0x93, 0xb3, 0xb9, 0xed, 0x82, 0x38, 0xa2, 0x56, 0xd6 };
    try std.testing.expectEqualSlices(u8, &expected, &output);
}

test "a seed is admitted only while its source stays qualified" {
    var entropy: Entropy = .{};
    var source: TestSource = .{ .ready = false };
    try std.testing.expectError(error.EntropyUnavailable, entropy.seedFrom(&source));
    try std.testing.expect(!entropy.available());
    source.ready = true;
    source.fail = true;
    try std.testing.expectError(error.SourceFailure, entropy.seedFrom(&source));
    try std.testing.expect(!entropy.available());
    for (std.mem.asBytes(&entropy.generator)) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    source.fail = false;
    source.revoke_after_fill = true;
    try std.testing.expectError(error.EntropyUnavailable, entropy.seedFrom(&source));
    try std.testing.expect(!entropy.available());
    source.ready = true;
    source.revoke_after_fill = false;
    try entropy.seedFrom(&source);
    try std.testing.expect(entropy.available());
    source.ready = false; // The seeded generator no longer needs the source.
    var first: [32]u8 = undefined;
    var second: [32]u8 = undefined;
    try entropy.fill(&first);
    try entropy.fill(&second);
    try std.testing.expect(!std.mem.eql(u8, &first, &second));
    entropy.clear();
    try std.testing.expect(!entropy.available());
    for (std.mem.asBytes(&entropy.generator)) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
}

test "limits reject output and require a fresh admitted seed" {
    var entropy: Entropy = .{};
    var source: TestSource = .{};
    try entropy.seedFrom(&source);
    var too_large: [max_request_bytes + 1]u8 = @splat(0xaa);
    try std.testing.expectError(error.EntropyUnavailable, entropy.fill(&too_large));
    try std.testing.expect(!entropy.available());
    try std.testing.expect(std.mem.allEqual(u8, &too_large, 0));
    try entropy.seedFrom(&source);
    entropy.generated = max_generated_bytes - 1;
    var output: [2]u8 = @splat(0xaa);
    try std.testing.expectError(error.EntropyUnavailable, entropy.fill(&output));
    try std.testing.expect(std.mem.allEqual(u8, &output, 0));
    try std.testing.expect(!entropy.available());
    try entropy.seedFrom(&source);
    entropy.generated = max_generated_bytes - 1;
    try entropy.fill(output[0..1]);
    try std.testing.expect(!entropy.available());
    try std.testing.expectError(error.EntropyUnavailable, entropy.fill(&output));
}
