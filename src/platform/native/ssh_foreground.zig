//! CPU0 foreground binding for the experimental xy SSH owner.
//! No hardware entropy source is qualified here; setup remains unavailable.
const ssh = @import("ssh_workspace");

const UnavailableEntropy = struct {
    // Do not link the SSH cryptographic path into a device image until a
    // qualified source and its memory placement have both been admitted.
    pub const qualified = false;
    pub fn available(_: *@This()) bool {
        return false;
    }
    pub fn fill(_: *@This(), _: []u8) error{EntropyUnavailable}!void {
        return error.EntropyUnavailable;
    }
};
const Visit = ssh.Foreground(UnavailableEntropy);

pub const Runtime = struct {
    workspace: ssh.Workspace,
    entropy: UnavailableEntropy = .{},
    visit: Visit,
    model: ?*ssh.Model = null,
    active: bool = false,

    pub fn init() Runtime {
        // SAFETY: workspace and visit are initialized on entry before access.
        return .{ .workspace = undefined, .visit = undefined };
    }

    /// Call on CPU0 after the network owner and UI have each been serviced.
    /// A failed cleanup retains the old model and prevents a new visit.
    pub fn poll(self: *Runtime, model: ?*ssh.Model, ui: *ssh.Ui, now: u64) void {
        if (comptime !UnavailableEntropy.qualified) return;
        const visible = if (model) |m| m.nav.screen == .ssh else false;
        if (self.active and (!visible or self.model != model)) {
            if (!self.visit.stop()) return;
            self.active = false;
            self.model = null;
        }
        if (!visible) return;
        const current = model orelse return;
        if (!self.active) {
            self.workspace.initInPlace(current, ui) catch return;
            self.visit.initInPlace(current, &self.workspace.controller, &self.entropy, 20_000_000, 5_000_000) catch return;
            self.model = current;
            self.active = true;
        }
        _ = self.visit.poll(true, now) catch return;
    }
};
