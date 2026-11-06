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
// OpenSSH SHA256 fingerprints use canonical, unpadded RFC 4648 base64.
// Decode directly to avoid retaining a general-purpose decoder table on device.
fn decodeFingerprint(encoded: []const u8, output: *[32]u8) error{InvalidProfile}!void {
    if (encoded.len != 43) return error.InvalidProfile;
    var bits: u5 = 0;
    var pending: u32 = 0;
    var written: usize = 0;
    for (encoded) |c| {
        const value: u32 = switch (c) {
            'A'...'Z' => c - 'A',
            'a'...'z' => c - 'a' + 26,
            '0'...'9' => c - '0' + 52,
            '+' => 62,
            '/' => 63,
            else => return error.InvalidProfile,
        };
        pending = (pending << 6) | value;
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            if (written >= output.len) return error.InvalidProfile;
            output[written] = @intCast((pending >> bits) & 0xff);
            written += 1;
            pending &= (@as(u32, 1) << bits) - 1;
        }
    }
    if (written != output.len or bits != 2 or pending != 0) return error.InvalidProfile;
}

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
        try decodeFingerprint(fingerprint[7..], &next.pin);
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
        const port = self.slice(.port);
        try profile.set(self.slice(.address), if (port.len == 0) "22" else port, self.slice(.username), self.slice(.fingerprint), self.slice(.seed));
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

/// Foreground driver for one journey. Entropy must be a qualified source:
/// available() must fail closed and fill() must be bounded and nonblocking,
/// filling every requested byte with fresh cryptographic randomness or returning
/// an error. This type supplies no entropy and stores none between ticks.
pub fn App(comptime JourneyType: type, comptime Entropy: type) type {
    return struct {
        const Self = @This();
        pub const Status = enum { idle, editing, connecting, connected, closing, closed, failed };
        journey: *JourneyType,
        entropy: *Entropy,
        connect_timeout_us: u64,
        close_timeout_us: u64,
        status: Status = .idle,

        pub fn init(journey: *JourneyType, entropy: *Entropy, connect_timeout_us: u64, close_timeout_us: u64) !Self {
            if (connect_timeout_us == 0 or close_timeout_us == 0) return error.InvalidArgument;
            return .{ .journey = journey, .entropy = entropy, .connect_timeout_us = connect_timeout_us, .close_timeout_us = close_timeout_us };
        }
        /// Do not collect credentials without a currently available source.
        pub fn start(self: *Self) !void {
            if (self.status != .idle or self.journey.controller.state != .idle) return error.InvalidState;
            if (!self.entropy.available()) return error.EntropyUnavailable;
            if (!self.journey.start()) return error.UiBusy;
            self.status = .editing;
        }
        /// Caller polls the network owner separately before each foreground tick.
        pub fn tick(self: *Self, now: u64) !Status {
            return self.advance(now) catch |err| {
                self.journey.cancel();
                self.status = .failed;
                return err;
            };
        }
        fn advance(self: *Self, now: u64) !Status {
            if (self.status == .editing) {
                if (self.journey.syncSetup() == .closed) {
                    self.status = .closed;
                    return .closed;
                }
                if (!self.entropy.available()) return error.EntropyUnavailable;
                if (self.journey.setup.status != .ready) return .editing;
                const deadline = std.math.add(u64, now, self.connect_timeout_us) catch return error.InvalidDeadline;
                var tuple: [6]u8 = @splat(0);
                defer std.crypto.secureZero(u8, &tuple);
                try self.entropy.fill(&tuple);
                const local_port = std.mem.readInt(u16, tuple[0..2], .big) & 0x3fff | 0xc000;
                const sequence = std.mem.readInt(u32, tuple[2..6], .big);
                try self.journey.begin(now, deadline, self.close_timeout_us, local_port, sequence);
                self.status = .connecting;
                return .connecting;
            }
            if (self.status != .connecting and self.status != .connected and self.status != .closing) return error.InvalidState;
            const state = self.journey.controller.state;
            if (state != .closing and !self.entropy.available()) return error.EntropyUnavailable;
            var padding: [32]u8 = @splat(0);
            var exchange: ExchangeEntropy = .{ .secret = @splat(0), .cookie = @splat(0) };
            defer std.crypto.secureZero(u8, &padding);
            defer std.crypto.secureZero(u8, std.mem.asBytes(&exchange));
            // These states do not encode SSH packets, so no padding is consumed.
            if (state == .handshaking or state == .ready) try self.entropy.fill(&padding);
            const supplied: ?*const ExchangeEntropy = if (state == .need_material) blk: {
                try self.entropy.fill(&exchange.secret);
                try self.entropy.fill(&exchange.cookie);
                break :blk &exchange;
            } else null;
            const result = try self.journey.poll(now, supplied, &padding);
            self.status = switch (result) {
                .opening, .need_material, .handshaking => .connecting,
                .ready => .connected,
                .closing => .closing,
                .closed => .closed,
                .idle, .failed => return error.InvalidState,
            };
            return self.status;
        }
        pub fn cancel(self: *Self) void {
            self.journey.cancel();
            self.status = .closed;
        }
        pub fn retryCleanup(self: *Self) bool {
            return self.journey.retryCleanup();
        }
    };
}

