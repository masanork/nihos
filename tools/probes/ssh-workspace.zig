//! RV32 compile-only lifecycle. Never execute with fixed test material.
const ssh = @import("ssh_workspace");
const ProbeEntropy = struct {
    bytes: *const [32]u8,
    pub fn available(_: *@This()) bool {
        return true;
    }
    pub fn fill(self: *@This(), out: []u8) !void {
        if (out.len > self.bytes.len) return error.TooLarge;
        @memcpy(out, self.bytes[0..out.len]);
    }
};
export fn nih_ssh_workspace_probe(ws: *ssh.Workspace, model: *ssh.Model, random: *const [32]u8, seed: *const [32]u8) u32 {
    ws.initInPlace(model) catch return 0;
    const now = ssh.Workspace.now() catch return 0;
    model.nav.screen = .ssh;
    // SAFETY: initInPlace initializes the owner before access.
    var journey: ssh.Journey = undefined;
    journey.initInPlace(model, &ws.controller);
    var entropy = ProbeEntropy{ .bytes = random };
    var app = ssh.App(ProbeEntropy).init(&journey, &entropy, 10_000_000, 2_000_000) catch return 0;
    app.start() catch return 0;
    defer app.cancel();
    for ([_][]const u8{ "10.0.2.2", "22", "probe", "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", "0101010101010101010101010101010101010101010101010101010101010101" }) |value| {
        for (value) |byte| model.handle(.{ .text = byte });
        model.handle(.enter);
    }
    if (journey.setup.status != .ready) return 0;
    journey.profile.seed = seed.*;
    _ = app.tick(now) catch return 0;
    _ = app.tick(now +| 1000) catch return 0;
    app.cancel();
    return @intFromBool(app.retryCleanup());
}
