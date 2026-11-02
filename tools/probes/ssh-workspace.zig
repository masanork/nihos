//! RV32 compile-only lifecycle. Never execute with fixed test material.
const ssh = @import("ssh_workspace");
export fn nih_ssh_workspace_probe(ws: *ssh.Workspace, model: *ssh.Model, random: *const [32]u8, seed: *const [32]u8) u32 {
    ws.initInPlace(model) catch return 0;
    const now = ssh.Workspace.now() catch return 0;
    var profile: ssh.Profile = .{};
    defer profile.clear();
    var form: ssh.ProfileForm = .{};
    defer form.clear();
    for ([_][]const u8{ "10.0.2.2", "22", "probe", "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", "0101010101010101010101010101010101010101010101010101010101010101" }) |value| {
        for (value) |byte| form.append(byte) catch return 0;
        form.next();
    }
    form.submit(&profile) catch return 0;
    profile.seed = seed.*;
    ws.beginProfile(&profile, now, now +| 10_000_000, 2_000_000, 50001, 123) catch return 0;
    const material = ssh.ExchangeEntropy{ .secret = @splat(1), .cookie = @splat(3) };
    _ = ws.pollProfile(&profile, now +| 1000, &material, random) catch return 0;
    ws.controller.cancel();
    return @intFromBool(ws.controller.retryCleanup());
}
