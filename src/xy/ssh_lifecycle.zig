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

/// Bounded transient input for a future SSH setup screen. Do not route secret
/// input through the editor, command history, logs or deferred input queues.
/// The owner must call clear on cancellation, navigation away or failure.
pub const ProfileForm = struct {
    pub const Field = enum(u8) { address, port, username, fingerprint, seed };
    const capacities = [5]u8{ 15, 5, 64, 50, 64 };
    fields: [5][64]u8 = @splat(@splat(0)),
    lengths: [5]u8 = @splat(0),
    selected: Field = .address,

    /// Reject a whole key rather than truncating it or accepting controls.
    pub fn append(self: *ProfileForm, byte: u8) error{ InvalidInput, Full }!void {
        const i = @backingInt(self.selected);
        if (byte < 33 or byte > 126) return error.InvalidInput;
        if (self.selected == .seed and !std.ascii.isHex(byte)) return error.InvalidInput;
        if (self.lengths[i] >= capacities[i]) return error.Full;
        self.fields[i][self.lengths[i]] = byte;
        self.lengths[i] += 1;
    }
    pub fn backspace(self: *ProfileForm) void {
        const i = @backingInt(self.selected);
        if (self.lengths[i] == 0) return;
        self.lengths[i] -= 1;
        self.fields[i][self.lengths[i]] = 0;
    }
    pub fn next(self: *ProfileForm) void {
        self.selected = @fromBackingInt(@intCast(@min(@backingInt(self.selected) + 1, 4)));
    }
    pub fn previous(self: *ProfileForm) void {
        self.selected = @fromBackingInt(@intCast(@backingInt(self.selected) -| 1));
    }
    fn slice(self: *const ProfileForm, field: Field) []const u8 {
        const i = @backingInt(field);
        return self.fields[i][0..self.lengths[i]];
    }
    /// The seed is never returned for display; the caller may draw a mask
    /// using length(.seed). No credential bytes are returned by this method.
    pub fn display(self: *const ProfileForm, field: Field) []const u8 {
        return if (field == .seed) "" else self.slice(field);
    }
    pub fn length(self: *const ProfileForm, field: Field) usize {
        return self.lengths[@backingInt(field)];
    }
    /// Failed validation preserves input for correction. A successful commit
    /// clears all form bytes; the caller owns and later clears the profile.
    pub fn submit(self: *ProfileForm, profile: *Profile) error{InvalidProfile}!void {
        try profile.set(self.slice(.address), self.slice(.port), self.slice(.username), self.slice(.fingerprint), self.slice(.seed));
        self.clear();
    }
    pub fn clear(self: *ProfileForm) void {
        std.crypto.secureZero(u8, std.mem.asBytes(self));
    }
};

/// Stable, caller-owned private input session. The model and output profile
/// must outlive it. No connection or persistence is started by this type.
pub fn ProfileInput(comptime Model: type) type {
    return struct {
        const Self = @This();
        const Key = Model.PrivateInputKey;
        const Port = Model.PrivateInputPortType;
        pub const Status = enum { idle, editing, ready, canceled };
        model: *Model,
        profile: *Profile,
        form: ProfileForm = .{},
        status: Status = .idle,
        invalid: bool = false,

        pub fn init(model: *Model, profile: *Profile) Self {
            return .{ .model = model, .profile = profile };
        }
        pub fn start(self: *Self) bool {
            if (self.status != .idle) return false;
            if (!self.model.attachPrivateInput(Port{ .context = self, .key = onKey, .close = onClose, .snapshot = onSnapshot })) return false;
            self.status = .editing;
            return true;
        }
        fn onKey(ctx: *anyopaque, key: Key) bool {
            const self: *Self = @ptrCast(@alignCast(ctx));
            if (self.status != .editing) return false;
            self.invalid = false;
            switch (key) {
                .text => |byte| self.form.append(byte) catch {
                    self.invalid = true;
                    return false;
                },
                .backspace => self.form.backspace(),
                .left, .up => self.form.previous(),
                .right, .down => self.form.next(),
                .enter => if (self.form.selected == .seed) {
                    self.form.submit(self.profile) catch {
                        self.invalid = true;
                        return false;
                    };
                    self.status = .ready;
                    self.model.detachPrivateInput();
                } else self.form.next(),
                .escape, .cancel => self.model.detachPrivateInput(),
                else => return false,
            }
            return true;
        }
        fn onClose(ctx: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.form.clear();
            if (self.status == .editing) self.status = .canceled;
        }
        fn onSnapshot(ctx: *anyopaque, out: *Port.View) bool {
            const self: *const Self = @ptrCast(@alignCast(ctx));
            if (self.status != .editing) return false;
            const field = self.form.selected;
            const public_text = self.form.display(field);
            out.* = .{ .field = @backingInt(field), .secret_length = if (field == .seed) @intCast(self.form.length(.seed)) else 0, .invalid = @intFromBool(self.invalid), .text = public_text.ptr, .text_length = public_text.len };
            return true;
        }
    };
}

