//! Experimental CPU0 SSH workspace lifecycle, not connected to home or key
//! storage. Caller owns this stable controller, services the network owner,
//! and supplies trusted host pins, client credentials and secure randomness.
const network = @import("network_service");
const console = @import("text_console");
const bridge = @import("ssh_terminal_session");
const lifecycle = @import("ssh_lifecycle");
const layout = @import("sqld_layout.zig");

pub const Material = lifecycle.Material;
pub const Model = console.scratch.Model;
pub const Ui = bridge.Session(network.ExperimentalSshSession, 80, 24, 8);
comptime {
    if (@sizeOf(Ui) > layout.ssh_ui_experiment_bytes) @compileError("SSH UI exceeds PSRAM reservation");
    if (layout.ssh_ui_experiment % @alignOf(Ui) != 0) @compileError("SSH UI reservation misaligned");
}
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
pub const Workspace = struct {
    network: NativeNetwork,
    controller: Controller,
    /// Called only after the network boot path admitted and bound PSRAM.
    /// Never move this workspace while the controller is active.
    pub fn initInPlace(self: *Workspace, model: *console.scratch.Model) !void {
        if (!network.experimentalSshStorageBound()) return error.StorageUnavailable;
        self.network = .{};
        const ui: *Ui = @ptrFromInt(layout.ssh_ui_experiment);
        self.controller = Controller.init(&self.network, ui, model);
    }
    pub fn now() !u64 {
        return network.experimentalSshSessionNow();
    }
};
