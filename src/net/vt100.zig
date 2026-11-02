//! Pure-Zig VT100 / ANSI Escape Sequence Terminal Emulator (`src/net/vt100.zig`)
//!
//! Allocation-free, memory-safe, and bounded terminal grid state machine.
//! Parses VT100 control codes, CSI / SGR color sequences, and UTF-8 multi-byte
//! codepoints into a 2D matrix of `nih_term_cell_t` (RGB565) cells with scrollback.

const std = @import("std");
const terminal_adapter = @import("terminal_adapter");

pub const Cell = terminal_adapter.Cell;
pub const TermView = terminal_adapter.TermView;

pub inline fn rgb565(r: u8, g: u8, b: u8) u16 {
    return (@as(u16, r >> 3) << 11) | (@as(u16, g >> 2) << 5) | @as(u16, b >> 3);
}

/// Standard 16-color ANSI palette in RGB565 little-endian.
pub const ansi_palette = [16]u16{
    rgb565(0, 0, 0), // 0: Black
    rgb565(205, 49, 49), // 1: Red
    rgb565(13, 188, 121), // 2: Green
    rgb565(229, 229, 16), // 3: Yellow
    rgb565(36, 114, 200), // 4: Blue
    rgb565(188, 63, 188), // 5: Magenta
    rgb565(17, 168, 205), // 6: Cyan
    rgb565(229, 229, 229), // 7: White / Light Gray
    rgb565(102, 102, 102), // 8: Bright Black (Dark Gray)
    rgb565(241, 76, 76), // 9: Bright Red
    rgb565(35, 209, 139), // 10: Bright Green
    rgb565(245, 245, 67), // 11: Bright Yellow
    rgb565(59, 142, 234), // 12: Bright Blue
    rgb565(214, 112, 214), // 13: Bright Magenta
    rgb565(41, 184, 219), // 14: Bright Cyan
    rgb565(255, 255, 255), // 15: Bright White
};

pub const EscState = enum(u8) {
    normal = 0,
    saw_esc = 1,
    csi = 2,
    osc = 3,
    consume_one = 4,
};

