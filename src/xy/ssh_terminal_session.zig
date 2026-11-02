//! Bounded bridge from an established SSH session owner to xy's VT100 view.
//! The caller owns the backend, credentials and entropy, and polls the network
//! independently. This module does not open connections or enable a UI screen.
const std = @import("std");
const vt = @import("vt100");
const terminal = @import("terminal_buffer");

/// Exact compile-time dimensions keep TermView's flat row stride correct.
/// The backend implements poll/read/write with the Hosted session signatures.
pub fn Session(comptime Backend: type, comptime cols: u16, comptime rows: u16, comptime history: usize) type {
    if (cols == 0 or rows == 0) @compileError("terminal dimensions must be nonzero");
    return struct {
        const Self = @This();
        pub const State = enum { connecting, ready, closed, failed };
        backend: *Backend,
        screen: vt.Vt100(cols, rows, history),
        buffer: terminal.TerminalBuffer,
        state: State = .connecting,
        input: [128]u8 = @splat(0),
        input_len: usize = 0,

        pub fn init(backend: *Backend, title: []const u8) Self {
            // SAFETY: initInPlace initializes the backend, grid and queue.
            var self: Self = undefined;
            self.initInPlace(backend, title);
            return self;
        }
        /// Initialize the terminal grid in its final caller-owned location.
        pub fn initInPlace(self: *Self, backend: *Backend, title: []const u8) void {
            self.backend = backend;
            self.screen.initInPlace(cols, rows);
            self.buffer = terminal.TerminalBuffer.init(title, cols, rows);
            self.state = .connecting;
            self.input = @splat(0);
            self.input_len = 0;
        }
        /// Enqueue a complete key sequence or reject it without dropping bytes.
        pub fn key(self: *Self, code: terminal.KeyCode, cp: ?u21) error{ NotReady, InputFull, InvalidKey }!void {
            if (self.state != .ready) return error.NotReady;
            var bytes: [4]u8 = undefined;
            const len = terminal.TerminalBuffer.encodeKey(code, cp, &bytes);
            if (len == 0) return error.InvalidKey;
            if (len > self.input.len - self.input_len) return error.InputFull;
            @memcpy(self.input[self.input_len..][0..len], bytes[0..len]);
            self.input_len += len;
        }
        /// Bounded to one backend poll, one 256-byte read and one partial write.
        /// Fresh cryptographic padding is needed on every call.
        pub fn poll(self: *Self, now_us: u64, padding: *const [32]u8, username: []const u8, seed: [32]u8) anyerror!State {
            return self.advance(now_us, padding, username, seed) catch |err| {
                self.state = .failed;
                std.crypto.secureZero(u8, &self.input);
                self.input_len = 0;
                self.backend.abort();
                return err;
            };
        }
        fn advance(self: *Self, now_us: u64, padding: *const [32]u8, username: []const u8, seed: [32]u8) anyerror!State {
            if (self.state == .failed or self.state == .closed) return error.InvalidState;
            const status = try self.backend.poll(now_us, padding, username, seed);
            switch (status) {
                .connecting => {
                    if (self.state != .connecting) return error.InvalidState;
                    return .connecting;
                },
                .closed => {
                    self.state = .closed;
                    std.crypto.secureZero(u8, &self.input);
                    self.input_len = 0;
                    return .closed;
                },
                .ready => self.state = .ready,
            }
            var bytes: [256]u8 = undefined;
            const n = try self.backend.read(now_us, padding, &bytes);
            if (n > bytes.len) return error.InvalidIo;
            self.screen.feed(bytes[0..n]);
            if (self.input_len != 0) {
                const sent = try self.backend.write(now_us, padding, self.input[0..self.input_len]);
                if (sent > self.input_len) return error.InvalidIo;
                std.mem.copyForwards(u8, self.input[0 .. self.input_len - sent], self.input[sent..self.input_len]);
                std.crypto.secureZero(u8, self.input[self.input_len - sent .. self.input_len]);
                self.input_len -= sent;
            }
            return .ready;
        }
        pub fn view(self: *const Self) terminal.TermView {
            return self.screen.getView();
        }
        pub fn cancel(self: *Self) void {
            self.backend.abort();
            std.crypto.secureZero(u8, &self.input);
            self.input_len = 0;
            self.state = .closed;
        }
    };
}

