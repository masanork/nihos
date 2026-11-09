//! Host-only ABI for exercising the xy VT bridge with a real SSH backend.
const xy = @import("ssh_terminal_session");
const console = @import("text_console");
const terminal = @import("terminal_adapter");
const Read = *const fn (*const [32]u8, [*]u8, usize) callconv(.c) isize;
const Write = *const fn (*const [32]u8, [*]const u8, usize) callconv(.c) isize;
const Poll = *const fn (*const [32]u8, [*]const u8, usize, *const [32]u8) callconv(.c) isize;
const Backend = struct {
    read_fn: Read,
    write_fn: Write,
    poll_fn: Poll,
    const Status = enum { connecting, ready, closed };
    pub fn poll(self: *@This(), _: u64, random: *const [32]u8, user: []const u8, seed: [32]u8) !Status {
        return switch (self.poll_fn(random, user.ptr, user.len, &seed)) {
            0 => .connecting,
            1 => .ready,
            2 => .closed,
            -2 => error.HostKeyMismatch,
            else => error.Backend,
        };
    }
    pub fn read(self: *@This(), _: u64, random: *const [32]u8, dst: []u8) !usize {
        const n = self.read_fn(random, dst.ptr, dst.len);
        if (n < 0) return error.Backend;
        return @intCast(n);
    }
    pub fn write(self: *@This(), _: u64, random: *const [32]u8, src: []const u8) !usize {
        const n = self.write_fn(random, src.ptr, src.len);
        if (n < 0) return error.Backend;
        return @intCast(n);
    }
    pub fn abort(_: *@This()) void {}
};
const Ui = xy.Session(Backend, 80, 24, 8);
// SAFETY: probe_vt_begin initializes both objects before any other call.
var backend: Backend = undefined;
// SAFETY: probe_vt_begin initializes this stable object before any other call.
var ui: Ui = undefined;
// SAFETY: probe_vt_begin initializes the stable model before use.
var model: console.scratch.Model = undefined;
var initialized = false;
export fn probe_vt_begin(poll: Poll, read: Read, write: Write) void {
    backend = .{ .poll_fn = poll, .read_fn = read, .write_fn = write };
    ui.initInPlace(&backend, "OpenSSH");
    model.initInPlace();
    initialized = true;
}
export fn probe_vt_poll(random: *const [32]u8, user: [*]const u8, len: usize, seed: *const [32]u8) isize {
    if (!initialized) return -1;
    const state = ui.poll(0, random, user[0..len], seed.*) catch {
        model.detachTerminal();
        return -1;
    };
    return switch (state) {
        .connecting => 0,
        .ready => blk: {
            if (model.terminal == null and !model.attachTerminal(ui.port(console.scratch.TerminalPort))) break :blk -1;
            model.terminalChanged();
            break :blk 1;
        },
        .closed => blk: {
            model.detachTerminal();
            break :blk 2;
        },
        .failed => -1,
    };
}
export fn probe_vt_key(cp: u32) bool {
    if (!initialized or cp > 127 or model.terminal == null) return false;
    model.handle(.{ .text = @intCast(cp) });
    return model.status != .buffer_full;
}
export fn probe_vt_cell(index: usize) u32 {
    if (!initialized or index >= 80 * 24) return 0;
    // SAFETY: a successful snapshot initializes every descriptor field.
    var snapshot: console.xy_render_protocol.TerminalView = undefined;
    if (!model.terminalSnapshot(&snapshot)) return 0;
    const cells: [*]const terminal.Cell = @ptrCast(@alignCast(snapshot.cells));
    return cells[index].codepoint;
}

