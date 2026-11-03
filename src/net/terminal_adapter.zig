//! Zig wrapper and adapter for the C-ABI terminal & Tailscale interface (`include/nihos/net_terminal.h`).
//! Bridges between low-level C network/SSH primitives and `xy`'s Terminal Buffer.

const std = @import("std");

pub const KeyCode = enum(u16) {
    none = 0,
    enter = 10,
    tab = 9,
    backspace = 127,
    escape = 27,
    arrow_up = 256,
    arrow_down = 257,
    arrow_right = 258,
    arrow_left = 259,
    page_up = 260,
    page_down = 261,
    home = 262,
    end = 263,
};

pub fn encodeKey(key: KeyCode, ch: ?u21, out_buf: []u8) usize {
    if (out_buf.len == 0) return 0;

    switch (key) {
        .none => {
            if (ch) |cp| {
                if (cp < 0x80) {
                    out_buf[0] = @intCast(cp);
                    return 1;
                }
                var tmp: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(cp, &tmp) catch return 0;
                if (len <= out_buf.len) {
                    @memcpy(out_buf[0..len], tmp[0..len]);
                    return len;
                }
            }
            return 0;
        },
        .enter => {
            out_buf[0] = '\r';
            return 1;
        },
        .tab => {
            out_buf[0] = '\t';
            return 1;
        },
        .backspace => {
            out_buf[0] = 0x7F; // DEL
            return 1;
        },
        .escape => {
            out_buf[0] = 0x1B;
            return 1;
        },
        .arrow_up => return copySeq(out_buf, "\x1b[A"),
        .arrow_down => return copySeq(out_buf, "\x1b[B"),
        .arrow_right => return copySeq(out_buf, "\x1b[C"),
        .arrow_left => return copySeq(out_buf, "\x1b[D"),
        .page_up => return copySeq(out_buf, "\x1b[5~"),
        .page_down => return copySeq(out_buf, "\x1b[6~"),
        .home => return copySeq(out_buf, "\x1b[H"),
        .end => return copySeq(out_buf, "\x1b[F"),
    }
}

fn copySeq(dst: []u8, seq: []const u8) usize {
    if (dst.len < seq.len) return 0;
    @memcpy(dst[0..seq.len], seq);
    return seq.len;
}

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
        // SAFETY: nih_ssh_get_view immediately populates all fields of TermView.
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
