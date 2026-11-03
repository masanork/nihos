//! Terminal Buffer Mode for `xy` (`src/xy/terminal_buffer.zig`)
//!
//! Integrates SSH / Virtual Terminal grid output into `xy`'s Display List pipeline.
//! Translates terminal cell matrices (`nih_term_view_t`) into `PlacedGlyph` slices
//! and cursor rectangles, and encodes user keystrokes into ANSI escape sequences.

const std = @import("std");
pub const viewport_layout = @import("viewport_layout");
pub const terminal_adapter = @import("terminal_adapter");

pub const PlacedGlyph = viewport_layout.PlacedGlyph;
pub const Cell = terminal_adapter.Cell;
pub const TermView = terminal_adapter.TermView;

pub const KeyCode = terminal_adapter.KeyCode;

pub const TerminalBuffer = struct {
    title: [48]u8 = @splat(0),
    title_len: u8 = 0,
    cols: u16 = 80,
    rows: u16 = 24,
    cell_w_px: u16 = 8,
    cell_h_px: u16 = 16,
    origin_x_px: i32 = 0,
    origin_y_px: i32 = 0,
    font_size_px: u8 = 16,
    style_id: u8 = 1, // Gothic monospace font

    pub fn init(title_str: []const u8, cols: u16, rows: u16) TerminalBuffer {
        var buf = TerminalBuffer{
            .cols = cols,
            .rows = rows,
        };
        buf.setTitle(title_str);
        return buf;
    }

    pub fn setTitle(self: *TerminalBuffer, title_str: []const u8) void {
        const len = @min(title_str.len, self.title.len);
        @memcpy(self.title[0..len], title_str[0..len]);
        self.title_len = @intCast(len);
    }

    pub fn getTitle(self: *const TerminalBuffer) []const u8 {
        return self.title[0..self.title_len];
    }

    /// Translates terminal cells into xy's PlacedGlyph Display List.
    /// Returns the number of placed glyphs written into `out_glyphs`.
    pub fn populateDisplayList(
        self: *const TerminalBuffer,
        view: *const TermView,
        out_glyphs: []PlacedGlyph,
    ) usize {
        var count: usize = 0;
        const total_cells = @as(usize, view.cols) * @as(usize, view.rows);

        var r: u16 = 0;
        while (r < view.rows) : (r += 1) {
            var c: u16 = 0;
            while (c < view.cols) : (c += 1) {
                const idx = @as(usize, r) * @as(usize, view.cols) + c;
                if (idx >= total_cells) break;

                const cell = view.cells[idx];
                // Skip plain empty spaces without formatting
                if (cell.codepoint == 0 or cell.codepoint == 0x20) {
                    continue;
                }

                if (count >= out_glyphs.len) return count;

                const px = self.origin_x_px + @as(i32, c) * @as(i32, self.cell_w_px);
                const py = self.origin_y_px + @as(i32, r) * @as(i32, self.cell_h_px);

                out_glyphs[count] = .{
                    .base_cp = cell.codepoint,
                    .ivs_cp = 0,
                    .cluster_byte_offset = 0,
                    .run = 0,
                    .style_id = self.style_id,
                    .px_size = self.font_size_px,
                    .vertical = 0,
                    .cell_x_px = px,
                    .cell_y_px = py,
                    .bitmap_x_px = px,
                    .bitmap_y_px = py,
                    .bitmap_width = self.cell_w_px,
                    .bitmap_height = self.cell_h_px,
                };
                count += 1;
            }
        }
        return count;
    }

    /// Encodes a keyboard action (character, control key, or cursor sequence)
    /// into ANSI/VT100 bytes suitable for sending to the SSH PTY.
    pub fn encodeKey(key: KeyCode, ch: ?u21, out_buf: []u8) usize {
        return terminal_adapter.encodeKey(key, ch, out_buf);
    }
};

// ============================================================================
// Unit Tests
// ============================================================================

