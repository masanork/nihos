//! One writer and one reader, serialized by a task/event transport.
//! Views are borrowed until retire; callers must discard them before sending
//! release. Tokens prevent reacquiring a stale view, not arbitrary raw-pointer use.
pub const Lease = extern struct { token: u32 = 0, bytes: u32 = 0 };
pub const State = struct {
    pub const Phase = enum { vacant, writing, published, retiring };
    pub const Error = error{ Owner, Busy, Stale, Size, Exhausted };
    producer: u32,
    consumer: u32,
    token: u32 = 0,
    bytes: u32 = 0,
    phase: Phase = .vacant,

    pub fn begin(self: *State, caller: u32) Error!u32 {
        if (caller != self.producer) return error.Owner;
        if (self.phase != .vacant) return error.Busy;
        if (self.token == 0xffff_ffff) return error.Exhausted;
        self.token += 1;
        self.phase = .writing;
        return self.token;
    }
    pub fn publish(self: *State, caller: u32, bytes: u32) Error!Lease {
        if (caller != self.producer) return error.Owner;
        if (self.phase != .writing) return error.Stale;
        if (bytes == 0 or bytes > 16384) return error.Size;
        self.bytes = bytes;
        self.phase = .published;
        return .{ .token = self.token, .bytes = bytes };
    }
    pub fn read(self: *const State, caller: u32, lease: Lease) Error!u32 {
        if (caller != self.consumer) return error.Owner;
        if (self.phase != .published or lease.token != self.token or lease.bytes != self.bytes) return error.Stale;
        return self.bytes;
    }
    pub fn retire(self: *State, caller: u32, lease: Lease) Error!void {
        _ = try self.read(caller, lease);
        self.phase = .retiring;
    }
    pub fn reclaim(self: *State, caller: u32, token: u32) Error!void {
        if (caller != self.producer) return error.Owner;
        if (token != self.token or (self.phase != .retiring and self.phase != .writing)) return error.Stale;
        self.phase = .vacant;
        self.bytes = 0;
    }
};

test "raster lease blocks reuse, foreign release, stale reads and duplicate release" {
    const std = @import("std");
    var state: State = .{ .producer = 7, .consumer = 9 };
    const token = try state.begin(7);
    const lease = try state.publish(7, 123);
    try std.testing.expectEqual(@as(u32, 123), try state.read(9, lease));
    try std.testing.expectError(error.Busy, state.begin(7));
    try std.testing.expectError(error.Owner, state.reclaim(9, token));
    try std.testing.expectError(error.Stale, state.read(9, .{ .token = token, .bytes = 124 }));
    try state.retire(9, lease);
    try std.testing.expectError(error.Stale, state.read(9, lease));
    try state.reclaim(7, token);
    try std.testing.expectError(error.Stale, state.reclaim(7, token));
    const next = try state.begin(7);
    try std.testing.expect(next != token);
    try std.testing.expectError(error.Stale, state.read(9, lease));
    try state.reclaim(7, next);
}