/// Owns one private setup and its volatile profile through a single session.
/// The owner, model and controller must remain stable until cleanup finishes.
/// The caller advances networking and supplies cryptographic entropy.
pub fn Journey(comptime Model: type, comptime SessionController: type) type {
    return struct {
        const Self = @This();
        pub const Status = enum { idle, editing, active, closed, failed };
        model: *Model,
        controller: *SessionController,
        profile: Profile,
        setup: ProfileInput(Model),
        status: Status,

        /// Only initialize fresh storage or storage whose cleanup is complete.
        pub fn initInPlace(self: *Self, model: *Model, controller: *SessionController) void {
            self.model = model;
            self.controller = controller;
            self.profile = .{};
            self.setup = ProfileInput(Model).init(model, &self.profile);
            self.status = .idle;
        }
        pub fn start(self: *Self) bool {
            if (self.status != .idle or !self.setup.start()) return false;
            self.status = .editing;
            return true;
        }
        /// Observe setup cancellation after input events have been delivered.
        pub fn syncSetup(self: *Self) Status {
            if (self.status == .editing and self.setup.status == .canceled) {
                self.profile.clear();
                self.status = .closed;
            }
            return self.status;
        }
        /// Caller selects a secure ephemeral port and sequence number.
        pub fn begin(self: *Self, now: u64, deadline: u64, close_timeout: u64, local_port: u16, sequence: u32) !void {
            _ = self.syncSetup();
            if (self.status != .editing or self.setup.status != .ready) return error.InvalidState;
            self.controller.beginProfile(&self.profile, now, deadline, close_timeout, local_port, sequence) catch |err| {
                self.profile.clear();
                self.status = .failed;
                return err;
            };
            self.status = .active;
        }
        pub fn poll(self: *Self, now: u64, exchange: ?*const ExchangeEntropy, padding: *const [32]u8) !State {
            if (self.status != .active) return error.InvalidState;
            const result = self.controller.pollProfile(&self.profile, now, exchange, padding) catch |err| {
                self.profile.clear();
                self.status = .failed;
                return err;
            };
            if (result == .ready) {
                // The authenticated terminal no longer needs the signing seed.
                std.crypto.secureZero(u8, &self.profile.seed);
            } else if (result == .closed) {
                self.profile.clear();
                self.status = .closed;
            }
            return result;
        }
        /// The controller retains references to any resources whose cleanup
        /// failed; call retryCleanup before reinitializing this owner.
        pub fn cancel(self: *Self) void {
            if (self.model.private_input) |port| {
                if (@intFromPtr(port.context) == @intFromPtr(&self.setup)) self.model.detachPrivateInput();
            }
            if (self.status == .active) self.controller.cancel();
            self.setup.form.clear();
            self.profile.clear();
            self.status = .closed;
        }
        pub fn retryCleanup(self: *Self) bool {
            return self.controller.retryCleanup();
        }
    };
}

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

const TestPrivateModel = struct {
    pub const PrivateInputKey = union(enum) { text: u8, backspace, left, up, right, down, enter, escape, cancel, eof };
    pub const PrivateInputPortType = struct {
        pub const View = struct { field: u8, secret_length: u8, invalid: u8, text: [*]const u8, text_length: usize };
        context: *anyopaque,
        key: *const fn (*anyopaque, PrivateInputKey) bool,
        close: *const fn (*anyopaque) void,
        snapshot: *const fn (*anyopaque, *View) bool,
    };
    private_input: ?PrivateInputPortType = null,
    fn attachPrivateInput(self: *@This(), port: PrivateInputPortType) bool {
        if (self.private_input != null) return false;
        self.private_input = port;
        return true;
    }
    fn detachPrivateInput(self: *@This()) void {
        const port = self.private_input orelse return;
        self.private_input = null;
        port.close(port.context);
    }
    fn send(self: *@This(), key: PrivateInputKey) bool {
        const port = self.private_input orelse return false;
        return port.key(port.context, key);
    }
};
const TestJourneyController = struct {
    next: State = .handshaking,
    canceled: bool = false,
    fn beginProfile(_: *@This(), _: *const Profile, _: u64, _: u64, _: u64, _: u16, _: u32) !void {}
    fn pollProfile(self: *@This(), _: *const Profile, _: u64, _: ?*const ExchangeEntropy, _: *const [32]u8) !State {
        return self.next;
    }
    fn cancel(self: *@This()) void {
        self.canceled = true;
    }
    fn retryCleanup(_: *@This()) bool {
        return true;
    }
};

