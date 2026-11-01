const std = @import("std");
const arm = @import("hosted_ota_arm.zig");
test "only exact reviewed image token arms once" {
    const digest: [32]u8 = @splat(0xab);
    var state = try arm.Arm.init(digest, 0, 100);
    var command: [70]u8 = undefined;
    @memcpy(command[0..5], "OTA1 ");
    for (0..32) |i| {
        command[5 + i * 2] = 'a';
        command[6 + i * 2] = 'b';
    }
    command[69] = '\n';
    for (command[0..69]) |b| try std.testing.expect(!try state.feed(b, 1));
    try std.testing.expect(try state.feed(command[69], 1));
    try std.testing.expectError(error.AlreadyFinished, state.feed('x', 2));
    state = try arm.Arm.init(digest, 0, 100);
    command[15] = 'c';
    for (command[0..69]) |b| _ = try state.feed(b, 1);
    try std.testing.expectError(error.InvalidToken, state.feed('\n', 1));
    try std.testing.expectError(error.AlreadyFinished, state.feed('x', 2));
}
test "truncated oversized and timed out input cannot arm" {
    const digest: [32]u8 = @splat(0);
    var state = try arm.Arm.init(digest, 0, 10);
    try std.testing.expectError(error.InvalidToken, state.feed('\n', 1));
    state = try arm.Arm.init(digest, 0, 10);
    for (0..69) |_| _ = try state.feed('a', 1);
    try std.testing.expectError(error.InvalidToken, state.feed('a', 1));
    state = try arm.Arm.init(digest, 0, 10);
    try std.testing.expectError(error.Timeout, state.feed('O', 10));
}
