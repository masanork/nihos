//! Bounded read-only diagnostic snapshot. No Document, undo or shell dispatch.
const std = @import("std");
pub const Kind = enum { log, memory, tasks };
pub const Request = enum { none, log, memory, tasks };
pub const Snapshot = struct {
    kind: Kind,
    bytes: [4096]u8,
    length: usize,
    top_row: usize,
    truncated: bool,
    dropped: u64,

    pub fn begin(self: *Snapshot, kind: Kind) void {
        self.kind = kind;
        self.length = 0;
        self.top_row = 0;
        self.truncated = false;
        self.dropped = 0;
    }
    pub fn slice(self: *const Snapshot) []const u8 {
        return self.bytes[0..self.length];
    }
    /// Retain printable diagnostics only; escape/control bytes cannot drive a grid.
    pub inline fn write(self: *Snapshot, text: []const u8) void {
        for (text) |byte| {
            if (byte == '\r') continue;
            if (self.length == self.bytes.len) {
                self.truncated = true;
                continue;
            }
            self.bytes[self.length] = if (byte == '\n' or (byte >= 32 and byte < 127)) byte else if (byte == '\t') ' ' else '?';
            self.length += 1;
        }
    }
    pub fn number(self: *Snapshot, value: u64) void {
        var bytes: [20]u8 = @splat(0);
        var rest = value;
        var start: usize = bytes.len;
        while (true) {
            start -= 1;
            bytes[start] = @as(u8, @intCast(rest % 10)) + '0';
            rest /= 10;
            if (rest == 0) break;
        }
        self.write(bytes[start..]);
    }
    pub fn usage(self: *Snapshot, label: []const u8, value: anytype) void {
        self.write(label);
        if (value) |observed| {
            self.write(" capacity=");
            self.number(observed.capacity);
            self.write(" free=");
            self.number(observed.free);
            self.write(" used=");
            self.number(observed.capacity - observed.free);
            self.write("\n");
        } else self.write(" unavailable\n");
    }
    pub fn counters(self: *Snapshot, hart: u32, value: anytype) void {
        self.write("hart ");
        self.number(hart);
        self.write(" ticks=");
        self.number(value.ticks);
        self.write(" switches=");
        self.number(value.switches);
        self.write(" calls=");
        self.number(value.calls);
        self.write("\n");
    }
    inline fn rows(self: *const Snapshot, columns: usize) usize {
        var count: usize = 1;
        var col: usize = 0;
        for (self.slice()) |byte| {
            if (byte == '\n') {
                count += 1;
                col = 0;
            } else {
                col += 1;
                if (col == columns) {
                    count += 1;
                    col = 0;
                }
            }
        }
        return count;
    }
    pub fn scroll(self: *Snapshot, down: bool) void {
        if (down) self.top_row +|= 1 else self.top_row -|= 1;
    }
    pub inline fn render(self: *Snapshot, grid: anytype) void {
        const Grid = @TypeOf(grid.*);
        const body_rows = Grid.height - 2;
        @memset(&grid.cells, ' ');
        grid.x = 0;
        grid.y = 0;
        grid.wrap_pending = false;
        grid.scrolls = 0;
        _ = grid.setScrollTop(1);
        grid.write(switch (self.kind) {
            .log => "xy / *log* [read only]\n",
            .memory => "xy / *memory* [read only]\n",
            .tasks => "xy / *tasks* [read only]\n",
        });
        self.top_row = @min(self.top_row, self.rows(Grid.width) -| body_rows);
        var row: usize = 0;
        var col: usize = 0;
        for (self.slice()) |byte| {
            if (row >= self.top_row + body_rows) break;
            if (byte == '\n') {
                row += 1;
                col = 0;
            } else {
                if (row >= self.top_row) grid.cells[(row - self.top_row + 1) * Grid.width + col] = byte;
                col += 1;
                if (col == Grid.width) {
                    row += 1;
                    col = 0;
                }
            }
        }
        grid.x = 0;
        grid.y = Grid.height - 1;
        grid.wrap_pending = false;
        grid.write(if (self.truncated) "[snapshot truncated] " else if (self.dropped != 0) "[older log bytes dropped] " else "Snapshot | ");
        grid.write("Up/Down: scroll | Ctrl-L: refresh | Esc: scratch");
    }
};

test "bounded snapshot normalizes control bytes and signals lost data" {
    // SAFETY: begin initializes every field read before the byte storage is filled.
    var snapshot: Snapshot = undefined;
    snapshot.begin(.log);
    snapshot.write("one\r\ntwo\x1b\t");
    try std.testing.expectEqualStrings("one\ntwo? ", snapshot.slice());
    for (0..5000) |_| snapshot.write("x");
    try std.testing.expect(snapshot.truncated);
    try std.testing.expectEqual(snapshot.bytes.len, snapshot.length);
}

test "snapshot wraps and clamps scrolling while keeping header and footer" {
    // SAFETY: begin initializes all metadata; write initializes active bytes.
    var snapshot: Snapshot = undefined;
    snapshot.begin(.tasks);
    for (0..20) |_| snapshot.write("line\n");
    snapshot.write("TAIL");
    for (0..100) |_| snapshot.scroll(true);
    var grid = @import("../console/ascii.zig").Grid(80, 8){};
    snapshot.render(&grid);
    try std.testing.expect(std.mem.startsWith(u8, &grid.cells, "xy / *tasks* [read only]"));
    try std.testing.expect(std.mem.indexOf(u8, &grid.cells, "TAIL") != null);
    try std.testing.expect(std.mem.indexOf(u8, &grid.cells, "Ctrl-L: refresh") != null);
    try std.testing.expect(snapshot.top_row < 100);
    snapshot.begin(.memory);
    try std.testing.expectEqual(@as(usize, 0), snapshot.top_row);
}