const lifecycle = @import("ssh_lifecycle");
const seeded_entropy = lifecycle.seeded_entropy;
const Start = *const fn (*const [16]u8, *const [32]u8, *const [32]u8) callconv(.c) bool;
const Action = *const fn () callconv(.c) bool;
const Fill = *const fn ([*]u8, usize) callconv(.c) bool;
const HostNetwork = struct {
    pub const Handle = u8;
    pub const Owner = Backend;
    start: Start,
    ready_fn: Action,
    release_fn: Action,
    cancel_fn: Action,
    close_fn: Action,
    complete_fn: Action,
    pub fn open(_: *@This(), remote: [4]u8, port: u16, local: u16, _: u32, deadline: u64) !Handle {
        if (!@import("std").mem.eql(u8, &remote, &.{ 10, 0, 2, 2 }) or port != 22 or local < 49152 or deadline == 0) return error.InvalidDestination;
        return 1;
    }
    pub fn ready(self: *@This(), _: Handle) !bool {
        return self.ready_fn();
    }
    pub fn startSsh(self: *@This(), _: Handle, _: u64, secret: [32]u8, pin: [32]u8, cookie: [16]u8, _: u32, _: u32) !*Owner {
        if (!self.start(&cookie, &secret, &pin)) return error.Backend;
        return &backend;
    }
    pub fn releaseSsh(self: *@This(), _: *Owner) !void {
        if (!self.release_fn()) return error.Backend;
    }
    pub fn cancel(self: *@This(), _: Handle) !void {
        if (!self.cancel_fn()) return error.Backend;
    }
    pub fn closeWrite(self: *@This(), _: Handle, _: u64) !void {
        if (!self.close_fn()) return error.Backend;
    }
    pub fn closeComplete(self: *@This(), _: Handle) !bool {
        return self.complete_fn();
    }
};
const Controller = lifecycle.Controller(HostNetwork, Ui, console.scratch.Model);
const HostEntropy = struct {
    fill_fn: Fill,
    generator: seeded_entropy.Entropy = .{},
    seeded: bool = false,
    pub fn available(self: *@This()) bool {
        return if (self.seeded) self.generator.available() else true;
    }
    pub fn fill(self: *@This(), out: []u8) !void {
        if (self.seeded) return self.generator.fill(out);
        if (!self.fill_fn(out.ptr, out.len)) return error.EntropyUnavailable;
    }
    fn clear(self: *@This()) void {
        self.generator.clear();
    }
};
const HostSeedSource = struct {
    fill_fn: Fill,
    pub fn lease(_: *@This()) ?u64 {
        return 1; // Host-only: the callback supplies OS cryptographic random bytes.
    }
    pub fn fillSeed(self: *@This(), generation: u64, out: *[seeded_entropy.seed_bytes]u8) !void {
        if (generation != 1) return error.EntropyUnavailable;
        if (!self.fill_fn(out, out.len)) return error.EntropyUnavailable;
    }
};
const HostJourney = lifecycle.Journey(console.scratch.Model, Controller);
const HostForeground = lifecycle.Foreground(console.scratch.Model, Controller, HostEntropy);
// Host-only adapter: OS random bytes seed the same CSPRNG used by the visit.
// This cannot qualify the native P4 entropy source or its resource owner.
const PreparedEntropy = struct {
    host: HostEntropy,
    state: enum { idle, collecting, restoring, ready, cleaning, failed } = .idle,
    pub fn begin(self: *@This(), _: u64, _: u64) !void {
        if (self.state != .idle) return error.Busy;
        self.state = .collecting;
    }
    pub fn poll(self: *@This(), _: u64) void {
        switch (self.state) {
            .collecting => {
                var source: HostSeedSource = .{ .fill_fn = self.host.fill_fn };
                self.host.generator.seedFrom(&source) catch {
                    self.state = .failed;
                    return;
                };
                self.host.seeded = true;
                self.state = .restoring;
            },
            .restoring => self.state = .ready,
            .cleaning => self.state = .idle,
            else => {},
        }
    }
    pub fn cancel(self: *@This()) void {
        self.host.clear();
        if (self.state != .idle) self.state = .cleaning;
    }
    pub fn available(self: *@This()) bool {
        return self.state == .ready and self.host.available();
    }
    pub fn fill(self: *@This(), out: []u8) !void {
        if (!self.available()) return error.EntropyUnavailable;
        try self.host.fill(out);
    }
};
const PreparedTimer = struct {
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
const PreparedWorkspace = struct {
    controller: Controller,
    pub fn initInPlace(self: *@This(), m: *console.scratch.Model, u: *Ui) !void {
        self.controller = Controller.init(&host_network, u, m);
    }
};
const PreparedVisit = lifecycle.TimedPreparedForeground(console.scratch.Model, Controller, PreparedEntropy, PreparedTimer);
const HostPreparedRuntime = lifecycle.PreparedRuntime(console.scratch.Model, Ui, PreparedWorkspace, PreparedVisit, PreparedEntropy, PreparedTimer);
// SAFETY: the lifecycle begin function initializes these before use.
var prepared_entropy: PreparedEntropy = undefined;
// SAFETY: the lifecycle begin function initializes these before use.
var prepared_timer: PreparedTimer = undefined;
// SAFETY: the lifecycle begin function initializes these before use.
var prepared_runtime: HostPreparedRuntime = undefined;
var use_prepared_runtime = false;
// SAFETY: probe_lifecycle_begin initializes these stable objects before use.
var host_network: HostNetwork = undefined;
// SAFETY: probe_lifecycle_begin initializes this stable object before use.
var controller: Controller = undefined;
// SAFETY: probe_lifecycle_begin initializes this stable owner before use.
var journey: HostJourney = undefined;
// SAFETY: probe_lifecycle_begin initializes these stable objects before use.
var host_entropy: HostEntropy = undefined;
// SAFETY: probe_lifecycle_begin initializes the foreground app before use.
var foreground: HostForeground = undefined;
export fn probe_lifecycle_begin(poll: Poll, read: Read, write: Write, start: Start, ready: Action, release: Action, cancel: Action, close: Action, complete: Action, fill: Fill, use_seeded: bool, use_prepared: bool, now: u64, user: [*]const u8, user_len: usize, fingerprint: *const [50]u8, seed_hex: *const [64]u8) bool {
    initialized = false;
    use_prepared_runtime = use_prepared;
    model.initInPlace();
    model.nav.home();
    model.handle(.{ .text = 't' });
    if (model.nav.screen != .ssh) return false;
    backend = .{ .poll_fn = poll, .read_fn = read, .write_fn = write };
    host_network = .{ .start = start, .ready_fn = ready, .release_fn = release, .cancel_fn = cancel, .close_fn = close, .complete_fn = complete };
    controller = Controller.init(&host_network, &ui, &model);
    journey.initInPlace(&model, &controller);
    if (!journey.start()) return false;
    journey.setup.form.selected = .seed;
    model.feedSerial('1', now);
    // SAFETY: a successful snapshot fills the descriptor before use.
    var masked: console.xy_render_protocol.PrivateInputView = undefined;
    if (!model.privateInputSnapshot(&masked) or masked.field != 4 or masked.secret_length != 1 or masked.text_length != 0) return false;
    model.handle(.escape);
    if (journey.syncSetup() != .closed or model.private_input != null or journey.profile.valid) return false;
    for (@import("std").mem.asBytes(&journey.setup.form)) |byte| if (byte != 0) return false;
    host_entropy = .{ .fill_fn = fill };
    if (use_prepared) prepared_entropy = .{ .host = .{ .fill_fn = fill } };
    defer if (!initialized) {
        host_entropy.clear();
        if (use_prepared) prepared_entropy.host.clear();
    };
    if (use_seeded and !use_prepared) {
        var source: HostSeedSource = .{ .fill_fn = fill };
        host_entropy.generator.seedFrom(&source) catch return false;
        host_entropy.seeded = true;
    }
    if (use_prepared) {
        prepared_timer = .{};
        prepared_runtime.initInPlace(&prepared_entropy, &prepared_timer);
        for (0..8) |_| {
            prepared_runtime.poll(&model, &ui, now);
            if (model.private_input != null) break;
        }
        if (model.private_input == null) return false;
    } else {
        foreground.initInPlace(&model, &controller, &host_entropy, 20_000_000, 20_000_000) catch return false;
        if ((foreground.poll(true, now) catch return false) != .editing) return false;
    }
    for ([_][]const u8{ "10.0.2.2", "", user[0..user_len], fingerprint, seed_hex }) |value| {
        for (value) |byte| {
            model.feedSerial(byte, now);
            if (model.status != .none) {
                if (use_prepared) prepared_runtime.poll(null, &ui, now) else _ = foreground.stop();
                return false;
            }
        }
        model.handle(.enter);
    }
    const setup_ready = if (use_prepared) prepared_runtime.visit.visit.visit.journey.setup.status == .ready else foreground.journey.setup.status == .ready;
    if (!setup_ready or model.private_input != null) {
        if (use_prepared) prepared_runtime.poll(null, &ui, now) else _ = foreground.stop();
        return false;
    }
    if (use_prepared) {
        prepared_runtime.poll(&model, &ui, now);
        if (prepared_runtime.workspace.controller.state != .opening) return false;
    } else if ((foreground.poll(true, now) catch return false) != .connecting) return false;
    initialized = true;
    return true;
}
export fn probe_lifecycle_poll(now: u64) isize {
    if (!initialized) return -1;
    if (use_prepared_runtime) {
        prepared_runtime.poll(&model, &ui, now);
        const visit = &prepared_runtime.visit.visit;
        return switch (visit.state) {
            .failed => -1,
            .finished, .idle => 2,
            .active => if (visit.visit.app.status == .connected) 1 else 0,
            else => 0,
        };
    }
    return switch (foreground.poll(model.nav.screen == .ssh, now) catch |err| {
        host_entropy.clear();
        return if (err == error.HostKeyMismatch) -2 else if (err == error.EntropyUnavailable) -3 else -1;
    }) {
        .editing, .connecting, .closing => 0,
        .connected => 1,
        .closed => blk: {
            host_entropy.clear();
            break :blk 2;
        },
        .idle, .failed => -1,
    };
}
export fn probe_profile_cleared() bool {
    if (use_prepared_runtime) {
        for (@import("std").mem.asBytes(&prepared_runtime.visit.visit.visit.journey.profile)) |byte| if (byte != 0) return false;
        return true;
    }
    for (@import("std").mem.asBytes(&foreground.journey.profile)) |byte| if (byte != 0) return false;
    return true;
}
export fn probe_seed_cleared() bool {
    if (use_prepared_runtime) {
        for (prepared_runtime.visit.visit.visit.journey.profile.seed) |byte| if (byte != 0) return false;
        return true;
    }
    for (foreground.journey.profile.seed) |byte| if (byte != 0) return false;
    return true;
}
export fn probe_lifecycle_leave(now: u64) bool {
    if (!initialized) return false;
    model.nav.home();
    if (use_prepared_runtime) {
        prepared_runtime.poll(&model, &ui, now);
        return !prepared_runtime.active and model.terminal == null and model.private_input == null and probe_profile_cleared();
    }
    if ((foreground.poll(false, now) catch return false) != .closed) return false;
    host_entropy.clear();
    return model.terminal == null and model.private_input == null and probe_profile_cleared();
}

test "real home model reaches SSH profile after prepared entropy cleanup" {
    const std = @import("std");
    const Entropy = struct {
        state: enum { idle, collecting, restoring, ready, cleaning, failed } = .idle,
        allow_restore: bool = false,
        pub fn begin(self: *@This(), _: u64, _: u64) !void {
            self.state = .collecting;
        }
        pub fn poll(self: *@This(), _: u64) void {
            if (self.state == .collecting) self.state = .restoring else if (self.state == .restoring and self.allow_restore) self.state = .ready else if (self.state == .cleaning) self.state = .idle;
        }
        pub fn cancel(self: *@This()) void {
            if (self.state != .idle) self.state = .cleaning;
        }
        pub fn available(self: *@This()) bool {
            return self.state == .ready;
        }
        pub fn fill(self: *@This(), out: []u8) !void {
            if (!self.available()) return error.EntropyUnavailable;
            @memset(out, 0x42);
        }
    };
    const Timer = struct {
        last: u64 = 0,
        pub fn observe(self: *@This(), now: u64) bool {
            if (now < self.last) return false;
            self.last = now;
            return true;
        }
    };
    const Workspace = struct {
        controller: Controller,
        pub fn initInPlace(self: *@This(), m: *console.scratch.Model, u: *Ui) !void {
            self.controller = Controller.init(&host_network, u, m);
        }
    };
    const Calls = struct {
        fn start(_: *const [16]u8, _: *const [32]u8, _: *const [32]u8) callconv(.c) bool {
            return true;
        }
        fn yes() callconv(.c) bool {
            return true;
        }
        fn no() callconv(.c) bool {
            return false;
        }
    };
    const Timed = lifecycle.TimedPreparedForeground(console.scratch.Model, Controller, Entropy, Timer);
    const Runtime = lifecycle.PreparedRuntime(console.scratch.Model, Ui, Workspace, Timed, Entropy, Timer);
    const owner = try std.testing.allocator.create(Runtime);
    defer std.testing.allocator.destroy(owner);
    const m = try std.testing.allocator.create(console.scratch.Model);
    defer std.testing.allocator.destroy(m);
    const u = try std.testing.allocator.create(Ui);
    defer std.testing.allocator.destroy(u);
    host_network = .{ .start = Calls.start, .ready_fn = Calls.no, .release_fn = Calls.yes, .cancel_fn = Calls.yes, .close_fn = Calls.yes, .complete_fn = Calls.yes };
    m.initInPlace();
    m.nav.home();
    m.handle(.{ .text = 't' });
    try std.testing.expectEqual(.ssh, m.nav.screen);
    var entropy: Entropy = .{};
    var timer: Timer = .{};
    owner.initInPlace(&entropy, &timer);
    owner.poll(m, u, 1);
    owner.poll(m, u, 2);
    try std.testing.expectEqual(.restoring, entropy.state);
    try std.testing.expect(m.private_input == null);
    entropy.allow_restore = true;
    owner.poll(m, u, 3);
    owner.poll(m, u, 4);
    owner.poll(m, u, 5);
    try std.testing.expect(m.private_input != null);
    for ([_][]const u8{ "10.0.2.2", "", "user", "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", "0101010101010101010101010101010101010101010101010101010101010101" }) |value| {
        for (value) |byte| m.feedSerial(byte, 5);
        m.handle(.enter);
    }
    owner.poll(m, u, 6);
    try std.testing.expectEqual(.opening, owner.workspace.controller.state);
    try std.testing.expect(m.private_input == null);
    m.nav.home();
    owner.poll(m, u, 7);
    try std.testing.expect(!owner.active and m.private_input == null);
    try std.testing.expect(std.mem.allEqual(u8, std.mem.asBytes(&owner.visit.visit.visit.journey.profile), 0));
}
