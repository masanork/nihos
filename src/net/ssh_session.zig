//! Post-NEWKEYS SSH session. Packet framing, host-key validation, transport,
//! credentials and lifetime remain the caller's responsibility.
const std = @import("std");
const auth = @import("ssh_auth.zig");
const channel = @import("ssh_channel.zig");
pub const Error = auth.Error || channel.Error || error{AuthenticationFailed};
pub const Event = union(enum) { service_ready, authenticated, banner, channel: channel.Event };
pub const Session = struct {
    const State = enum { initial, service_pending, service_ready, auth_pending, authenticated, failed };
    state: State = .initial,
    session_id: [32]u8,
    terminal: channel.Channel = .{},

    pub fn service(self: *Session, out: []u8) Error![]const u8 {
        if (self.state != .initial) return error.InvalidState;
        const request = "\x05\x00\x00\x00\x0cssh-userauth";
        if (out.len < request.len) return error.BufferTooSmall;
        @memcpy(out[0..request.len], request);
        self.state = .service_pending;
        return out[0..request.len];
    }
    pub fn authenticate(self: *Session, out: []u8, user: []const u8, seed: [32]u8) Error![]const u8 {
        if (self.state != .service_ready) return error.InvalidState;
        const payload = try auth.request(out, user, self.session_id, seed);
        self.state = .auth_pending;
        return payload;
    }
    pub fn open(self: *Session, out: []u8) Error![]const u8 {
        if (self.state != .authenticated) return error.InvalidState;
        return self.terminal.open(out);
    }
    pub fn pty(self: *Session, out: []u8, cols: u32, rows: u32) Error![]const u8 {
        if (self.state != .authenticated) return error.InvalidState;
        return self.terminal.pty(out, cols, rows);
    }
    pub fn start(self: *Session, out: []u8, command: []const u8) Error![]const u8 {
        if (self.state != .authenticated) return error.InvalidState;
        return self.terminal.start(out, command);
    }
    pub fn data(self: *Session, out: []u8, bytes: []const u8) Error![]const u8 {
        if (self.state != .authenticated) return error.InvalidState;
        return self.terminal.data(out, bytes);
    }
    pub fn grant(self: *Session, out: []u8, count: u32) Error![]const u8 {
        if (self.state != .authenticated) return error.InvalidState;
        return self.terminal.grant(out, count);
    }
    pub fn eof(self: *Session, out: []u8) Error![]const u8 {
        if (self.state != .authenticated) return error.InvalidState;
        return self.terminal.eof(out);
    }
    pub fn close(self: *Session, out: []u8) Error![]const u8 {
        if (self.state != .authenticated) return error.InvalidState;
        return self.terminal.close(out);
    }
    pub fn receive(self: *Session, payload: []const u8) Error!Event {
        return self.read(payload) catch |err| {
            self.state = .failed;
            return err;
        };
    }
    fn read(self: *Session, payload: []const u8) Error!Event {
        switch (self.state) {
            .service_pending => {
                if (!std.mem.eql(u8, payload, "\x06\x00\x00\x00\x0cssh-userauth")) return error.Malformed;
                self.state = .service_ready;
                return .service_ready;
            },
            .auth_pending => {
                if (payload.len == 0) return error.Malformed;
                if (payload[0] == 51) return error.AuthenticationFailed;
                if (payload[0] == 53) {
                    // Banner has exactly two bounded SSH strings.
                    var pos: usize = 1;
                    for (0..2) |_| {
                        if (payload.len - pos < 4) return error.Malformed;
                        const len = std.mem.readInt(u32, payload[pos..][0..4], .big);
                        pos += 4;
                        if (len > payload.len - pos) return error.Malformed;
                        pos += len;
                    }
                    if (pos != payload.len) return error.Malformed;
                    return .banner;
                }
                if (!std.mem.eql(u8, payload, &.{52})) return error.Malformed;
                self.state = .authenticated;
                return .authenticated;
            },
            .authenticated => return .{ .channel = try self.terminal.receive(payload) },
            else => return error.InvalidState,
        }
    }
};

test "authentication gates channel and rejects reordered responses" {
    var s = Session{ .session_id = @splat(1) };
    var out: [512]u8 = undefined;
    try std.testing.expectError(error.InvalidState, s.open(&out));
    _ = try s.service(&out);
    try std.testing.expectEqual(Event.service_ready, try s.receive("\x06\x00\x00\x00\x0cssh-userauth"));
    _ = try s.authenticate(&out, "user", @splat(2));
    try std.testing.expectError(error.Malformed, s.receive(&.{91}));
    try std.testing.expectError(error.InvalidState, s.open(&out));
    var failed = Session{ .session_id = @splat(1) };
    _ = try failed.service(&out);
    _ = try failed.receive("\x06\x00\x00\x00\x0cssh-userauth");
    _ = try failed.authenticate(&out, "user", @splat(2));
    try std.testing.expectError(error.AuthenticationFailed, failed.receive(&.{51}));
    try std.testing.expectError(error.InvalidState, failed.open(&out));
}
