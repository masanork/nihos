//! One bounded SSH session channel. Authentication and packet transport are
//! owned by the caller; received data is borrowed until the next input packet.
const std = @import("std");
pub const Error = error{ InvalidState, Malformed, WrongChannel, WindowExceeded, BufferTooSmall, RemoteFailure, Unsupported };
const Reader = struct {
    input: []const u8,
    pos: usize = 0,
    fn take(self: *Reader, n: usize) Error![]const u8 {
        if (n > self.input.len - self.pos) return error.Malformed;
        const v = self.input[self.pos..][0..n];
        self.pos += n;
        return v;
    }
    fn int(self: *Reader) Error!u32 {
        return std.mem.readInt(u32, (try self.take(4))[0..4], .big);
    }
    fn string(self: *Reader) Error![]const u8 {
        return self.take(try self.int());
    }
    fn end(self: *Reader) Error!void {
        if (self.pos != self.input.len) return error.Malformed;
    }
};

test "channel enforces transitions, credit and recipient" {
    var c: Channel = .{};
    var out: [256]u8 = undefined;
    try std.testing.expectError(error.InvalidState, c.pty(&out, 80, 24));
    _ = try c.open(&out);
    try std.testing.expectEqual(Event.opened, try c.receive(&.{ 91, 0, 0, 0, 0, 0, 0, 0, 7, 0, 0, 0, 3, 0, 0, 0, 2 }));
    _ = try c.pty(&out, 80, 24);
    try std.testing.expectEqual(Event.pty_ready, try c.receive(&.{ 99, 0, 0, 0, 0 }));
    _ = try c.start(&out, "");
    try std.testing.expectEqual(Event.started, try c.receive(&.{ 99, 0, 0, 0, 0 }));
    try std.testing.expectError(error.WindowExceeded, c.data(&out, "abc"));
    _ = try c.data(&out, "ab");
    try std.testing.expectEqual(@as(u32, 1), c.remote_window);
    const event = try c.receive(&.{ 94, 0, 0, 0, 0, 0, 0, 0, 2, 'o', 'k' });
    try std.testing.expectEqualStrings("ok", event.data);
    try std.testing.expectEqual(@as(u32, 65534), c.local_window);
    _ = try c.grant(&out, 2);
    try std.testing.expectError(error.WrongChannel, c.receive(&.{ 96, 0, 0, 0, 1 }));
    try std.testing.expectError(error.InvalidState, c.receive(&.{ 96, 0, 0, 0, 0 }));
}

