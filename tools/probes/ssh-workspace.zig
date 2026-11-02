//! RV32 compile-only lifecycle. Never execute with fixed test material.
const ssh = @import("ssh_workspace");
export fn nih_ssh_workspace_probe(ws: *ssh.Workspace, model: *ssh.Model, random: *const [32]u8, seed: *const [32]u8) u32 {
    ws.initInPlace(model) catch return 0;
    const now = ssh.Workspace.now() catch return 0;
    model.nav.screen = .ssh;
    // SAFETY: initInPlace initializes the owner before access.
    var journey: ssh.Journey = undefined;
    journey.initInPlace(model, &ws.controller);
    if (!journey.start()) return 0;
    defer journey.cancel();
    for ([_][]const u8{ "10.0.2.2", "22", "probe", "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", "0101010101010101010101010101010101010101010101010101010101010101" }) |value| {
        for (value) |byte| model.handle(.{ .text = byte });
        model.handle(.enter);
    }
    if (journey.setup.status != .ready) return 0;
    journey.profile.seed = seed.*;
    journey.begin(now, now +| 10_000_000, 2_000_000, 50001, 123) catch return 0;
    const material = ssh.ExchangeEntropy{ .secret = @splat(1), .cookie = @splat(3) };
    _ = journey.poll(now +| 1000, &material, random) catch return 0;
    journey.cancel();
    return @intFromBool(journey.retryCleanup());
}