test "journey wipes the signing seed after authentication and profile on close" {
    var model: TestPrivateModel = .{};
    var controller: TestJourneyController = .{};
    // SAFETY: initInPlace initializes the owner before use.
    var journey: Journey(TestPrivateModel, TestJourneyController) = undefined;
    journey.initInPlace(&model, &controller);
    try std.testing.expect(journey.start());
    for ([_][]const u8{ "10.0.2.2", "22", "alice", "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", "0101010101010101010101010101010101010101010101010101010101010101" }) |value| {
        for (value) |byte| try std.testing.expect(model.send(.{ .text = byte }));
        if (journey.setup.form.selected == .seed) {
            const port = model.private_input.?;
            try std.testing.expect(!model.send(.{ .text = 'z' }));
            // SAFETY: a successful snapshot fills this descriptor.
            var view: TestPrivateModel.PrivateInputPortType.View = undefined;
            try std.testing.expect(port.snapshot(port.context, &view));
            try std.testing.expectEqual(@as(usize, 0), view.text_length);
            try std.testing.expectEqual(@as(u8, 64), view.secret_length);
            try std.testing.expectEqual(@as(u8, 1), view.invalid);
            try std.testing.expect(model.send(.backspace));
            try std.testing.expect(model.send(.{ .text = '1' }));
            try std.testing.expect(port.snapshot(port.context, &view));
            try std.testing.expectEqual(@as(u8, 0), view.invalid);
        }
        try std.testing.expect(model.send(.enter));
    }
    try journey.begin(10, 100, 20, 50001, 123);
    const padding: [32]u8 = @splat(5);
    try std.testing.expectEqual(State.handshaking, try journey.poll(11, null, &padding));
    try std.testing.expectEqual(@as(u8, 1), journey.profile.seed[0]);
    controller.next = .ready;
    try std.testing.expectEqual(State.ready, try journey.poll(12, null, &padding));
    for (journey.profile.seed) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    try std.testing.expect(journey.profile.valid);
    controller.next = .closed;
    try std.testing.expectEqual(State.closed, try journey.poll(13, null, &padding));
    try std.testing.expectEqual(@TypeOf(journey).Status.closed, journey.status);
    for (std.mem.asBytes(&journey.profile)) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
}

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

test "profile form masks and clears key input on submit and cancel" {
    var form: ProfileForm = .{};
    var profile: Profile = .{};
    const values = [_][]const u8{
        "10.0.2.2",
        "22",
        "alice",
        "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "0101010101010101010101010101010101010101010101010101010101010101",
    };
    for (values) |value| {
        for (value) |byte| try form.append(byte);
        if (form.selected == .seed) {
            try std.testing.expectEqualStrings("", form.display(.seed));
            try std.testing.expectEqual(@as(usize, 64), form.length(.seed));
            try std.testing.expectError(error.Full, form.append('a'));
            try std.testing.expectError(error.InvalidInput, form.append('z'));
        }
        form.next();
    }
    try form.submit(&profile);
    try std.testing.expect(profile.valid);
    try std.testing.expectEqualStrings("alice", profile.user());
    for (std.mem.asBytes(&form)) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    form.selected = .seed;
    try form.append('a');
    form.backspace();
    try std.testing.expectEqual(@as(u8, 0), form.fields[4][0]);
    try form.append('b');
    form.clear();
    for (std.mem.asBytes(&form)) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    profile.clear();
}

test "profile form rejects malformed fields without changing existing profile" {
    var form: ProfileForm = .{};
    var profile: Profile = .{};
    try profile.set("10.0.2.2", "22", "alice", "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", "0101010101010101010101010101010101010101010101010101010101010101");
    try form.append('1');
    try std.testing.expectError(error.InvalidProfile, form.submit(&profile));
    try std.testing.expectEqualStrings("alice", profile.user());
    try std.testing.expectEqualStrings("1", form.display(.address));
    form.clear();
    profile.clear();
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
