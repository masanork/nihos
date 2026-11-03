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
    pub fn open(_: *@This(), _: [4]u8, _: u16, _: u16, _: u32, _: u64) !Handle {
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
    pub fn available(_: *@This()) bool {
        return true;
    }
    pub fn fill(self: *@This(), out: []u8) !void {
        if (!self.fill_fn(out.ptr, out.len)) return error.EntropyUnavailable;
    }
};
const HostJourney = lifecycle.Journey(console.scratch.Model, Controller);
const HostForeground = lifecycle.Foreground(console.scratch.Model, Controller, HostEntropy);
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
export fn probe_lifecycle_begin(poll: Poll, read: Read, write: Write, start: Start, ready: Action, release: Action, cancel: Action, close: Action, complete: Action, fill: Fill, now: u64, user: [*]const u8, user_len: usize, fingerprint: *const [50]u8, seed_hex: *const [64]u8) bool {
    initialized = false;
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
    foreground.initInPlace(&model, &controller, &host_entropy, 20_000_000, 20_000_000) catch return false;
    if ((foreground.poll(true, now) catch return false) != .editing) return false;
    for ([_][]const u8{ "10.0.2.2", "22", user[0..user_len], fingerprint, seed_hex }) |value| {
        for (value) |byte| {
            model.feedSerial(byte, now);
            if (model.status != .none) {
                _ = foreground.stop();
                return false;
            }
        }
        model.handle(.enter);
    }
    if (foreground.journey.setup.status != .ready or model.private_input != null) {
        _ = foreground.stop();
        return false;
    }
    if ((foreground.poll(true, now) catch return false) != .connecting) return false;
    initialized = true;
    return true;
}
export fn probe_lifecycle_poll(now: u64) isize {
    if (!initialized) return -1;
    return switch (foreground.poll(model.nav.screen == .ssh, now) catch |err| {
        return if (err == error.HostKeyMismatch) -2 else if (err == error.EntropyUnavailable) -3 else -1;
    }) {
        .editing, .connecting, .closing => 0,
        .connected => 1,
        .closed => 2,
        .idle, .failed => -1,
    };
}
export fn probe_profile_cleared() bool {
    for (@import("std").mem.asBytes(&foreground.journey.profile)) |byte| if (byte != 0) return false;
    return true;
}
export fn probe_seed_cleared() bool {
    for (foreground.journey.profile.seed) |byte| if (byte != 0) return false;
    return true;
}
export fn probe_lifecycle_leave(now: u64) bool {
    if (!initialized) return false;
    model.nav.home();
    if ((foreground.poll(false, now) catch return false) != .closed) return false;
    return model.terminal == null and model.private_input == null and probe_profile_cleared();
}
