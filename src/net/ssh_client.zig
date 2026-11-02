//! Bounded SSH connection through authenticated interactive shell startup.
//! A caller retains socket, transport and pump ownership, supplies fresh packet
//! padding and an Ed25519 seed on each poll, and owns credential storage.
const std = @import("std");
const connection = @import("ssh_connection.zig");
const session = @import("ssh_session.zig");
const socket = @import("ssh_socket_pump.zig");
const transport = @import("ssh_transport.zig");

pub const Error = connection.Error || session.Error || error{InvalidMessage};
pub const Client = struct {
    const Phase = enum { connecting, service, service_reply, auth, auth_reply, open, open_reply, pty, pty_reply, shell, shell_reply, ready, failed };
    conn: connection.Connection,
    session: ?session.Session = null,
    phase: Phase = .connecting,
    cols: u32,
    rows: u32,

    pub fn init(epoch: u64, now_us: u64, deadline_us: u64, secret: [32]u8, pin: [32]u8, cookie: [16]u8, cols: u32, rows: u32) Client {
        return .{ .conn = connection.Connection.init(epoch, now_us, deadline_us, secret, pin, cookie), .cols = cols, .rows = rows };
    }
    /// One bounded I/O and state transition per call. Seed and user must stay
    /// consistent through startup; they are not retained by this object.
    pub fn poll(self: *Client, wire: *transport.Transport, pump: *socket.Pump, io: socket.Io, epoch: u64, now_us: u64, padding: *const [32]u8, user: []const u8, seed: [32]u8) Error!bool {
        return self.advance(wire, pump, io, epoch, now_us, padding, user, seed) catch |err| {
            self.deinit(wire, pump);
            return err;
        };
    }
    fn advance(self: *Client, wire: *transport.Transport, pump: *socket.Pump, io: socket.Io, epoch: u64, now_us: u64, padding: *const [32]u8, user: []const u8, seed: [32]u8) Error!bool {
        if (self.phase == .failed) return error.Failed;
        if (self.phase != .ready and now_us >= self.conn.deadline_us) return error.Timeout;
        if (!(try self.conn.poll(wire, pump, io, epoch, now_us, padding))) return false;
        if (self.phase == .connecting) {
            self.session = .{ .session_id = self.conn.driver.session_id orelse return error.InvalidState };
            self.phase = .service;
            return false;
        }
        if (self.phase == .ready) return true;
        try pump.poll(io, epoch);
        if (wire.pending().len != 0) return false;
        const s = if (self.session) |*v| v else return error.InvalidState;
        var out: [512]u8 = undefined;
        const payload: ?[]const u8 = switch (self.phase) {
            .service => blk: {
                self.phase = .service_reply;
                break :blk try s.service(&out);
            },
            .auth => blk: {
                self.phase = .auth_reply;
                break :blk try s.authenticate(&out, user, seed);
            },
            .open => blk: {
                self.phase = .open_reply;
                break :blk try s.open(&out);
            },
            .pty => blk: {
                self.phase = .pty_reply;
                break :blk try s.pty(&out, self.cols, self.rows);
            },
            .shell => blk: {
                self.phase = .shell_reply;
                break :blk try s.start(&out, "");
            },
            .service_reply, .auth_reply, .open_reply, .pty_reply, .shell_reply => blk: {
                const packet = wire.rx.payload() orelse return false;
                // SSH_MSG_IGNORE and SSH_MSG_DEBUG carry no session state.
                if (packet.len > 0 and (packet[0] == 2 or packet[0] == 4)) {
                    wire.rx.release();
                    return false;
                }
                // Reject unsolicited global requests when the peer asks for a reply.
                if (packet.len > 0 and packet[0] == 80) {
                    if (packet.len < 6) return error.InvalidMessage;
                    const name_len = std.mem.readInt(u32, packet[1..5], .big);
                    if (name_len > packet.len - 6) return error.InvalidMessage;
                    const want_reply = packet[5 + name_len];
                    if (want_reply > 1) return error.InvalidMessage;
                    wire.rx.release();
                    if (want_reply == 1) {
                        out[0] = 82;
                        break :blk out[0..1];
                    }
                    return false;
                }
                const event = try s.receive(packet);
                switch (self.phase) {
                    .service_reply => if (event == .service_ready) {
                        self.phase = .auth;
                    } else return error.InvalidMessage,
                    .auth_reply => switch (event) {
                        .banner => {},
                        .authenticated => self.phase = .open,
                        else => return error.InvalidMessage,
                    },
                    .open_reply, .pty_reply, .shell_reply => switch (event) {
                        .channel => |ev| switch (ev) {
                            .window, .ignored => {},
                            .opened => if (self.phase == .open_reply) {
                                self.phase = .pty;
                            } else return error.InvalidMessage,
                            .pty_ready => if (self.phase == .pty_reply) {
                                self.phase = .shell;
                            } else return error.InvalidMessage,
                            .started => if (self.phase == .shell_reply) {
                                self.phase = .ready;
                            } else return error.InvalidMessage,
                            else => return error.InvalidMessage,
                        },
                        else => return error.InvalidMessage,
                    },
                    else => unreachable,
                }
                wire.rx.release();
                return self.phase == .ready;
            },
            else => return error.InvalidState,
        };
        if (payload) |bytes| try wire.prepare(bytes, padding);
        return false;
    }
    pub fn deinit(self: *Client, wire: *transport.Transport, pump: *socket.Pump) void {
        self.conn.deinit(wire, pump);
        if (self.session) |*s| std.crypto.secureZero(u8, std.mem.asBytes(s));
        self.session = null;
        self.phase = .failed;
    }
};

test "authentication rejection aborts startup and clears session" {
    const Mock = struct {
        fn read(_: ?*anyopaque, _: []u8) socket.SocketError!socket.Result {
            return .would_block;
        }
        fn write(_: ?*anyopaque, _: []const u8) socket.SocketError!socket.Result {
            return .would_block;
        }
    };
    const io = socket.Io{ .context = null, .read = Mock.read, .write = Mock.write };
    const random: [32]u8 = @splat(4);
    var wire: transport.Transport = .{};
    var pump = socket.Pump{ .wire = &wire, .epoch = 1 };
    var c = Client.init(1, 0, 100, @splat(1), @splat(2), @splat(3), 80, 24);
    c.conn.phase = .ready;
    c.phase = .auth_reply;
    c.session = .{ .session_id = @splat(5) };
    var out: [512]u8 = undefined;
    const s = if (c.session) |*value| value else unreachable;
    _ = try s.service(&out);
    _ = try s.receive("\x06\x00\x00\x00\x0cssh-userauth");
    _ = try s.authenticate(&out, "user", @splat(6));
    var peer: transport.Transport = .{};
    try peer.prepare(&.{51}, &random);
    _ = try wire.feed(peer.pending());
    try std.testing.expectError(error.AuthenticationFailed, c.poll(&wire, &pump, io, 1, 1, &random, "user", @splat(6)));
    try std.testing.expect(wire.failed and pump.dead and c.session == null);
    try std.testing.expectError(error.Failed, c.poll(&wire, &pump, io, 1, 2, &random, "user", @splat(6)));
}
