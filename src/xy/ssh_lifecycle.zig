//! Single foreground SSH lifecycle. Network, UI and model storage are owned by
//! the caller and must stay stable; no credentials or entropy are retained.
//! The caller polls the network owner separately and serializes every operation.
const std = @import("std");

pub const Material = struct { secret: [32]u8, pin: [32]u8, cookie: [16]u8 };
pub const State = enum { idle, opening, need_material, handshaking, ready, closing, closed, failed };

/// Network wraps one TCP owner and a reserved SSH owner; Ui is an in-place xy
/// terminal session, and Model provides the terminal attachment API.
pub fn Controller(comptime Network: type, comptime Ui: type, comptime Model: type) type {
    return struct {
        const Self = @This();
        network: *Network,
        ui: *Ui,
        model: *Model,
        state: State = .idle,
        handle: ?Network.Handle = null,
        owner: ?*Network.Owner = null,
        ui_initialized: bool = false,
        attached: bool = false,
        deadline_us: u64 = 0,
        last_us: u64 = 0,
        close_timeout_us: u64 = 0,
        /// Bit 0: SSH release failed; bit 1: TCP cancellation failed.
        cleanup_errors: u8 = 0,

        pub fn init(network: *Network, ui: *Ui, model: *Model) Self {
            return .{ .network = network, .ui = ui, .model = model };
        }
        /// Port and sequence must be selected securely by the caller. A closed
        /// tuple is not reusable until the network owner changes its epoch.
        pub fn begin(self: *Self, now: u64, deadline: u64, close_timeout: u64, remote: [4]u8, remote_port: u16, local_port: u16, sequence: u32) !void {
            if (self.state != .idle) return error.InvalidState;
            if (deadline <= now or close_timeout == 0 or remote_port == 0 or local_port == 0) return error.InvalidArgument;
            const handle = try self.network.open(remote, remote_port, local_port, sequence, deadline);
            self.handle = handle;
            self.deadline_us = deadline;
            self.close_timeout_us = close_timeout;
            self.last_us = now;
            self.state = .opening;
        }
        /// Supply fresh padding for every call. Material is used only when TCP
        /// becomes ready. Username and Ed25519 seed must stay consistent until
        /// ready; the caller owns and must protect and erase those values.
        pub fn poll(self: *Self, now: u64, material: ?*const Material, padding: *const [32]u8, username: []const u8, seed: [32]u8) anyerror!State {
            return self.advance(now, material, padding, username, seed) catch |err| {
                self.cleanup();
                self.state = .failed;
                return err;
            };
        }
        fn advance(self: *Self, now: u64, material: ?*const Material, padding: *const [32]u8, username: []const u8, seed: [32]u8) anyerror!State {
            if (self.state == .idle or self.state == .closed or self.state == .failed) return error.InvalidState;
            if (now < self.last_us) return error.ClockRegression;
            self.last_us = now;
            if (self.state != .ready and now >= self.deadline_us) return error.Timeout;
            const handle = self.handle orelse return error.InvalidState;
            switch (self.state) {
                .opening, .need_material => {
                    if (!try self.network.ready(handle)) {
                        self.state = .opening;
                        return .opening;
                    }
                    const m = material orelse {
                        self.state = .need_material;
                        return .need_material;
                    };
                    const owner = try self.network.startSsh(handle, self.deadline_us, m.secret, m.pin, m.cookie, 80, 24);
                    self.owner = owner;
                    self.ui.initInPlace(owner, "SSH");
                    self.ui_initialized = true;
                    self.state = .handshaking;
                    // The adapter samples its own clock in startSsh. Poll on a
                    // later call with a fresh clock, never the older sample.
                    return .handshaking;
                },
                .handshaking, .ready => {
                    const old_revision = self.ui.revision;
                    const result = try self.ui.poll(now, padding, username, seed);
                    switch (result) {
                        .connecting => {
                            if (self.state != .handshaking) return error.InvalidState;
                            return .handshaking;
                        },
                        .ready => {
                            if (!self.attached) {
                                if (!self.model.attachTerminal(self.ui.port(Model.TerminalPortType))) return error.UiBusy;
                                self.attached = true;
                            } else if (self.ui.revision != old_revision) self.model.terminalChanged();
                            self.state = .ready;
                            return .ready;
                        },
                        .closed => {
                            self.detachUi();
                            if (self.owner) |owner| {
                                try self.network.releaseSsh(owner);
                                self.owner = null;
                            }
                            self.deadline_us = std.math.add(u64, now, self.close_timeout_us) catch return error.InvalidArgument;
                            try self.network.closeWrite(handle, self.deadline_us);
                            self.state = .closing;
                            return .closing;
                        },
                        .failed => return error.InvalidState,
                    }
                },
                .closing => {
                    if (!try self.network.closeComplete(handle)) return .closing;
                    try self.network.cancel(handle);
                    self.handle = null;
                    self.state = .closed;
                    return .closed;
                },
                else => return error.InvalidState,
            }
        }
        /// Cancellation never retries ambiguous I/O and wipes owned SSH state.
        pub fn cancel(self: *Self) void {
            self.cleanup();
            self.state = .closed;
        }
        fn detachUi(self: *Self) void {
            if (!self.ui_initialized) return;
            if (self.attached) {
                if (self.model.terminal) |port| {
                    if (@intFromPtr(port.context) == @intFromPtr(self.ui)) {
                        self.model.detachTerminal();
                    } else self.ui.cancel();
                } else self.ui.cancel();
            } else self.ui.cancel();
            self.attached = false;
            self.ui_initialized = false;
        }
        /// Retry cleanup if a platform operation failed; references remain
        /// owned until the corresponding operation confirms completion.
        pub fn retryCleanup(self: *Self) bool {
            self.cleanup();
            return self.owner == null and self.handle == null;
        }
        fn cleanup(self: *Self) void {
            self.detachUi();
            if (self.owner) |owner| {
                if (self.network.releaseSsh(owner)) |_| {
                    self.owner = null;
                } else |_| self.cleanup_errors |= 1;
            }
            if (self.handle) |handle| {
                if (self.network.cancel(handle)) |_| {
                    self.handle = null;
                } else |_| self.cleanup_errors |= 2;
            }
        }
    };
}

