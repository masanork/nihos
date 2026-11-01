//! Zig wrapper and adapter for the C-ABI terminal & Tailscale interface (`include/nihos/net_terminal.h`).
//! Bridges between low-level C network/SSH primitives and `xy`'s Terminal Buffer.

const std = @import("std");

pub const Cell = extern struct {
    codepoint: u32 = 0x20, // ' '
    fg_rgb565: u16 = 0xFFFF, // White
    bg_rgb565: u16 = 0x0000, // Black
    flags: u8 = 0, // bit0: bold, bit1: underline, bit2: reverse
};

pub const TermView = extern struct {
    cols: u16 = 80,
    rows: u16 = 24,
    cursor_col: u16 = 0,
    cursor_row: u16 = 0,
    cursor_visible: bool = true,
    cells: [*]const Cell,
};

pub const TsState = enum(u32) {
    stopped = 0,
    connecting = 1,
    needs_login = 2,
    running = 3,
    error_state = 4,
};

pub const TsPeer = extern struct {
    hostname: [48]u8 = @splat(0),
    ip: [4]u8 = @splat(0),
    online: bool = false,

    pub fn getHostname(self: *const TsPeer) []const u8 {
        const len = std.mem.indexOfScalar(u8, &self.hostname, 0) orelse self.hostname.len;
        return self.hostname[0..len];
    }
};

pub const TsStatus = extern struct {
    state: TsState = .stopped,
    my_ip: [4]u8 = @splat(0),
    hostname: [32]u8 = @splat(0),
    auth_url: [160]u8 = @splat(0),
    peer_count: i32 = 0,
    peers: [64]TsPeer = @splat(.{}),

    pub fn getHostname(self: *const TsStatus) []const u8 {
        const len = std.mem.indexOfScalar(u8, &self.hostname, 0) orelse self.hostname.len;
        return self.hostname[0..len];
    }

    pub fn getAuthUrl(self: *const TsStatus) []const u8 {
        const len = std.mem.indexOfScalar(u8, &self.auth_url, 0) orelse self.auth_url.len;
        return self.auth_url[0..len];
    }
};

pub const OpaqueSshSession = opaque {};

pub const DirtyCallback = *const fn (user_ctx: ?*anyopaque) callconv(.c) void;

// Declarations matching `include/nihos/net_terminal.h`
pub extern fn nih_tailscale_init() callconv(.c) bool;
pub extern fn nih_tailscale_up(auth_key: ?[*:0]const u8) callconv(.c) bool;
pub extern fn nih_tailscale_down() callconv(.c) void;
pub extern fn nih_tailscale_get_status(out: *TsStatus) callconv(.c) void;
pub extern fn nih_tailscale_resolve(hostname: [*:0]const u8, out_ip: *[4]u8) callconv(.c) bool;

pub extern fn nih_ssh_create(cols: u16, rows: u16, cb: ?DirtyCallback, user_ctx: ?*anyopaque) callconv(.c) ?*OpaqueSshSession;
pub extern fn nih_ssh_connect(s: *OpaqueSshSession, host: [*:0]const u8, port: u16, user: [*:0]const u8, pass: [*:0]const u8) callconv(.c) bool;
pub extern fn nih_ssh_disconnect(s: *OpaqueSshSession) callconv(.c) void;
pub extern fn nih_ssh_destroy(s: *OpaqueSshSession) callconv(.c) void;

pub extern fn nih_ssh_send_input(s: *OpaqueSshSession, bytes: [*]const u8, len: usize) callconv(.c) void;
pub extern fn nih_ssh_resize(s: *OpaqueSshSession, cols: u16, rows: u16) callconv(.c) void;
pub extern fn nih_ssh_poll(s: *OpaqueSshSession) callconv(.c) void;
pub extern fn nih_ssh_get_view(s: *OpaqueSshSession, out_view: *TermView) callconv(.c) void;

// ============================================================================
// Safe Idiomatic Zig Session Wrapper
// ============================================================================

pub const SshTerminal = struct {
    raw: *OpaqueSshSession,
    cols: u16,
    rows: u16,

    pub fn init(cols: u16, rows: u16, cb: ?DirtyCallback, user_ctx: ?*anyopaque) ?SshTerminal {
        const raw = nih_ssh_create(cols, rows, cb, user_ctx) orelse return null;
        return .{
            .raw = raw,
            .cols = cols,
            .rows = rows,
        };
    }

    pub fn deinit(self: *SshTerminal) void {
        nih_ssh_destroy(self.raw);
    }

    pub fn connect(self: *SshTerminal, host: [:0]const u8, port: u16, user: [:0]const u8, pass: [:0]const u8) bool {
        return nih_ssh_connect(self.raw, host.ptr, port, user.ptr, pass.ptr);
    }

    pub fn disconnect(self: *SshTerminal) void {
        nih_ssh_disconnect(self.raw);
    }

    pub fn sendInput(self: *SshTerminal, bytes: []const u8) void {
        nih_ssh_send_input(self.raw, bytes.ptr, bytes.len);
    }

    pub fn resize(self: *SshTerminal, cols: u16, rows: u16) void {
        self.cols = cols;
        self.rows = rows;
        nih_ssh_resize(self.raw, cols, rows);
    }

    pub fn poll(self: *SshTerminal) void {
        nih_ssh_poll(self.raw);
    }

    pub fn getView(self: *SshTerminal) TermView {
        var view: TermView = undefined;
        nih_ssh_get_view(self.raw, &view);
        return view;
    }
};

// ============================================================================
// In-Memory Host Mock for Unit Testing
// ============================================================================

pub const MockBackend = struct {
    var mock_status: TsStatus = .{};
    var mock_cells: [80 * 25]Cell = @splat(.{});
    var mock_view: TermView = .{
        .cols = 80,
        .rows = 25,
        .cursor_col = 0,
        .cursor_row = 0,
        .cursor_visible = true,
        .cells = &mock_cells,
    };
    var last_input: [256]u8 = @splat(0);
    var last_input_len: usize = 0;
    var connected: bool = false;

    pub fn reset() void {
        mock_status = .{};
        for (&mock_cells) |*c| {
            c.* = .{};
        }
        mock_view.cols = 80;
        mock_view.rows = 25;
        mock_view.cursor_col = 0;
        mock_view.cursor_row = 0;
        last_input_len = 0;
        connected = false;
    }
};

test "Mock terminal types alignment and size contracts" {
    try std.testing.expectEqual(12, @sizeOf(Cell));
    try std.testing.expect(@sizeOf(TsStatus) > 0);
}
