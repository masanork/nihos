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
