//! Single foreground SSH lifecycle. Network, UI and model storage are owned by
//! the caller and must stay stable; no credentials or entropy are retained.
//! The caller polls the network owner separately and serializes every operation.
const std = @import("std");

pub const Material = struct { secret: [32]u8, pin: [32]u8, cookie: [16]u8 };
pub const ExchangeEntropy = struct { secret: [32]u8, cookie: [16]u8 };
pub const State = enum { idle, opening, need_material, handshaking, ready, closing, closed, failed };

/// Volatile caller-owned connection material. Never copy, persist, log or put
/// this object in an editor buffer. Input slices must not alias this object.
/// The fingerprint is OpenSSH's SHA256 hash of the complete host-key blob;
/// the seed is exactly 32 raw Ed25519 seed bytes, encoded as 64 hex digits.
pub const Profile = struct {
    address: [4]u8 = @splat(0),
    port: u16 = 0,
    username: [64]u8 = @splat(0),
    username_len: u8 = 0,
    pin: [32]u8 = @splat(0),
    seed: [32]u8 = @splat(0),
    valid: bool = false,

    /// Replace atomically: invalid input leaves the previous profile intact.
    pub fn set(self: *Profile, address: []const u8, port: []const u8, username: []const u8, fingerprint: []const u8, seed_hex: []const u8) error{InvalidProfile}!void {
        var next: Profile = .{};
        defer next.clear();
        var pieces = std.mem.splitScalar(u8, address, '.');
        for (&next.address) |*octet| {
            const text = pieces.next() orelse return error.InvalidProfile;
            if (text.len == 0 or text.len > 3 or (text.len > 1 and text[0] == '0')) return error.InvalidProfile;
            for (text) |c| if (c < '0' or c > '9') return error.InvalidProfile;
            octet.* = std.fmt.parseInt(u8, text, 10) catch return error.InvalidProfile;
        }
        if (pieces.next() != null or next.address[0] == 0 or next.address[0] >= 224) return error.InvalidProfile;
        if (port.len == 0 or port.len > 5) return error.InvalidProfile;
        for (port) |c| if (c < '0' or c > '9') return error.InvalidProfile;
        next.port = std.fmt.parseInt(u16, port, 10) catch return error.InvalidProfile;
        if (next.port == 0 or username.len == 0 or username.len > next.username.len) return error.InvalidProfile;
        for (username) |c| if (c < 33 or c > 126) return error.InvalidProfile;
        @memcpy(next.username[0..username.len], username);
        next.username_len = @intCast(username.len);
        if (!std.mem.startsWith(u8, fingerprint, "SHA256:") or fingerprint.len != 50) return error.InvalidProfile;
        const encoded = fingerprint[7..];
        std.base64.standard_no_pad.Decoder.decode(&next.pin, encoded) catch return error.InvalidProfile;
        var canonical: [43]u8 = undefined;
        if (!std.mem.eql(u8, std.base64.standard_no_pad.Encoder.encode(&canonical, &next.pin), encoded)) return error.InvalidProfile;
        if (seed_hex.len != 64) return error.InvalidProfile;
        _ = std.fmt.hexToBytes(&next.seed, seed_hex) catch return error.InvalidProfile;
        next.valid = true;
        self.clear();
        self.* = next;
    }
    pub fn user(self: *const Profile) []const u8 {
        return self.username[0..self.username_len];
    }
    pub fn clear(self: *Profile) void {
        std.crypto.secureZero(u8, std.mem.asBytes(self));
    }
};

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
        /// Profile remains caller-owned and unchanged throughout authentication.
        /// The local port and sequence must be selected securely by the caller.
        pub fn beginProfile(self: *Self, profile: *const Profile, now: u64, deadline: u64, close_timeout: u64, local_port: u16, sequence: u32) !void {
            if (!profile.valid) return error.InvalidProfile;
            try self.begin(now, deadline, close_timeout, profile.address, profile.port, local_port, sequence);
        }
        /// Caller supplies fresh padding on every call and wipes its profile and
        /// exchange entropy after use. No entropy source is provided here.
        pub fn pollProfile(self: *Self, profile: *const Profile, now: u64, exchange: ?*const ExchangeEntropy, padding: *const [32]u8) !State {
            if (!profile.valid) {
                self.cancel();
                return error.InvalidProfile;
            }
            var material: Material = .{ .secret = @splat(0), .pin = @splat(0), .cookie = @splat(0) };
            defer std.crypto.secureZero(u8, std.mem.asBytes(&material));
            const supplied: ?*const Material = if (exchange) |entropy| blk: {
                material = .{ .secret = entropy.secret, .pin = profile.pin, .cookie = entropy.cookie };
                break :blk &material;
            } else null;
            return self.poll(now, supplied, padding, profile.user(), profile.seed);
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
    observed_pin: [32]u8 = @splat(0),
    fn open(_: *@This(), _: [4]u8, _: u16, _: u16, _: u32, _: u64) !Handle {
        return 7;
    }
    fn ready(self: *@This(), _: Handle) !bool {
        return self.established;
    }
    fn startSsh(self: *@This(), _: Handle, _: u64, _: [32]u8, pin: [32]u8, _: [16]u8, _: u32, _: u32) !*Owner {
        self.observed_pin = pin;
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

test "profile validates OpenSSH fingerprint and wipes credentials" {
    var p: Profile = .{};
    const ones: [32]u8 = @splat(1);
    const pin = "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
    const seed = "0101010101010101010101010101010101010101010101010101010101010101";
    try p.set("192.168.1.5", "22", "alice", pin, seed);
    try std.testing.expectEqual([4]u8{ 192, 168, 1, 5 }, p.address);
    try std.testing.expectEqual(@as(u16, 22), p.port);
    try std.testing.expectEqualStrings("alice", p.user());
    try std.testing.expectEqual(ones, p.seed);
    try std.testing.expectError(error.InvalidProfile, p.set("192.168.01.5", "22", "alice", pin, seed));
    try std.testing.expectError(error.InvalidProfile, p.set("192.168.1.5", "0", "alice", pin, seed));
    try std.testing.expectError(error.InvalidProfile, p.set("192.168.1.5", "22", "alice\n", pin, seed));
    try std.testing.expectError(error.InvalidProfile, p.set("192.168.1.5", "22", "alice", "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAB", seed));
    try std.testing.expectError(error.InvalidProfile, p.set("192.168.1.5", "22", "alice", pin, "invalid"));
    try std.testing.expectError(error.InvalidProfile, p.set("192.168.1.5", "22", "alice", pin, "01010101010101010101010101010101010101010101010101010101010101xz"));
    try std.testing.expectError(error.InvalidProfile, p.set("224.0.0.1", "22", "alice", pin, seed));
    try std.testing.expect(p.valid);
    try std.testing.expectEqualStrings("alice", p.user());
    try std.testing.expectEqual(ones, p.seed);
    p.clear();
    for (std.mem.asBytes(&p)) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
}

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

test "profile lifecycle supplies pin and cancels if profile is erased" {
    var network: TestNetwork = .{ .established = true };
    var ui: TestUi = .{};
    var model: TestModel = .{};
    var controller = Controller(TestNetwork, TestUi, TestModel).init(&network, &ui, &model);
    var profile: Profile = .{};
    const pad: [32]u8 = @splat(4);
    const entropy = ExchangeEntropy{ .secret = @splat(1), .cookie = @splat(2) };
    try std.testing.expectError(error.InvalidProfile, controller.beginProfile(&profile, 10, 100, 20, 50001, 123));
    try profile.set("10.0.2.2", "22", "user", "SHA256:AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE", "0101010101010101010101010101010101010101010101010101010101010101");
    try controller.beginProfile(&profile, 10, 100, 20, 50001, 123);
    try std.testing.expectEqual(State.need_material, try controller.pollProfile(&profile, 11, null, &pad));
    try std.testing.expectEqual(State.handshaking, try controller.pollProfile(&profile, 12, &entropy, &pad));
    try std.testing.expectEqual(profile.pin, network.observed_pin);
    profile.clear();
    try std.testing.expectError(error.InvalidProfile, controller.pollProfile(&profile, 13, null, &pad));
    try std.testing.expectEqual(State.closed, controller.state);
    try std.testing.expect(ui.canceled and controller.owner == null and controller.handle == null);
    try std.testing.expectEqual(@as(u32, 1), network.released);
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
