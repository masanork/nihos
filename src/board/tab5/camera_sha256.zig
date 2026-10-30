//! Compact SHA-256 for bounded diagnostic scans. No hardware or secrecy claim.
const std = @import("std");
const constants = [64]u32{
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
};
pub const Sha256 = struct {
    state: [8]u32 = .{ 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 },
    buffer: [64]u8 = @splat(0),
    used: usize = 0,
    length: u64 = 0,
    pub fn init(_: anytype) Sha256 { return .{}; }
    fn rotr(x: u32, bits: u5) u32 { return (x >> bits) | (x << @as(u5, @intCast(32 - @as(u6, bits)))); }
    noinline fn block(self: *Sha256, data: *const [64]u8) void {
        var w: [64]u32 = undefined;
        for (0..16) |i| w[i] = std.mem.readInt(u32, data[i * 4 ..][0..4], .big);
        for (16..64) |i| {
            const a = w[i - 15]; const b = w[i - 2];
            w[i] = w[i - 16] +% (rotr(a, 7) ^ rotr(a, 18) ^ (a >> 3)) +% w[i - 7] +% (rotr(b, 17) ^ rotr(b, 19) ^ (b >> 10));
        }
        var a = self.state[0]; var b = self.state[1]; var c = self.state[2]; var d = self.state[3];
        var e = self.state[4]; var f = self.state[5]; var g = self.state[6]; var h = self.state[7];
        for (0..64) |i| {
            const t1 = h +% (rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)) +% ((e & f) ^ (~e & g)) +% constants[i] +% w[i];
            const t2 = (rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)) +% ((a & b) ^ (a & c) ^ (b & c));
            h = g; g = f; f = e; e = d +% t1; d = c; c = b; b = a; a = t1 +% t2;
        }
        self.state[0] +%= a; self.state[1] +%= b; self.state[2] +%= c; self.state[3] +%= d;
        self.state[4] +%= e; self.state[5] +%= f; self.state[6] +%= g; self.state[7] +%= h;
    }
    pub fn update(self: *Sha256, input: []const u8) void {
        self.length +%= input.len;
        var remaining = input;
        while (remaining.len != 0) {
            const take = @min(64 - self.used, remaining.len);
            @memcpy(self.buffer[self.used..][0..take], remaining[0..take]);
            self.used += take;
            remaining = remaining[take..];
            if (self.used == 64) { self.block(&self.buffer); self.used = 0; }
        }
    }
    pub fn final(self: *Sha256, output: *[32]u8) void {
        const bit_length = self.length *% 8;
        self.buffer[self.used] = 0x80;
        self.used += 1;
        if (self.used > 56) {
            @memset(self.buffer[self.used..], 0);
            self.block(&self.buffer);
            self.used = 0;
        }
        @memset(self.buffer[self.used..56], 0);
        std.mem.writeInt(u64, self.buffer[56..64], bit_length, .big);
        self.block(&self.buffer);
        for (self.state, 0..) |value, i| std.mem.writeInt(u32, output[i * 4 ..][0..4], value, .big);
    }
};
test "compact SHA-256 agrees with standard across boundaries and chunks" {
    var data: [1025]u8 = undefined;
    for (&data, 0..) |*byte, i| byte.* = @truncate(i *% 37 +% 11);
    for ([_]usize{ 0, 1, 55, 56, 63, 64, 65, 127, 128, 1024, 1025 }) |n| {
        var expected: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(data[0..n], &expected, .{});
        for ([_]usize{ 1, 7, 64, 511 }) |chunk| {
            var hash = Sha256.init(.{}); var i: usize = 0;
            while (i < n) { const end = @min(i + chunk, n); hash.update(data[i..end]); i = end; }
            var actual: [32]u8 = undefined; hash.final(&actual);
            try std.testing.expectEqualSlices(u8, &expected, &actual);
        }
    }
}
test "frame-sized incremental digest agrees with standard" {
    var data: [1024]u8 = undefined;
    for (&data, 0..) |*byte, i| byte.* = @truncate(i *% 13 +% 7);
    var actual = Sha256.init(.{});
    var expected = std.crypto.hash.sha2.Sha256.init(.{});
    for (0..900) |_| { actual.update(&data); expected.update(&data); }
    var a: [32]u8 = undefined; var b: [32]u8 = undefined;
    actual.final(&a); expected.final(&b);
    try std.testing.expectEqualSlices(u8, &b, &a);
}
