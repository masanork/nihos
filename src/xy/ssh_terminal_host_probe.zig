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
// SAFETY: probe_lifecycle_begin initializes these stable objects before use.
var host_network: HostNetwork = undefined;
// SAFETY: probe_lifecycle_begin initializes this stable object before use.
var controller: Controller = undefined;
export fn probe_lifecycle_begin(poll: Poll, read: Read, write: Write, start: Start, ready: Action, release: Action, cancel: Action, close: Action, complete: Action, now: u64) bool {
    backend = .{ .poll_fn = poll, .read_fn = read, .write_fn = write };
    host_network = .{ .start = start, .ready_fn = ready, .release_fn = release, .cancel_fn = cancel, .close_fn = close, .complete_fn = complete };
    model.initInPlace();
    controller = Controller.init(&host_network, &ui, &model);
    controller.begin(now, now +| 20_000_000, 20_000_000, .{ 10, 0, 2, 2 }, 22, 50001, 123) catch return false;
    initialized = true;
    return true;
}
export fn probe_lifecycle_poll(now: u64, secret: *const [32]u8, pin: *const [32]u8, cookie: *const [16]u8, random: *const [32]u8, user: [*]const u8, len: usize, seed: *const [32]u8) isize {
    if (!initialized) return -1;
    const material = lifecycle.Material{ .secret = secret.*, .pin = pin.*, .cookie = cookie.* };
    return switch (controller.poll(now, &material, random, user[0..len], seed.*) catch return -1) {
        .opening, .need_material, .handshaking, .closing => 0,
        .ready => 1,
        .closed => 2,
        .idle, .failed => -1,
    };
}
