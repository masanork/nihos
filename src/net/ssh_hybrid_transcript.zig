//! Experimental RFC 10042 transcript primitives. Not wired into SSH negotiation.
const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const client_len = 1184 + 32;
pub const server_len = 1088 + 32;
pub const Error = error{ InvalidLength, InvalidSharedSecret, InputTooLong };

/// X25519's result is the fixed-width byte encoding used by RFC 8731.
pub fn combine(pq: [32]u8, classical: [32]u8) Error![32]u8 {
    if (std.mem.allEqual(u8, &classical, 0)) return error.InvalidSharedSecret;
    var hash = Sha256.init(.{});
    hash.update(&pq);
    hash.update(&classical);
    return hash.finalResult();
}

/// K is encoded as an SSH string, not as the classical SSH mpint.
pub fn exchangeHash(client_banner: []const u8, server_banner: []const u8, client_init: []const u8, server_init: []const u8, host_key: []const u8, client: []const u8, server: []const u8, k: [32]u8) Error![32]u8 {
    if (client.len != client_len or server.len != server_len) return error.InvalidLength;
    var hash = Sha256.init(.{});
    for ([_][]const u8{ client_banner, server_banner, client_init, server_init, host_key, client, server, &k }) |part| {
        if (part.len > std.math.maxInt(u32)) return error.InputTooLong;
        var n: [4]u8 = undefined;
        std.mem.writeInt(u32, &n, @intCast(part.len), .big);
        hash.update(&n);
        hash.update(part);
    }
    return hash.finalResult();
}

test "hybrid transcript hashes fixed-width secrets and SSH strings" {
    const k = try combine(@splat(1), @splat(2));
    var k_buf: [32]u8 = undefined;
    const expected_k = try std.fmt.hexToBytes(&k_buf, "f818afd37a6dc3bc92fb44731011277006db4efa6e9023cd7468c02335d22a4d");
    try std.testing.expectEqualSlices(u8, expected_k, &k);
    const client: [client_len]u8 = @splat(3);
    const server: [server_len]u8 = @splat(4);
    const h = try exchangeHash("client", "server", "ci", "si", "host", &client, &server, k);
    var expected_buf: [32]u8 = undefined;
    const expected = try std.fmt.hexToBytes(&expected_buf, "049e727be62a946d25cef6f2ed56dd1eba4c31f6cc6533e5f0787a90b6f8b00a");
    try std.testing.expectEqualSlices(u8, expected, &h);
    try std.testing.expectError(error.InvalidLength, exchangeHash("", "", "", "", "", client[0 .. client.len - 1], &server, k));
    try std.testing.expectError(error.InvalidLength, exchangeHash("", "", "", "", "", &client, server[0 .. server.len - 1], k));
    try std.testing.expectError(error.InvalidSharedSecret, combine(@splat(1), @splat(0)));
}