pub fn Vt100(comptime max_cols: u16, comptime max_rows: u16, comptime max_hist: usize) type {
    if (max_cols == 0 or max_rows == 0) @compileError("terminal dimensions must be nonzero");
    return struct {
        const Self = @This();

        cols: u16 = max_cols,
        rows: u16 = max_rows,
        cx: u16 = 0,
        cy: u16 = 0,
        cursor_visible: bool = true,

        // Drawing attributes
        cur_fg: u8 = 7, // Light gray
        cur_bg: u8 = 0, // Black
        bold: bool = false,
        reverse: bool = false,
        underline: bool = false,

        // Parser state
        esc_state: EscState = .normal,
        csi_params: [8]i32 = @splat(0),
        csi_nparams: u8 = 0,
        csi_priv: bool = false,

        // UTF-8 decoder state
        utf8_cp: u32 = 0,
        utf8_rem: u8 = 0,

        // Screen buffer
        screen: [max_rows][max_cols]Cell = @splat(@splat(.{})),
        dirty_rows: [max_rows]bool = @splat(true),

        // Scrollback history ring buffer
        hist: [max_hist][max_cols]Cell = @splat(@splat(.{})),
        hist_head: usize = 0,
        hist_count: usize = 0,

        pub fn init(cols: u16, rows: u16) Self {
            // SAFETY: initInPlace initializes all fields and both grids.
            var term: Self = undefined;
            term.initInPlace(cols, rows);
            return term;
        }

        /// Initialize caller-owned storage without a large temporary grid.
        pub fn initInPlace(self: *Self, cols: u16, rows: u16) void {
            self.cols = std.math.clamp(cols, 1, max_cols);
            self.rows = std.math.clamp(rows, 1, max_rows);
            self.cursor_visible = true;
            self.csi_params = @splat(0);
            self.dirty_rows = @splat(true);
            for (&self.screen) |*row| @memset(row, .{});
            for (&self.hist) |*row| @memset(row, .{});
            self.reset();
        }

        pub fn reset(self: *Self) void {
            self.cx = 0;
            self.cy = 0;
            self.cur_fg = 7;
            self.cur_bg = 0;
            self.bold = false;
            self.reverse = false;
            self.underline = false;
            self.esc_state = .normal;
            self.csi_nparams = 0;
            self.csi_priv = false;
            self.utf8_cp = 0;
            self.utf8_rem = 0;
            self.hist_head = 0;
            self.hist_count = 0;

            for (0..self.rows) |r| {
                self.clearLine(r, 7, 0);
                self.dirty_rows[r] = true;
            }
        }

        fn clearLine(self: *Self, r: usize, fg_idx: u8, bg_idx: u8) void {
            const fg_c = ansi_palette[fg_idx & 15];
            const bg_c = ansi_palette[bg_idx & 15];
            for (0..self.cols) |c| {
                self.screen[r][c] = .{
                    .codepoint = ' ',
                    .fg_rgb565 = fg_c,
                    .bg_rgb565 = bg_c,
                    .flags = 0,
                };
            }
        }

        pub fn scrollUp(self: *Self) void {
            // Push top line to scrollback ring buffer
            if (max_hist > 0) {
                self.hist[self.hist_head] = self.screen[0];
                self.hist_head = (self.hist_head + 1) % max_hist;
                if (self.hist_count < max_hist) {
                    self.hist_count += 1;
                }
            }

            // Shift rows up
            var r: usize = 0;
            while (r + 1 < self.rows) : (r += 1) {
                self.screen[r] = self.screen[r + 1];
                self.dirty_rows[r] = true;
            }

            self.clearLine(self.rows - 1, self.cur_fg, self.cur_bg);
            self.dirty_rows[self.rows - 1] = true;
        }

        pub fn newline(self: *Self) void {
            self.dirty_rows[self.cy] = true;
            if (self.cy + 1 < self.rows) {
                self.cy += 1;
                self.dirty_rows[self.cy] = true;
            } else {
                self.scrollUp();
            }
        }

        pub fn putCodepoint(self: *Self, cp: u32) void {
            if (self.cx >= self.cols) {
                self.cx = 0;
                self.newline();
            }

            var fg_idx = self.cur_fg;
            if (self.bold and fg_idx < 8) fg_idx += 8;
            var bg_idx = self.cur_bg;

            if (self.reverse) {
                const tmp = fg_idx;
                fg_idx = bg_idx;
                bg_idx = tmp;
            }

            var flags: u8 = 0;
            if (self.bold) flags |= 1;
            if (self.underline) flags |= 2;
            if (self.reverse) flags |= 4;

            self.screen[self.cy][self.cx] = .{
                .codepoint = cp,
                .fg_rgb565 = ansi_palette[fg_idx & 15],
                .bg_rgb565 = ansi_palette[bg_idx & 15],
                .flags = flags,
            };
            self.dirty_rows[self.cy] = true;
            self.cx += 1;
        }

        pub fn feed(self: *Self, bytes: []const u8) void {
            for (bytes) |b| {
                self.feedByte(b);
            }
        }

        pub fn feedByte(self: *Self, b: u8) void {
            switch (self.esc_state) {
                .normal => {
                    if (b == 0x1B) {
                        self.utf8_rem = 0;
                        self.esc_state = .saw_esc;
                        return;
                    }
                    if (b >= 0x80) {
                        if ((b & 0xC0) == 0x80) {
                            if (self.utf8_rem > 0) {
                                self.utf8_cp = (self.utf8_cp << 6) | @as(u32, b & 0x3F);
                                self.utf8_rem -= 1;
                                if (self.utf8_rem == 0) {
                                    self.putCodepoint(self.utf8_cp);
                                }
                            }
                        } else if ((b & 0xE0) == 0xC0) {
                            self.utf8_cp = @as(u32, b & 0x1F);
                            self.utf8_rem = 1;
                        } else if ((b & 0xF0) == 0xE0) {
                            self.utf8_cp = @as(u32, b & 0x0F);
                            self.utf8_rem = 2;
                        } else if ((b & 0xF8) == 0xF0) {
                            self.utf8_cp = @as(u32, b & 0x07);
                            self.utf8_rem = 3;
                        } else {
                            self.utf8_rem = 0;
                        }
                        return;
                    }

                    self.utf8_rem = 0;
                    if (b == '\r') {
                        self.cx = 0;
                        self.dirty_rows[self.cy] = true;
                        return;
                    }
                    if (b == '\n') {
                        self.newline();
                        return;
                    }
                    if (b == '\x08' or b == 0x7F) { // Backspace
                        if (self.cx > 0) {
                            self.cx -= 1;
                            self.dirty_rows[self.cy] = true;
                        }
                        return;
                    }
                    if (b == '\t') {
                        const next_tab = (self.cx + 8) & ~@as(u16, 7);
                        self.cx = @min(next_tab, self.cols - 1);
                        self.dirty_rows[self.cy] = true;
                        return;
                    }
                    if (b < 0x20) {
                        return;
                    }
                    self.putCodepoint(b);
                },

                .saw_esc => {
                    if (b == '[') {
                        self.esc_state = .csi;
                        self.csi_nparams = 0;
                        self.csi_priv = false;
                        self.csi_params = @splat(0);
                        return;
                    }
                    if (b == ']') {
                        self.esc_state = .osc;
                        return;
                    }
                    if (b == '(' or b == ')' or b == '*' or b == '+') {
                        self.esc_state = .consume_one;
                        return;
                    }
                    if (b == 'c') {
                        self.reset();
                        return;
                    }
                    if (b == 'D' or b == 'E') {
                        if (b == 'E') self.cx = 0;
                        self.newline();
                        self.esc_state = .normal;
                        return;
                    }
                    if (b == 'M') {
                        if (self.cy > 0) self.cy -= 1;
                        self.dirty_rows[self.cy] = true;
                        self.esc_state = .normal;
                        return;
                    }
                    self.esc_state = .normal;
                },

                .csi => {
                    if (b == '?' or b == '>' or b == '=') {
                        self.csi_priv = true;
                        return;
                    }
                    if (b >= '0' and b <= '9') {
                        if (self.csi_nparams == 0) self.csi_nparams = 1;
                        const idx = self.csi_nparams - 1;
                        if (idx < self.csi_params.len) {
                            // A server controls these bytes. Saturate before conversion
                            // and cursor arithmetic instead of overflowing on long CSI.
                            self.csi_params[idx] = @min(65535, self.csi_params[idx] *| 10 +| @as(i32, b - '0'));
                        }
                        return;
                    }
                    if (b == ';') {
                        if (self.csi_nparams == 0) self.csi_nparams = 1;
                        if (self.csi_nparams < self.csi_params.len) {
                            self.csi_nparams += 1;
                            self.csi_params[self.csi_nparams - 1] = 0;
                        }
                        return;
                    }
                    if (b >= 0x40 and b <= 0x7E) {
                        self.handleCsi(b);
                        self.esc_state = .normal;
                        return;
                    }
                },

                .osc => {
                    if (b == 0x07) {
                        self.esc_state = .normal;
                    } else if (b == 0x1B) {
                        self.esc_state = .consume_one;
                    }
                },

                .consume_one => {
                    self.esc_state = .normal;
                },
            }
        }

        fn handleCsi(self: *Self, final_ch: u8) void {
            const p0: i32 = if (self.csi_nparams >= 1) self.csi_params[0] else 0;
            const p1: i32 = if (self.csi_nparams >= 2) self.csi_params[1] else 0;

            self.dirty_rows[self.cy] = true;

            switch (final_ch) {
                'm' => self.handleSgr(),
                'A' => { // Cursor Up
                    const n: u16 = @intCast(@min(if (p0 > 0) p0 else 1, @as(i32, self.rows)));
                    if (self.cy >= n) {
                        self.cy -= n;
                    } else {
                        self.cy = 0;
                    }
                    self.dirty_rows[self.cy] = true;
                },
                'B' => { // Cursor Down
                    const n: u16 = @intCast(@min(if (p0 > 0) p0 else 1, @as(i32, self.rows)));
                    self.cy = @min(self.cy +| n, self.rows - 1);
                    self.dirty_rows[self.cy] = true;
                },
                'C' => { // Cursor Forward
                    const n: u16 = @intCast(@min(if (p0 > 0) p0 else 1, @as(i32, self.cols)));
                    self.cx = @min(self.cx +| n, self.cols - 1);
                },
                'D' => { // Cursor Back
                    const n: u16 = @intCast(@min(if (p0 > 0) p0 else 1, @as(i32, self.cols)));
                    if (self.cx >= n) {
                        self.cx -= n;
                    } else {
                        self.cx = 0;
                    }
                },
                'G' => { // Cursor Horizontal Absolute
                    const col = if (p0 > 0) p0 - 1 else 0;
                    self.cx = @intCast(std.math.clamp(col, 0, @as(i32, self.cols - 1)));
                },
                'd' => { // Line Position Absolute
                    const row = if (p0 > 0) p0 - 1 else 0;
                    self.cy = @intCast(std.math.clamp(row, 0, @as(i32, self.rows - 1)));
                    self.dirty_rows[self.cy] = true;
                },
                'H', 'f' => { // Cursor Position
                    const row = if (p0 > 0) p0 - 1 else 0;
                    const col = if (p1 > 0) p1 - 1 else 0;
                    self.cy = @intCast(std.math.clamp(row, 0, @as(i32, self.rows - 1)));
                    self.cx = @intCast(std.math.clamp(col, 0, @as(i32, self.cols - 1)));
                    self.dirty_rows[self.cy] = true;
                },
                'J' => { // Erase in Display
                    if (p0 == 2 or p0 == 3) {
                        for (0..self.rows) |r| {
                            self.clearLine(r, self.cur_fg, self.cur_bg);
                            self.dirty_rows[r] = true;
                        }
                        self.cx = 0;
                        self.cy = 0;
                    } else if (p0 == 0) {
                        for (self.cx..self.cols) |c| {
                            self.screen[self.cy][c] = .{ .codepoint = ' ', .fg_rgb565 = ansi_palette[self.cur_fg], .bg_rgb565 = ansi_palette[self.cur_bg] };
                        }
                        self.dirty_rows[self.cy] = true;
                        var r = self.cy + 1;
                        while (r < self.rows) : (r += 1) {
                            self.clearLine(r, self.cur_fg, self.cur_bg);
                            self.dirty_rows[r] = true;
                        }
                    }
                },
                'K' => { // Erase in Line
                    if (p0 == 0) {
                        for (self.cx..self.cols) |c| {
                            self.screen[self.cy][c] = .{ .codepoint = ' ', .fg_rgb565 = ansi_palette[self.cur_fg], .bg_rgb565 = ansi_palette[self.cur_bg] };
                        }
                    } else if (p0 == 1) {
                        for (0..@min(@as(usize, self.cx) + 1, self.cols)) |c| {
                            self.screen[self.cy][c] = .{ .codepoint = ' ', .fg_rgb565 = ansi_palette[self.cur_fg], .bg_rgb565 = ansi_palette[self.cur_bg] };
                        }
                    } else if (p0 == 2) {
                        self.clearLine(self.cy, self.cur_fg, self.cur_bg);
                    }
                    self.dirty_rows[self.cy] = true;
                },
                'h' => {
                    if (self.csi_priv and p0 == 25) {
                        self.cursor_visible = true;
                    }
                },
                'l' => {
                    if (self.csi_priv and p0 == 25) {
                        self.cursor_visible = false;
                    }
                },
                else => {},
            }
        }

        fn handleSgr(self: *Self) void {
            if (self.csi_nparams == 0) {
                self.cur_fg = 7;
                self.cur_bg = 0;
                self.bold = false;
                self.reverse = false;
                self.underline = false;
                return;
            }

            var i: usize = 0;
            while (i < self.csi_nparams) : (i += 1) {
                const p = self.csi_params[i];
                if (p == 0) {
                    self.cur_fg = 7;
                    self.cur_bg = 0;
                    self.bold = false;
                    self.reverse = false;
                    self.underline = false;
                } else if (p == 1) {
                    self.bold = true;
                } else if (p == 4) {
                    self.underline = true;
                } else if (p == 7) {
                    self.reverse = true;
                } else if (p == 22) {
                    self.bold = false;
                } else if (p == 24) {
                    self.underline = false;
                } else if (p == 27) {
                    self.reverse = false;
                } else if (p >= 30 and p <= 37) {
                    self.cur_fg = @intCast(p - 30);
                } else if (p == 39) {
                    self.cur_fg = 7;
                } else if (p >= 40 and p <= 47) {
                    self.cur_bg = @intCast(p - 40);
                } else if (p == 49) {
                    self.cur_bg = 0;
                } else if (p >= 90 and p <= 97) {
                    self.cur_fg = @intCast(p - 90 + 8);
                } else if (p >= 100 and p <= 107) {
                    self.cur_bg = @intCast(p - 100 + 8);
                }
            }
        }

        pub fn getView(self: *const Self) TermView {
            return TermView{
                .cols = self.cols,
                .rows = self.rows,
                .cursor_col = self.cx,
                .cursor_row = self.cy,
                .cursor_visible = self.cursor_visible,
                .cells = @ptrCast(&self.screen[0][0]),
            };
        }
    };
}

