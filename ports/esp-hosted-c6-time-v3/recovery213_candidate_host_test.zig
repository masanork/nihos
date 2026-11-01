const std = @import("std");
const ota = @import("hosted_ota.zig");
const pump = @import("hosted_ota_pump.zig");
const fake = @import("hosted_ota_fake.zig");
test "exact 2.13.1 recovery candidate transfer with 3.0.10 explicit activation" {
    const image = @embedFile("candidate.bin");
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(image, &hash, .{});
    const expected = [_]u8{ 0x7f, 0x03, 0x6e, 0x61, 0x6d, 0xf4, 0xd4, 0x78, 0x20, 0x15, 0xca, 0xf3, 0x0f, 0x18, 0x5f, 0x78, 0x59, 0xaf, 0x11, 0x54, 0x38, 0xf3, 0x94, 0x46, 0x36, 0x00, 0xd0, 0xf8, 0xd6, 0x99, 0x95, 0xbe };
    try std.testing.expectEqualSlices(u8, &expected, &hash);
    var client = try ota.Client.init(image, expected, 9, 0);
    client.activation = .explicit_rpc;
    var driver = try pump.Pump.init(client, 0, 10000);
    var peer: fake.Fake = .{ .image = image, .explicit_activation = true };
    var now: u64 = 1;
    while (driver.state != .complete) : (now += 1) try driver.step(&peer, now);
    try std.testing.expectEqual(image.len, peer.offset);
    try std.testing.expectEqual(@TypeOf(peer.phase).complete, peer.phase);
}
