const std = @import("std");
const ota = @import("hosted_ota.zig");
const pump = @import("hosted_ota_pump.zig");
const fake = @import("hosted_ota_fake.zig");
test "exact Hosted 3 candidate transfer with 2.13 explicit activation" {
    const image = @embedFile("candidate.bin");
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(image, &hash, .{});
    const expected = [_]u8{ 0x04, 0xbd, 0x14, 0xfa, 0xf9, 0x43, 0x45, 0x3c, 0xcf, 0x39, 0x07, 0x5b, 0xc6, 0x14, 0x56, 0x46, 0x3b, 0x3f, 0x36, 0x26, 0x43, 0xa3, 0xa6, 0x3d, 0xab, 0x0f, 0x82, 0xa5, 0x3f, 0x4d, 0xc8, 0xfe };
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