test "terminal bridges fragmented output and preserves partial key writes" {
    const Mock = struct {
        const Status = enum { connecting, ready, closed };
        source: []const u8 = "A\xe3\x81\x82\r\nZ",
        pos: usize = 0,
        sent: [128]u8 = @splat(0),
        used: usize = 0,
        allow_write: bool = false,
        aborted: bool = false,
        fail_read: bool = false,
        fn poll(_: *@This(), _: u64, _: *const [32]u8, _: []const u8, _: [32]u8) !Status {
            return .ready;
        }
        fn read(self: *@This(), _: u64, _: *const [32]u8, out: []u8) !usize {
            if (self.fail_read) return error.Backend;
            if (self.pos == self.source.len) return 0;
            out[0] = self.source[self.pos];
            self.pos += 1;
            return 1;
        }
        fn write(self: *@This(), _: u64, _: *const [32]u8, bytes: []const u8) !usize {
            if (!self.allow_write) return 0;
            const n = @min(1, bytes.len);
            @memcpy(self.sent[self.used..][0..n], bytes[0..n]);
            self.used += n;
            return n;
        }
        fn abort(self: *@This()) void {
            self.aborted = true;
        }
    };
    var backend: Mock = .{};
    var session = Session(Mock, 10, 2, 0).init(&backend, "test");
    const random: [32]u8 = @splat(1);
    try std.testing.expectError(error.NotReady, session.key(.enter, null));
    _ = try session.poll(1, &random, "user", @splat(0));
    try session.key(.arrow_up, null);
    try session.key(.none, 0x3042);
    for (0..5) |i| _ = try session.poll(2 + i, &random, "user", @splat(0));
    try std.testing.expectEqual(@as(usize, 6), session.input_len);
    try std.testing.expectEqual(@as(u32, 'A'), session.view().cells[0].codepoint);
    try std.testing.expectEqual(@as(u32, 0x3042), session.view().cells[1].codepoint);
    backend.allow_write = true;
    for (0..6) |i| _ = try session.poll(10 + i, &random, "user", @splat(0));
    try std.testing.expectEqual(@as(usize, 0), session.input_len);
    try std.testing.expectEqualStrings("\x1b[Aあ", backend.sent[0..backend.used]);
    try std.testing.expectEqual(@as(u32, 'Z'), session.view().cells[10].codepoint);
    for (0..128) |_| try session.key(.none, 'x');
    try std.testing.expectError(error.InputFull, session.key(.arrow_up, null));
    try std.testing.expectEqual(@as(usize, 128), session.input_len);
    backend.fail_read = true;
    try std.testing.expectError(error.Backend, session.poll(30, &random, "user", @splat(0)));
    try std.testing.expect(std.mem.allEqual(u8, &session.input, 0));
    try std.testing.expect(backend.aborted);
    try std.testing.expectError(error.NotReady, session.key(.enter, null));
    var other: Mock = .{};
    var canceled = Session(Mock, 10, 2, 0).init(&other, "cancel");
    _ = try canceled.poll(1, &random, "user", @splat(0));
    try canceled.key(.enter, null);
    canceled.cancel();
    try std.testing.expect(other.aborted and canceled.input_len == 0);
}

test "Hosted session backend matches terminal bridge contract" {
    const Backend = @import("ssh_hosted_session").Owner;
    const Ui = Session(Backend, 80, 24, 8);
    const poll = &Ui.poll;
    const key = &Ui.key;
    const cancel = &Ui.cancel;
    _ = .{ poll, key, cancel };
    try std.testing.expect(@sizeOf(Ui) < 65536);
}
