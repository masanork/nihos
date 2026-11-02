//! RV32 compile-only lifecycle. Never execute with fixed test material.
const ssh = @import("ssh_workspace");
export fn nih_ssh_workspace_probe(ws: *ssh.Workspace, model: *ssh.Model, random: *const [32]u8, seed: *const [32]u8) u32 {
    ws.initInPlace(model) catch return 0;
    const now = ssh.Workspace.now() catch return 0;
    ws.controller.begin(now, now +| 10_000_000, 2_000_000, .{ 10, 0, 2, 2 }, 22, 50001, 123) catch return 0;
    const material = ssh.Material{ .secret = @splat(1), .pin = @splat(2), .cookie = @splat(3) };
    _ = ws.controller.poll(now +| 1000, &material, random, "probe", seed.*) catch return 0;
    ws.controller.cancel();
    return @intFromBool(ws.controller.retryCleanup());
}