const TestModel = struct {
    const TerminalPort = struct { context: *anyopaque, close: *const fn (*anyopaque) void };
    pub const TerminalPortType = TerminalPort;
    terminal: ?TerminalPort = null,
    updates: u32 = 0,
    fn attachTerminal(self: *@This(), port: TerminalPort) bool {
        if (self.terminal != null) return false;
        self.terminal = port;
        return true;
    }
    fn detachTerminal(self: *@This()) void {
        const port = self.terminal orelse return;
        self.terminal = null;
        port.close(port.context);
    }
    fn terminalChanged(self: *@This()) void {
        self.updates += 1;
    }
};
const TestNetwork = struct {
    const Handle = u32;
    const Owner = struct { token: u8 = 1 };
    owner: Owner = .{},
    established: bool = false,
    close_done: bool = false,
    canceled: u32 = 0,
    released: u32 = 0,
    close_deadline: u64 = 0,
    fail_release: bool = false,
    fail_cancel: bool = false,
    fn open(_: *@This(), _: [4]u8, _: u16, _: u16, _: u32, _: u64) !Handle {
        return 7;
    }
    fn ready(self: *@This(), _: Handle) !bool {
        return self.established;
    }
    fn startSsh(self: *@This(), _: Handle, _: u64, _: [32]u8, _: [32]u8, _: [16]u8, _: u32, _: u32) !*Owner {
        return &self.owner;
    }
    fn releaseSsh(self: *@This(), _: *Owner) !void {
        if (self.fail_release) return error.ReleaseFailed;
        self.released += 1;
    }
    fn cancel(self: *@This(), _: Handle) !void {
        if (self.fail_cancel) return error.CancelFailed;
        self.canceled += 1;
    }
    fn closeWrite(self: *@This(), _: Handle, deadline: u64) !void {
        self.close_deadline = deadline;
    }
    fn closeComplete(self: *@This(), _: Handle) !bool {
        return self.close_done;
    }
};
const TestUi = struct {
    const Stage = enum { connecting, ready, closed, failed };
    stage: Stage = .connecting,
    revision: u32 = 0,
    produce: bool = false,
    canceled: bool = false,
    fn initInPlace(self: *@This(), _: *TestNetwork.Owner, _: []const u8) void {
        self.* = .{};
    }
    fn poll(self: *@This(), _: u64, _: *const [32]u8, _: []const u8, _: [32]u8) !Stage {
        if (self.produce) {
            self.produce = false;
            self.revision += 1;
        }
        return self.stage;
    }
    fn port(self: *@This(), comptime Port: type) Port {
        const Close = struct {
            fn call(ctx: *anyopaque) void {
                const ui: *TestUi = @ptrCast(@alignCast(ctx));
                ui.cancel();
            }
        };
        return .{ .context = self, .close = Close.call };
    }
    fn cancel(self: *@This()) void {
        self.canceled = true;
    }
};