// ============================================================================
// Unit Tests
// ============================================================================

test "VT100 plain text and newline / carriage return" {
    var term = Vt100(80, 24, 64).init(80, 24);
    term.feed("Hello\r\nWorld!");

    try std.testing.expectEqual(@as(u16, 6), term.cx);
    try std.testing.expectEqual(@as(u16, 1), term.cy);
    try std.testing.expectEqual('H', term.screen[0][0].codepoint);
    try std.testing.expectEqual('o', term.screen[0][4].codepoint);
    try std.testing.expectEqual('W', term.screen[1][0].codepoint);
    try std.testing.expectEqual('!', term.screen[1][5].codepoint);
}

test "VT100 ANSI CSI cursor movement and line clear" {
    var term = Vt100(80, 24, 64).init(80, 24);
    term.feed("ABCDE\x1b[2D\x1b[K"); // Write ABCDE, move back 2 (at 'D'), clear line to end

    try std.testing.expectEqual(@as(u16, 3), term.cx);
    try std.testing.expectEqual('A', term.screen[0][0].codepoint);
    try std.testing.expectEqual('B', term.screen[0][1].codepoint);
    try std.testing.expectEqual('C', term.screen[0][2].codepoint);
    try std.testing.expectEqual(' ', term.screen[0][3].codepoint); // Cleared
    try std.testing.expectEqual(' ', term.screen[0][4].codepoint); // Cleared
}