test "EOF and close handshake are emitted at most once" {
    var c = Channel{ .state = .running, .remote = 7 };
    var out: [16]u8 = undefined;
    try std.testing.expectEqualSlices(u8, &.{ 96, 0, 0, 0, 7 }, try c.eof(&out));
    try std.testing.expectError(error.InvalidState, c.eof(&out));
    try std.testing.expectEqual(Event.eof, try c.receive(&.{ 96, 0, 0, 0, 0 }));
    try std.testing.expectEqual(Event.closed, try c.receive(&.{ 97, 0, 0, 0, 0 }));
    try std.testing.expectEqualSlices(u8, &.{ 97, 0, 0, 0, 7 }, try c.close(&out));
    try std.testing.expectError(error.InvalidState, c.close(&out));
}
const Writer = struct {
    out: []u8,
    pos: usize = 0,
    fn put(self: *Writer, b: []const u8) Error!void {
        if (b.len > self.out.len - self.pos) return error.BufferTooSmall;
        @memcpy(self.out[self.pos..][0..b.len], b);
        self.pos += b.len;
    }
    fn int(self: *Writer, n: u32) Error!void {
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, n, .big);
        try self.put(&b);
    }
    fn string(self: *Writer, b: []const u8) Error!void {
        if (b.len > std.math.maxInt(u32)) return error.BufferTooSmall;
        try self.int(@intCast(b.len));
        try self.put(b);
    }
};
pub const Event = union(enum) { opened, pty_ready, started, data: []const u8, extended: []const u8, window, eof, closed, exit_status: u32, ignored };
pub const Channel = struct {
    const State = enum { idle, opening, opened, pty_pending, pty_ready, start_pending, running, closing, closed, failed };
    state: State = .idle,
    remote: u32 = 0,
    remote_window: u32 = 0,
    remote_max: u32 = 0,
    local_window: u32 = 65536,
    remote_eof: bool = false,
    local_eof: bool = false,
    close_sent: bool = false,

    pub fn open(self: *Channel, out: []u8) Error![]const u8 {
        if (self.state != .idle) return error.InvalidState;
        var w = Writer{ .out = out };
        try w.put(&.{90});
        try w.string("session");
        try w.int(0);
        try w.int(65536);
        try w.int(32768);
        self.state = .opening;
        return out[0..w.pos];
    }
    pub fn pty(self: *Channel, out: []u8, cols: u32, rows: u32) Error![]const u8 {
        if (self.state != .opened or cols == 0 or rows == 0) return error.InvalidState;
        var w = Writer{ .out = out };
        try w.put(&.{98});
        try w.int(self.remote);
        try w.string("pty-req");
        try w.put(&.{1});
        try w.string("xterm");
        try w.int(cols);
        try w.int(rows);
        try w.int(0);
        try w.int(0);
        try w.string(&.{0});
        self.state = .pty_pending;
        return out[0..w.pos];
    }
    /// Empty command opens an interactive shell; otherwise request exec.
    pub fn start(self: *Channel, out: []u8, command: []const u8) Error![]const u8 {
        if (self.state != .pty_ready) return error.InvalidState;
        var w = Writer{ .out = out };
        try w.put(&.{98});
        try w.int(self.remote);
        try w.string(if (command.len == 0) "shell" else "exec");
        try w.put(&.{1});
        if (command.len != 0) try w.string(command);
        self.state = .start_pending;
        return out[0..w.pos];
    }
    pub fn data(self: *Channel, out: []u8, bytes: []const u8) Error![]const u8 {
        if (self.state != .running or self.local_eof) return error.InvalidState;
        if (bytes.len == 0 or bytes.len > self.remote_window or bytes.len > self.remote_max) return error.WindowExceeded;
        var w = Writer{ .out = out };
        try w.put(&.{94});
        try w.int(self.remote);
        try w.string(bytes);
        self.remote_window -= @intCast(bytes.len);
        return out[0..w.pos];
    }
    /// Grant more receive credit only after the consumer has processed bytes.
    pub fn grant(self: *Channel, out: []u8, count: u32) Error![]const u8 {
        if (self.state != .running or count == 0 or count > 65536 - self.local_window) return error.InvalidState;
        var w = Writer{ .out = out };
        try w.put(&.{93});
        try w.int(self.remote);
        try w.int(count);
        self.local_window += count;
        return out[0..w.pos];
    }
    pub fn eof(self: *Channel, out: []u8) Error![]const u8 {
        if (self.state != .running or self.local_eof) return error.InvalidState;
        var w = Writer{ .out = out };
        try w.put(&.{96});
        try w.int(self.remote);
        self.local_eof = true;
        return out[0..w.pos];
    }
    pub fn close(self: *Channel, out: []u8) Error![]const u8 {
        if ((self.state != .running and self.state != .closed) or self.close_sent) return error.InvalidState;
        var w = Writer{ .out = out };
        try w.put(&.{97});
        try w.int(self.remote);
        self.close_sent = true;
        if (self.state != .closed) self.state = .closing;
        return out[0..w.pos];
    }
    pub fn receive(self: *Channel, input: []const u8) Error!Event {
        return self.read(input) catch |err| {
            self.state = .failed;
            return err;
        };
    }
    fn read(self: *Channel, input: []const u8) Error!Event {
        if (self.state == .idle or self.state == .closed or self.state == .failed) return error.InvalidState;
        var r = Reader{ .input = input };
        const kind = (try r.take(1))[0];
        if (try r.int() != 0) return error.WrongChannel;
        switch (kind) {
            91 => {
                if (self.state != .opening) return error.InvalidState;
                const remote = try r.int();
                const window = try r.int();
                const maximum = try r.int();
                try r.end();
                if (maximum == 0) return error.Malformed;
                self.remote = remote;
                self.remote_window = window;
                self.remote_max = maximum;
                self.state = .opened;
                return .opened;
            },
            92, 100 => return error.RemoteFailure,
            99 => {
                try r.end();
                if (self.state == .pty_pending) {
                    self.state = .pty_ready;
                    return .pty_ready;
                }
                if (self.state == .start_pending) {
                    self.state = .running;
                    return .started;
                }
                return error.InvalidState;
            },
            93 => {
                if (self.state != .opened and self.state != .pty_pending and self.state != .pty_ready and self.state != .start_pending and self.state != .running) return error.InvalidState;
                const count = try r.int();
                try r.end();
                self.remote_window = std.math.add(u32, self.remote_window, count) catch return error.WindowExceeded;
                return .window;
            },
            94, 95 => {
                if (self.state != .running or self.remote_eof) return error.InvalidState;
                if (kind == 95 and try r.int() != 1) return error.Unsupported;
                const bytes = try r.string();
                try r.end();
                if (bytes.len > self.local_window or bytes.len > 32768) return error.WindowExceeded;
                self.local_window -= @intCast(bytes.len);
                return if (kind == 94) .{ .data = bytes } else .{ .extended = bytes };
            },
            96 => {
                try r.end();
                if (self.remote_eof or (self.state != .running and self.state != .closing)) return error.InvalidState;
                self.remote_eof = true;
                return .eof;
            },
            97 => {
                try r.end();
                self.state = .closed;
                return .closed;
            },
            98 => {
                const name = try r.string();
                const reply = (try r.take(1))[0];
                if (reply != 0) return error.Unsupported;
                if (std.mem.eql(u8, name, "exit-status")) {
                    const status = try r.int();
                    try r.end();
                    return .{ .exit_status = status };
                }
                return error.Unsupported;
            },
            else => return error.Unsupported,
        }
    }
};