test "TerminalBuffer title and display list generation" {
    var tb = TerminalBuffer.init("*ssh: dev-box*", 80, 24);
    try std.testing.expectEqualStrings("*ssh: dev-box*", tb.getTitle());

    var mock_cells: [80 * 24]Cell = @splat(.{});
    // Write "OK" at (c=0, r=0)
    mock_cells[0] = .{ .codepoint = 'O', .fg_rgb565 = 0xFFFF, .bg_rgb565 = 0 };
    mock_cells[1] = .{ .codepoint = 'K', .fg_rgb565 = 0xFFFF, .bg_rgb565 = 0 };

    const view = TermView{
        .cols = 80,
        .rows = 24,
        .cursor_col = 2,
        .cursor_row = 0,
        .cursor_visible = true,
        .cells = &mock_cells,
    };

    var glyphs: [16]PlacedGlyph = undefined;
    const placed_count = tb.populateDisplayList(&view, &glyphs);

    try std.testing.expectEqual(2, placed_count);
    try std.testing.expectEqual('O', glyphs[0].base_cp);
    try std.testing.expectEqual('K', glyphs[1].base_cp);
    try std.testing.expectEqual(0, glyphs[0].cell_x_px);
    try std.testing.expectEqual(8, glyphs[1].cell_x_px);
}

test "TerminalBuffer key encoding for ANSI VT100 sequences" {
    var buf: [16]u8 = undefined;

    // Arrow keys
    try std.testing.expectEqualStrings("\x1b[A", buf[0..TerminalBuffer.encodeKey(.arrow_up, null, &buf)]);
    try std.testing.expectEqualStrings("\x1b[B", buf[0..TerminalBuffer.encodeKey(.arrow_down, null, &buf)]);
    try std.testing.expectEqualStrings("\x1b[C", buf[0..TerminalBuffer.encodeKey(.arrow_right, null, &buf)]);
    try std.testing.expectEqualStrings("\x1b[D", buf[0..TerminalBuffer.encodeKey(.arrow_left, null, &buf)]);

    // Special keys
    try std.testing.expectEqualStrings("\r", buf[0..TerminalBuffer.encodeKey(.enter, null, &buf)]);
    try std.testing.expectEqualStrings("\x7F", buf[0..TerminalBuffer.encodeKey(.backspace, null, &buf)]);

    // Unicode character
    try std.testing.expectEqualStrings("a", buf[0..TerminalBuffer.encodeKey(.none, 'a', &buf)]);
    try std.testing.expectEqualStrings("あ", buf[0..TerminalBuffer.encodeKey(.none, 0x3042, &buf)]);
}

test "End-to-End VT100 parser fed into TerminalBuffer and populated to PlacedGlyphs" {
    const vt100 = @import("vt100");
    var term = vt100.Vt100(80, 24, 64).init(80, 24);

    // Feed green bold "nihos" followed by space and "2026"
    term.feed("\x1b[1;32mnihos\x1b[0m 2026");

    var tb = TerminalBuffer.init("*ssh: tab5*", 80, 24);
    const view = term.getView();

    var glyphs: [32]PlacedGlyph = undefined;
    const count = tb.populateDisplayList(&view, &glyphs);

    // "nihos" (5) + "2026" (4) = 9 glyphs (space is skipped in sparse display list)
    try std.testing.expectEqual(9, count);
    try std.testing.expectEqual('n', glyphs[0].base_cp);
    try std.testing.expectEqual('i', glyphs[1].base_cp);
    try std.testing.expectEqual('h', glyphs[2].base_cp);
    try std.testing.expectEqual('o', glyphs[3].base_cp);
    try std.testing.expectEqual('s', glyphs[4].base_cp);
    try std.testing.expectEqual('2', glyphs[5].base_cp);
    try std.testing.expectEqual('0', glyphs[6].base_cp);
    try std.testing.expectEqual('2', glyphs[7].base_cp);
    try std.testing.expectEqual('6', glyphs[8].base_cp);
}