test "VT100 ANSI SGR color attributes" {
    var term = Vt100(80, 24, 64).init(80, 24);
    term.feed("\x1b[1;31mRED\x1b[0mNORMAL");

    // "RED" should have bold flag set and red color
    try std.testing.expectEqual('R', term.screen[0][0].codepoint);
    try std.testing.expectEqual(ansi_palette[9], term.screen[0][0].fg_rgb565); // bright red because bold
    try std.testing.expectEqual(@as(u8, 1), term.screen[0][0].flags & 1);

    // "NORMAL" should be default
    try std.testing.expectEqual('N', term.screen[0][3].codepoint);
    try std.testing.expectEqual(ansi_palette[7], term.screen[0][3].fg_rgb565);
    try std.testing.expectEqual(@as(u8, 0), term.screen[0][3].flags & 1);
}

test "VT100 UTF-8 multi-byte decoding" {
    var term = Vt100(80, 24, 64).init(80, 24);
    term.feed("こんにちは");

    try std.testing.expectEqual(@as(u16, 5), term.cx);
    try std.testing.expectEqual(0x3053, term.screen[0][0].codepoint); // 'こ'
    try std.testing.expectEqual(0x3093, term.screen[0][1].codepoint); // 'ん'
    try std.testing.expectEqual(0x306B, term.screen[0][2].codepoint); // 'に'
    try std.testing.expectEqual(0x3061, term.screen[0][3].codepoint); // 'ち'
    try std.testing.expectEqual(0x306F, term.screen[0][4].codepoint); // 'は'
}

test "untrusted long CSI counts stay bounded and parsing recovers" {
    var term = Vt100(10, 2, 0).init(0, 0);
    try std.testing.expectEqual(@as(u16, 1), term.cols);
    try std.testing.expectEqual(@as(u16, 1), term.rows);
    term.feed("\x1b[999999999999999999999999999999999B");
    term.feed("\x1b[999999999999999999999999999999999C");
    term.feed("\x1b[999999999999999999999999999999999A");
    term.feed("\x1b[999999999999999999999999999999999D");
    term.feed("\x1b[999999999999999999999999999999999;999999999999999999999H");
    term.feed("X");
    try std.testing.expectEqual(@as(u16, 0), term.cy);
    try std.testing.expectEqual(@as(u32, 'X'), term.getView().cells[0].codepoint);
    var wide = Vt100(80, 24, 0).init(80, 24);
    wide.feed("\x1b[65535;65535H\x1b[65535B\x1b[65535C!");
    try std.testing.expectEqual(@as(u16, 23), wide.cy);
    try std.testing.expectEqual(@as(u32, '!'), wide.screen[23][79].codepoint);
}
