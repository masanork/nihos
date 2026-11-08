//! Experimental CPU0 SSH workspace lifecycle, not connected to home or key
//! storage. Caller owns this stable controller, services the network owner,
//! and supplies trusted host pins, client credentials and secure randomness.
const network = @import("network_service");
const console = @import("text_console");
const bridge = @import("ssh_terminal_session");
const lifecycle = @import("ssh_lifecycle");

pub const Material = lifecycle.Material;
pub const Profile = lifecycle.Profile;
pub const ProfileForm = lifecycle.ProfileForm;
pub const ExchangeEntropy = lifecycle.ExchangeEntropy;
pub const Model = console.scratch.Model;
pub const ProfileInput = lifecycle.ProfileInput(Model);
pub const Ui = bridge.Session(network.ExperimentalSshSession, 80, 24, 8);
pub const NativeNetwork = struct {
    pub const Handle = network.ExperimentalTcpHandle;
    pub const Owner = network.ExperimentalSshSession;
    pub fn open(_: *@This(), remote: [4]u8, port: u16, local: u16, seq: u32, deadline: u64) !Handle {
        return network.experimentalTcpOpen(remote, port, local, seq, deadline);
    }
    pub fn ready(_: *@This(), handle: Handle) !bool {
        return network.experimentalTcpReady(handle);
    }
    pub fn startSsh(_: *@This(), handle: Handle, deadline: u64, secret: [32]u8, pin: [32]u8, cookie: [16]u8, cols: u32, rows: u32) !*Owner {
        return network.experimentalSshReservedStart(handle, deadline, 5000, secret, pin, cookie, cols, rows);
    }
    pub fn releaseSsh(_: *@This(), owner: *Owner) !void {
        return network.experimentalSshReservedRelease(owner);
    }
    pub fn cancel(_: *@This(), handle: Handle) !void {
        network.experimentalTcpCancel(handle) catch |err| switch (err) {
            // A stale handle is already retired; the network epoch or owner
            // has revoked it and cannot route writes to it again.
            error.StaleHandle => return,
            else => return err,
        };
    }
    pub fn closeWrite(_: *@This(), handle: Handle, deadline: u64) !void {
        return network.experimentalTcpCloseWrite(handle, deadline);
    }
    pub fn closeComplete(_: *@This(), handle: Handle) !bool {
        return network.experimentalTcpCloseComplete(handle);
    }
};
pub const Controller = lifecycle.Controller(NativeNetwork, Ui, console.scratch.Model);
pub const Journey = lifecycle.Journey(Model, Controller);
/// The caller must provide a qualified entropy source; no native source is
/// assumed or enabled by this experimental adapter.
pub fn App(comptime Entropy: type) type {
    return lifecycle.App(Journey, Entropy);
}
pub fn Foreground(comptime Entropy: type) type {
    return lifecycle.Foreground(Model, Controller, Entropy);
}
/// The caller still supplies and qualifies the platform entropy session.
pub fn PreparedForeground(comptime EntropySession: type) type {
    return lifecycle.PreparedForeground(Model, Controller, EntropySession);
}
/// A foreground owner can feed its existing tick to entropy preparation.
/// The caller still owns and qualifies the timer and entropy session.
pub fn TimedPreparedForeground(comptime EntropySession: type, comptime Timer: type) type {
    return lifecycle.TimedPreparedForeground(Model, Controller, EntropySession, Timer);
}
pub const Workspace = struct {
    network: NativeNetwork,
    controller: Controller,
    /// Called only after the network boot path admitted and bound PSRAM.
    /// Never move this workspace while the controller is active.
    pub fn initInPlace(self: *Workspace, model: *console.scratch.Model, ui: *Ui) !void {
        if (!network.experimentalSshStorageBound()) return error.StorageUnavailable;
        self.network = .{};
        self.controller = Controller.init(&self.network, ui, model);
    }
    pub fn now() !u64 {
        return network.experimentalSshSessionNow();
    }
    /// Profile must remain unchanged and caller-owned through authentication.
    /// Port and sequence must be securely selected; this API does not generate entropy.
    pub fn beginProfile(self: *Workspace, profile: *const Profile, now_us: u64, deadline_us: u64, close_timeout_us: u64, local_port: u16, sequence: u32) !void {
        try self.controller.beginProfile(profile, now_us, deadline_us, close_timeout_us, local_port, sequence);
    }
    /// Every call needs fresh padding; exchange entropy is needed once TCP is
    /// ready. The caller retains and erases profile and entropy storage.
    pub fn pollProfile(self: *Workspace, profile: *const Profile, now_us: u64, exchange: ?*const ExchangeEntropy, padding: *const [32]u8) !lifecycle.State {
        return self.controller.pollProfile(profile, now_us, exchange, padding);
    }
};

/// CPU0 owner for an already prepared, stable entropy session and timer.
/// This is an integration boundary, not a qualified hardware owner. Keep
/// this object, its entropy session, and timer in place for its lifetime.
pub fn PreparedRuntime(comptime EntropySession: type, comptime Timer: type) type {
    const TimedVisit = TimedPreparedForeground(EntropySession, Timer);
    return struct {
        const Self = @This();
        workspace: Workspace,
        visit: TimedVisit,
        entropy: *EntropySession,
        timer: *Timer,
        model: ?*Model = null,
        active: bool = false,

        /// Boot-only, before the first visit; never reinitialize a live owner.
        pub fn initInPlace(self: *Self, entropy: *EntropySession, timer: *Timer) void {
            self.entropy = entropy;
            self.timer = timer;
            self.model = null;
            self.active = false;
        }

        /// After network and UI service, using the owner's monotonic tick.
        /// A departing or replaced model stays attached until cleanup succeeds.
        pub fn poll(self: *Self, model: ?*Model, ui: *Ui, now: u64) void {
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
                self.visit.initInPlace(current, &self.workspace.controller, self.entropy, self.timer, 20_000_000, 20_000_000, 5_000_000) catch return;
                self.model = current;
                self.active = true;
            }
            _ = self.visit.poll(true, now);
        }
    };
}
