//! CPU0 foreground binding for the experimental xy SSH owner.
//! No hardware entropy source is qualified here; setup remains unavailable.
const ssh = @import("ssh_workspace");

const UnavailableEntropy = struct {
    // Do not link the SSH cryptographic path into a device image until a
    // qualified source and its memory placement have both been admitted.
    pub const qualified = false;
    state: enum { idle, failed } = .idle,
    pub fn begin(_: *@This(), _: u64, _: u64) error{EntropyUnavailable}!void {
        return error.EntropyUnavailable;
    }
    pub fn poll(_: *@This(), _: u64) void {}
    pub fn cancel(_: *@This()) void {}
    pub fn available(_: *@This()) bool {
        return false;
    }
    pub fn fill(_: *@This(), _: []u8) error{EntropyUnavailable}!void {
        return error.EntropyUnavailable;
    }
};
pub const qualified = UnavailableEntropy.qualified;
const Visit = ssh.PreparedForeground(UnavailableEntropy);

pub const Runtime = struct {
    workspace: ssh.Workspace,
    entropy: UnavailableEntropy = .{},
    visit: Visit,
    model: ?*ssh.Model = null,
    active: bool = false,

    /// Initialize the reserved, stable PSRAM storage before the first poll.
    /// Workspace and visit are initialized in place before their first use.
    pub fn initInPlace(self: *Runtime) void {
        self.entropy = .{};
        self.model = null;
        self.active = false;
    }

    /// Call on CPU0 after the network owner and UI have each been serviced.
    /// A failed cleanup retains the old model and prevents a new visit.
    pub fn poll(self: *Runtime, model: ?*ssh.Model, ui: *ssh.Ui, now: u64) void {
        if (comptime !UnavailableEntropy.qualified) return;
        const visible = if (model) |m| m.nav.screen == .ssh else false;
        if (self.active and (!visible or self.model != model)) {
            if (self.visit.poll(false, now) != .idle) return;
            self.active = false;
            self.model = null;
        }
        if (!visible) return;
        const current = model orelse return;
        if (!self.active) {
            self.workspace.initInPlace(current, ui) catch return;
            self.visit.initInPlace(current, &self.workspace.controller, &self.entropy, 20_000_000, 20_000_000, 5_000_000) catch return;
            self.model = current;
            self.active = true;
        }
        _ = self.visit.poll(true, now);
    }
};