/// One visit to the SSH screen. Poll after the network owner and after input
/// delivery; the owner must stop this visit before replacing the xy model.
/// A failed start is not retried until a fresh visit is initialized.
pub fn Foreground(comptime Model: type, comptime SessionController: type, comptime Entropy: type) type {
    return struct {
        const Self = @This();
        const JourneyType = Journey(Model, SessionController);
        const AppType = App(JourneyType, Entropy);
        pub const Status = AppType.Status;
        journey: JourneyType,
        app: AppType,
        attempted: bool = false,

        /// Initialize only fresh storage or after stop returned true.
        pub fn initInPlace(self: *Self, model: *Model, controller: *SessionController, entropy: *Entropy, connect_timeout_us: u64, close_timeout_us: u64) !void {
            self.journey.initInPlace(model, controller);
            self.app = try AppType.init(&self.journey, entropy, connect_timeout_us, close_timeout_us);
            self.attempted = false;
        }
        pub fn poll(self: *Self, visible: bool, now: u64) !Status {
            if (!visible) {
                if (!self.stop()) return error.CleanupPending;
                return .closed;
            }
            if (!self.attempted) {
                self.attempted = true;
                try self.app.start();
            }
            return switch (self.app.status) {
                .editing, .connecting, .connected, .closing => try self.app.tick(now),
                .idle, .closed, .failed => self.app.status,
            };
        }
        /// Never recycle the controller or model while cleanup has failed.
        pub fn stop(self: *Self) bool {
            if (self.attempted and self.app.status != .idle and self.app.status != .closed and self.app.status != .failed) self.app.cancel();
            return self.app.retryCleanup();
        }
    };
}