test "lifecycle connects, attaches only when ready, and closes in order" {
    var network: TestNetwork = .{};
    var ui: TestUi = .{};
    var model: TestModel = .{};
    var c = Controller(TestNetwork, TestUi, TestModel).init(&network, &ui, &model);
    const pad: [32]u8 = @splat(4);
    const material = Material{ .secret = @splat(1), .pin = @splat(2), .cookie = @splat(3) };
    try c.begin(10, 100, 20, .{ 10, 0, 2, 2 }, 22, 50001, 123);
    try std.testing.expectEqual(State.opening, try c.poll(11, null, &pad, "user", @splat(5)));
    network.established = true;
    try std.testing.expectEqual(State.need_material, try c.poll(12, null, &pad, "user", @splat(5)));
    try std.testing.expectEqual(State.handshaking, try c.poll(13, &material, &pad, "user", @splat(5)));
    try std.testing.expect(model.terminal == null);
    ui.stage = .ready;
    try std.testing.expectEqual(State.ready, try c.poll(14, null, &pad, "user", @splat(5)));
    try std.testing.expect(model.terminal != null);
    ui.produce = true;
    _ = try c.poll(15, null, &pad, "user", @splat(5));
    try std.testing.expectEqual(@as(u32, 1), model.updates);
    ui.stage = .closed;
    try std.testing.expectEqual(State.closing, try c.poll(16, null, &pad, "user", @splat(5)));
    try std.testing.expect(model.terminal == null and ui.canceled);
    try std.testing.expectEqual(@as(u64, 36), network.close_deadline);
    try std.testing.expectEqual(@as(u32, 1), network.released);
    try std.testing.expectEqual(State.closing, try c.poll(17, null, &pad, "user", @splat(5)));
    network.close_done = true;
    try std.testing.expectEqual(State.closed, try c.poll(18, null, &pad, "user", @splat(5)));
    try std.testing.expectEqual(@as(u32, 1), network.canceled);
}

test "lifecycle times out and retains failed cleanup for retry" {
    var network: TestNetwork = .{ .established = true };
    var ui: TestUi = .{};
    var model: TestModel = .{};
    var c = Controller(TestNetwork, TestUi, TestModel).init(&network, &ui, &model);
    const pad: [32]u8 = @splat(4);
    const material = Material{ .secret = @splat(1), .pin = @splat(2), .cookie = @splat(3) };
    try c.begin(10, 20, 10, .{ 10, 0, 2, 2 }, 22, 50001, 123);
    _ = try c.poll(11, &material, &pad, "user", @splat(5));
    network.fail_release = true;
    network.fail_cancel = true;
    try std.testing.expectError(error.Timeout, c.poll(20, null, &pad, "user", @splat(5)));
    try std.testing.expectEqual(State.failed, c.state);
    try std.testing.expectEqual(@as(u8, 3), c.cleanup_errors);
    try std.testing.expect(c.owner != null and c.handle != null and ui.canceled);
    network.fail_release = false;
    network.fail_cancel = false;
    try std.testing.expect(c.retryCleanup());
    try std.testing.expect(c.owner == null and c.handle == null);
}
