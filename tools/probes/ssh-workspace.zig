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
export fn nih_ssh_workspace_probe(ws: *ssh.Workspace, model: *ssh.Model, ui: *ssh.Ui, random: *const [32]u8, seed: *const [32]u8) u32 {
    ws.initInPlace(model, ui) catch return 0;
    const now = ssh.Workspace.now() catch return 0;
    model.nav.screen = .ssh;
    var entropy = ProbeEntropy{ .bytes = random };
    // SAFETY: initInPlace initializes the visit before use.
    var foreground: ssh.Foreground(ProbeEntropy) = undefined;
    foreground.initInPlace(model, &ws.controller, &entropy, 10_000_000, 2_000_000) catch return 0;
    _ = foreground.poll(true, now) catch return 0;
    defer _ = foreground.stop();
    for ([_][]const u8{ "10.0.2.2", "22", "probe", "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", "0101010101010101010101010101010101010101010101010101010101010101" }) |value| {
        for (value) |byte| model.handle(.{ .text = byte });
        model.handle(.enter);
    }
    if (foreground.journey.setup.status != .ready) return 0;
    foreground.journey.profile.seed = seed.*;
    _ = foreground.poll(true, now) catch return 0;
    _ = foreground.poll(true, now +| 1000) catch return 0;
    return @intFromBool(foreground.stop());
}

// Compile-only foreground timing; this stub never provides entropy.
const ProbeSession = struct {
    state: enum { idle, failed } = .idle,
    pub fn begin(_: *@This(), _: u64, _: u64) error{Unavailable}!void {
        return error.Unavailable;
    }
    pub fn poll(_: *@This(), _: u64) void {}
    pub fn cancel(self: *@This()) void {
        self.state = .idle;
    }
    pub fn available(_: *@This()) bool {
        return false;
    }
    pub fn fill(_: *@This(), _: []u8) error{EntropyUnavailable}!void {
        return error.EntropyUnavailable;
    }
};
const ProbeTimer = struct {
    last: u64 = 0,
    failed: bool = false,
    pub fn observe(self: *@This(), now: u64) bool {
        if (self.failed or now < self.last) {
            self.failed = true;
            return false;
        }
        self.last = now;
        return true;
    }
};
const Timed = ssh.TimedPreparedForeground(ProbeSession, ProbeTimer);
export fn nih_ssh_timed_workspace_probe(timed: *Timed, ws: *ssh.Workspace, model: *ssh.Model, entropy: *ProbeSession, timer: *ProbeTimer, now: u64) u32 {
    timed.initInPlace(model, &ws.controller, entropy, timer, 10_000_000, 2_000_000, 2_000_000) catch return 0;
    return @backingInt(timed.poll(true, now));
}