/// Prepare entropy without blocking the UI or attaching a credential form.
/// The session and this object must stay in stable storage until stop finishes.
/// Neither this coordinator nor its tests qualify the entropy backend.
pub fn PreparedForeground(comptime Model: type, comptime ControllerType: type, comptime EntropySession: type) type {
    return struct {
        const Self = @This();
        const Visit = Foreground(Model, ControllerType, EntropySession);
        pub const State = enum { idle, preparing, active, stopping, finished, failed };
        model: *Model,
        controller: *ControllerType,
        entropy: *EntropySession,
        visit: Visit = undefined,
        visit_live: bool = false,
        state: Self.State = .idle,
        seed_timeout: u64,
        connect_timeout: u64,
        close_timeout: u64,

        pub fn init(model: *Model, controller: *ControllerType, entropy: *EntropySession, seed_timeout: u64, connect_timeout: u64, close_timeout: u64) !Self {
            if (seed_timeout == 0 or connect_timeout == 0 or close_timeout == 0) return error.InvalidArgument;
            return .{ .model = model, .controller = controller, .entropy = entropy, .seed_timeout = seed_timeout, .connect_timeout = connect_timeout, .close_timeout = close_timeout };
        }

        /// Call once per foreground tick, after servicing the network. A
        /// failed visit is not retried while the SSH screen remains visible.
        pub fn poll(self: *Self, visible: bool, now: u64) Self.State {
            if (!visible and self.state != .idle and self.state != .stopping) self.beginStop();
            switch (self.state) {
                .idle => if (visible) {
                    self.entropy.begin(now, self.seed_timeout) catch {
                        self.state = .failed;
                        return self.state;
                    };
                    self.state = .preparing;
                },
                .preparing => {
                    self.entropy.poll(now);
                    if (self.entropy.state == .failed) {
                        self.entropy.cancel();
                        self.state = .failed;
                    } else if (self.entropy.available()) {
                        self.visit.initInPlace(self.model, self.controller, self.entropy, self.connect_timeout, self.close_timeout) catch {
                            self.entropy.cancel();
                            self.state = .failed;
                            return self.state;
                        };
                        self.visit_live = true;
                        self.state = .active;
                    }
                },
                .active => {
                    const status = self.visit.poll(true, now) catch {
                        self.beginStop();
                        return self.state;
                    };
                    if (status == .closed or status == .failed) self.beginStop();
                },
                .stopping => {
                    if (self.visit_live and self.visit.stop()) self.visit_live = false;
                    self.entropy.poll(now);
                    if (!self.visit_live and self.entropy.state == .idle) self.state = if (visible) .finished else .idle;
                },
                .failed => self.entropy.poll(now),
                .finished => {},
            }
            return self.state;
        }

        fn beginStop(self: *Self) void {
            // Retain the visit and its model until transport cleanup succeeds.
            if (self.visit_live and self.visit.stop()) self.visit_live = false;
            self.entropy.cancel();
            self.state = .stopping;
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
    state: State = .idle,
    canceled: bool = false,
    local_port: u16 = 0,
    sequence: u32 = 0,
    exchange_seen: bool = false,
    cleanup_ok: bool = true,
    fn beginProfile(self: *@This(), _: *const Profile, _: u64, _: u64, _: u64, local_port: u16, sequence: u32) !void {
        self.local_port = local_port;
        self.sequence = sequence;
        self.state = .opening;
    }
    fn pollProfile(self: *@This(), _: *const Profile, _: u64, exchange: ?*const ExchangeEntropy, _: *const [32]u8) !State {
        self.exchange_seen = exchange != null;
        self.state = self.next;
        return self.next;
    }
    fn cancel(self: *@This()) void {
        self.canceled = true;
    }
    fn retryCleanup(self: *@This()) bool {
        return self.cleanup_ok;
    }
};

test "foreground visit gates secrets and cleans up before reuse" {
    var model: TestPrivateModel = .{};
    var controller: TestJourneyController = .{};
    var entropy: TestEntropy = .{ .online = false };
    // SAFETY: initInPlace initializes the visit before use.
    var foreground: Foreground(TestPrivateModel, TestJourneyController, TestEntropy) = undefined;
    try foreground.initInPlace(&model, &controller, &entropy, 100, 20);
    try std.testing.expectError(error.EntropyUnavailable, foreground.poll(true, 1));
    try std.testing.expect(model.private_input == null);
    entropy.online = true;
    try std.testing.expectEqual(@TypeOf(foreground).Status.idle, try foreground.poll(true, 2));
    try std.testing.expect(foreground.stop());
    try foreground.initInPlace(&model, &controller, &entropy, 100, 20);
    try std.testing.expectEqual(@TypeOf(foreground).Status.editing, try foreground.poll(true, 3));
    foreground.journey.setup.form.selected = .seed;
    try std.testing.expect(model.send(.{ .text = 'a' }));
    try std.testing.expectEqual(@TypeOf(foreground).Status.closed, try foreground.poll(false, 4));
    try std.testing.expect(model.private_input == null);
    for (std.mem.asBytes(&foreground.journey.setup.form)) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    try foreground.initInPlace(&model, &controller, &entropy, 100, 20);
    _ = try foreground.poll(true, 5);
    for ([_][]const u8{ "10.0.2.2", "22", "alice", "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", "0101010101010101010101010101010101010101010101010101010101010101" }) |value| {
        for (value) |byte| try std.testing.expect(model.send(.{ .text = byte }));
        try std.testing.expect(model.send(.enter));
    }
    try std.testing.expectEqual(@TypeOf(foreground).Status.connecting, try foreground.poll(true, 6));
    controller.cleanup_ok = false;
    try std.testing.expectError(error.CleanupPending, foreground.poll(false, 7));
    try std.testing.expect(controller.canceled);
    for (std.mem.asBytes(&foreground.journey.profile)) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    controller.cleanup_ok = true;
    try std.testing.expect(foreground.stop());
}

const TestEntropy = struct {
    online: bool = true,
    fail: bool = false,
    fail_on: u32 = 0,
    calls: u32 = 0,
    fn available(self: *@This()) bool {
        return self.online;
    }
    fn fill(self: *@This(), bytes: []u8) !void {
        self.calls += 1;
        if (!self.online or self.fail or self.calls == self.fail_on) {
            @memset(bytes, 0xaa); // Model a source failing after a partial write.
            return error.EntropyUnavailable;
        }
        @memset(bytes, @intCast(self.calls));
    }
};

test "app refuses unavailable entropy and cancels safely if it fails later" {
    var model: TestPrivateModel = .{};
    var controller: TestJourneyController = .{};
    // SAFETY: initInPlace initializes the owner before use.
    var journey: Journey(TestPrivateModel, TestJourneyController) = undefined;
    journey.initInPlace(&model, &controller);
    var entropy: TestEntropy = .{ .online = false };
    var app = try App(@TypeOf(journey), TestEntropy).init(&journey, &entropy, 100, 20);
    try std.testing.expectError(error.EntropyUnavailable, app.start());
    try std.testing.expect(model.private_input == null and !journey.profile.valid);
    entropy.online = true;
    controller.state = .closed;
    try std.testing.expectError(error.InvalidState, app.start());
    try std.testing.expect(model.private_input == null);
    controller.state = .idle;
    try app.start();
    for ([_][]const u8{ "10.0.2.2", "22", "alice", "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", "0101010101010101010101010101010101010101010101010101010101010101" }) |value| {
        for (value) |byte| try std.testing.expect(model.send(.{ .text = byte }));
        try std.testing.expect(model.send(.enter));
    }
    try std.testing.expectEqual(@TypeOf(app).Status.connecting, try app.tick(10));
    try std.testing.expectEqual(@as(u16, 0xc101), controller.local_port);
    try std.testing.expectEqual(@as(u32, 0x01010101), controller.sequence);
    controller.next = .need_material;
    try std.testing.expectEqual(@TypeOf(app).Status.connecting, try app.tick(11));
    try std.testing.expectEqual(@as(u32, 1), entropy.calls);
    controller.next = .handshaking;
    try std.testing.expectEqual(@TypeOf(app).Status.connecting, try app.tick(12));
    try std.testing.expect(controller.exchange_seen);
    try std.testing.expectEqual(@as(u32, 3), entropy.calls);
    controller.next = .ready;
    try std.testing.expectEqual(@TypeOf(app).Status.connected, try app.tick(13));
    for (journey.profile.seed) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    entropy.fail = true;
    try std.testing.expectError(error.EntropyUnavailable, app.tick(14));
    try std.testing.expectEqual(@TypeOf(app).Status.failed, app.status);
    try std.testing.expect(controller.canceled and app.retryCleanup());
    for (std.mem.asBytes(&journey.profile)) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
}

test "app clears configured credentials when initial entropy fails" {
    var model: TestPrivateModel = .{};
    var controller: TestJourneyController = .{};
    // SAFETY: initInPlace initializes the owner before use.
    var journey: Journey(TestPrivateModel, TestJourneyController) = undefined;
    journey.initInPlace(&model, &controller);
    var entropy: TestEntropy = .{};
    var app = try App(@TypeOf(journey), TestEntropy).init(&journey, &entropy, 100, 20);
    try app.start();
    for ([_][]const u8{ "10.0.2.2", "22", "alice", "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", "0101010101010101010101010101010101010101010101010101010101010101" }) |value| {
        for (value) |byte| try std.testing.expect(model.send(.{ .text = byte }));
        try std.testing.expect(model.send(.enter));
    }
    entropy.fail = true;
    try std.testing.expectError(error.EntropyUnavailable, app.tick(10));
    try std.testing.expectEqual(@TypeOf(app).Status.failed, app.status);
    try std.testing.expect(model.private_input == null and controller.state == .idle);
    for (std.mem.asBytes(&journey.profile)) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
}

test "app erases an unfinished private form if entropy becomes unavailable" {
    var model: TestPrivateModel = .{};
    var controller: TestJourneyController = .{};
    // SAFETY: initInPlace initializes the owner before use.
    var journey: Journey(TestPrivateModel, TestJourneyController) = undefined;
    journey.initInPlace(&model, &controller);
    var entropy: TestEntropy = .{};
    var app = try App(@TypeOf(journey), TestEntropy).init(&journey, &entropy, 100, 20);
    try app.start();
    journey.setup.form.selected = .seed;
    try std.testing.expect(model.send(.{ .text = 'a' }));
    entropy.online = false;
    try std.testing.expectError(error.EntropyUnavailable, app.tick(10));
    try std.testing.expectEqual(@TypeOf(app).Status.failed, app.status);
    try std.testing.expect(model.private_input == null and controller.state == .idle);
    for (std.mem.asBytes(&journey.setup.form)) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    for (std.mem.asBytes(&journey.profile)) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
}

test "app cancels when entropy fails after creating the exchange secret" {
    var model: TestPrivateModel = .{};
    var controller: TestJourneyController = .{};
    // SAFETY: initInPlace initializes the owner before use.
    var journey: Journey(TestPrivateModel, TestJourneyController) = undefined;
    journey.initInPlace(&model, &controller);
    var entropy: TestEntropy = .{ .fail_on = 3 };
    var app = try App(@TypeOf(journey), TestEntropy).init(&journey, &entropy, 100, 20);
    try app.start();
    for ([_][]const u8{ "10.0.2.2", "22", "alice", "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", "0101010101010101010101010101010101010101010101010101010101010101" }) |value| {
        for (value) |byte| try std.testing.expect(model.send(.{ .text = byte }));
        try std.testing.expect(model.send(.enter));
    }
    try std.testing.expectEqual(@TypeOf(app).Status.connecting, try app.tick(10));
    controller.next = .need_material;
    try std.testing.expectEqual(@TypeOf(app).Status.connecting, try app.tick(11));
    try std.testing.expectError(error.EntropyUnavailable, app.tick(12));
    try std.testing.expectEqual(@as(u32, 3), entropy.calls);
    try std.testing.expect(controller.canceled and app.retryCleanup());
    for (std.mem.asBytes(&journey.profile)) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
}

test "app can finish a TCP close without consuming entropy" {
    var model: TestPrivateModel = .{};
    var controller: TestJourneyController = .{ .state = .closing, .next = .closed };
    // SAFETY: initInPlace initializes the owner before use.
    var journey: Journey(TestPrivateModel, TestJourneyController) = undefined;
    journey.initInPlace(&model, &controller);
    journey.status = .active;
    journey.profile.valid = true;
    var entropy: TestEntropy = .{ .online = false };
    var app = try App(@TypeOf(journey), TestEntropy).init(&journey, &entropy, 100, 20);
    app.status = .closing;
    try std.testing.expectEqual(@TypeOf(app).Status.closed, try app.tick(10));
    try std.testing.expectEqual(@as(u32, 0), entropy.calls);
    for (std.mem.asBytes(&journey.profile)) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
}

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

test "fingerprint decoder accepts canonical base64 and rejects noncanonical input" {
    for (0..256) |seed| {
        var expected: [32]u8 = undefined;
        for (&expected, 0..) |*byte, i| byte.* = @truncate(seed +% (i *% 73));
        var text: [43]u8 = undefined;
        _ = std.base64.standard_no_pad.Encoder.encode(&text, &expected);
        var actual: [32]u8 = undefined;
        try decodeFingerprint(&text, &actual);
        try std.testing.expectEqualSlices(u8, &expected, &actual);
        const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        const last = std.mem.indexOfScalar(u8, alphabet, text[42]) orelse unreachable;
        text[42] = alphabet[last + 1];
        try std.testing.expectError(error.InvalidProfile, decodeFingerprint(&text, &actual));
        text[0] = '=';
        try std.testing.expectError(error.InvalidProfile, decodeFingerprint(&text, &actual));
    }
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
        "2222",
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
    try std.testing.expectEqual(@as(u16, 2222), profile.port);
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

test "profile form uses SSH default only for an empty port" {
    var form: ProfileForm = .{};
    var profile: Profile = .{};
    for ([_][]const u8{
        "10.0.2.2",                                           "",                                                                 "alice",
        "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", "0101010101010101010101010101010101010101010101010101010101010101",
    }) |value| {
        for (value) |byte| try form.append(byte);
        form.next();
    }
    try form.submit(&profile);
    try std.testing.expectEqual(@as(u16, 22), profile.port);
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

const PreparedTestBackend = struct {
    held: bool = false,
    release_ready: bool = false,
    fail: bool = false,
    byte: u8 = 1,
    pub fn begin(self: *@This()) !void {
        if (self.held) return error.Busy;
        self.held = true;
    }
    pub fn owned(self: *@This()) bool {
        return self.held;
    }
    pub fn sample(self: *@This()) !?u8 {
        if (self.fail) return error.SampleFailed;
        defer self.byte +%= 1;
        return self.byte;
    }
    pub fn release(self: *@This()) bool {
        if (!self.release_ready) return false;
        self.held = false;
        return true;
    }
};

test "prepared foreground waits for entropy and cleanup before credentials" {
    const entropy = @import("ssh_entropy_session.zig");
    const Session = entropy.Session(PreparedTestBackend);
    var backend: PreparedTestBackend = .{};
    var generations: entropy.Generations = .{};
    var session = Session.init(&backend, &generations);
    var model: TestPrivateModel = .{};
    var controller: TestJourneyController = .{};
    var prepared = try PreparedForeground(TestPrivateModel, TestJourneyController, Session).init(&model, &controller, &session, 200, 100, 20);
    try std.testing.expectEqual(.preparing, prepared.poll(true, 0));
    for (0..40) |_| {
        _ = prepared.poll(true, 1);
        try std.testing.expect(model.private_input == null);
    }
    try std.testing.expectEqual(.restoring, session.state);
    backend.release_ready = true;
    try std.testing.expectEqual(.active, prepared.poll(true, 2));
    try std.testing.expect(model.private_input == null);
    try std.testing.expectEqual(.active, prepared.poll(true, 3));
    try std.testing.expect(model.private_input != null);
    for ([_][]const u8{ "10.0.2.2", "22", "alice", "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", "0101010101010101010101010101010101010101010101010101010101010101" }) |value| {
        for (value) |byte| try std.testing.expect(model.send(.{ .text = byte }));
        try std.testing.expect(model.send(.enter));
    }
    try std.testing.expectEqual(.active, prepared.poll(true, 3));
    try std.testing.expectEqual(State.opening, controller.state);
    controller.cleanup_ok = false;
    try std.testing.expectEqual(.stopping, prepared.poll(false, 4));
    try std.testing.expect(model.private_input == null);
    try std.testing.expect(!session.available());
    try std.testing.expectEqual(.stopping, prepared.poll(true, 5));
    try std.testing.expectEqual(@as(u64, 1), generations.last);
    controller.cleanup_ok = true;
    try std.testing.expectEqual(.finished, prepared.poll(true, 6));
    try std.testing.expectEqual(.idle, prepared.poll(false, 7));
    try std.testing.expectEqual(.preparing, prepared.poll(true, 9));
    try std.testing.expectEqual(@as(u64, 2), generations.last);
}

test "prepared foreground cancellation and entropy failure never open credentials" {
    const entropy = @import("ssh_entropy_session.zig");
    const Session = entropy.Session(PreparedTestBackend);
    var backend: PreparedTestBackend = .{};
    var generations: entropy.Generations = .{};
    var session = Session.init(&backend, &generations);
    var model: TestPrivateModel = .{};
    var controller: TestJourneyController = .{};
    var prepared = try PreparedForeground(TestPrivateModel, TestJourneyController, Session).init(&model, &controller, &session, 200, 100, 20);
    _ = prepared.poll(true, 0);
    _ = prepared.poll(true, 1);
    try std.testing.expectEqual(.stopping, prepared.poll(false, 2));
    try std.testing.expectEqual(.stopping, prepared.poll(true, 3));
    try std.testing.expect(model.private_input == null and backend.held);
    backend.release_ready = true;
    try std.testing.expectEqual(.finished, prepared.poll(true, 4));
    _ = prepared.poll(false, 5);
    _ = prepared.poll(false, 6);
    backend.fail = true;
    try std.testing.expectEqual(.preparing, prepared.poll(true, 7));
    _ = prepared.poll(true, 8);
    try std.testing.expectEqual(.failed, prepared.poll(true, 9));
    _ = prepared.poll(true, 10);
    try std.testing.expect(model.private_input == null and !session.available());
    try std.testing.expectEqual(@as(u64, 2), generations.last);
}
