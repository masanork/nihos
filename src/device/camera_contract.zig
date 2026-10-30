//! Host-side lifecycle model for one camera capture. No hardware or IPC.
const std = @import("std");

pub const Error = error{ Busy, Stale, Invalid, NotReady, Exhausted, Pinned };
pub const Format = enum { rgb565, yuv422, jpeg, bayer_bggr8 };
pub const Frame = struct { width: u32, height: u32, stride: u32, length: usize, format: Format };
pub const State = enum { idle, capturing, stopping, ready, borrowed, pinned };

/// One service owner serializes all calls. Tokens are never reused. The driver
/// must stop DMA and make data coherent before reporting completion; the model
/// cannot verify hardware quiescence or revoke a pointer already given to a client.
pub const Capture = struct {
    state: State = .idle,
    serial: u64 = 0,
    token: u64 = 0,
    capacity: usize = 0,
    frame: ?Frame = null,

    pub fn start(self: *Capture, capacity: usize) Error!u64 {
        if (self.state == .pinned) return error.Pinned;
        if (self.state != .idle) return error.Busy;
        if (capacity == 0) return error.Invalid;
        if (self.serial == std.math.maxInt(u64)) return error.Exhausted;
        self.serial += 1;
        self.token = self.serial;
        self.capacity = capacity;
        self.frame = null;
        self.state = .capturing;
        return self.token;
    }
    fn check(self: *const Capture, token: u64) Error!void {
        if (token == 0 or token != self.token or self.state == .idle) return error.Stale;
    }
    pub fn cancel(self: *Capture, token: u64) Error!void {
        try self.check(token);
        if (self.state != .capturing) return error.NotReady;
        self.state = .stopping;
    }
    /// clean means DMA/controller stopped and cache ownership returned.
    pub fn stopped(self: *Capture, token: u64, clean: bool) Error!void {
        try self.check(token);
        if (self.state != .stopping) return error.NotReady;
        self.state = if (clean) .idle else .pinned;
    }
    pub fn complete(self: *Capture, token: u64, frame: Frame, clean: bool) Error!void {
        try self.check(token);
        if (self.state != .capturing) return error.NotReady;
        if (!clean) {
            self.state = .pinned;
            return error.Pinned;
        }
        if (frame.width == 0 or frame.height == 0 or frame.length == 0 or frame.length > self.capacity) {
            self.state = .idle;
            return error.Invalid;
        }
        if (frame.format != .jpeg) {
            const pixel_bytes: u32 = if (frame.format == .bayer_bggr8) 1 else 2;
            const row = std.math.mul(u32, frame.width, pixel_bytes) catch {
                self.state = .idle;
                return error.Invalid;
            };
            const needed = std.math.mul(usize, frame.stride, frame.height) catch {
                self.state = .idle;
                return error.Invalid;
            };
            if (frame.stride < row or needed > frame.length) {
                self.state = .idle;
                return error.Invalid;
            }
        }
        self.frame = frame;
        self.state = .ready;
    }
    pub fn borrow(self: *Capture, token: u64) Error!Frame {
        try self.check(token);
        if (self.state != .ready) return error.NotReady;
        self.state = .borrowed;
        return self.frame.?;
    }
    pub fn release(self: *Capture, token: u64) Error!void {
        try self.check(token);
        if (self.state != .borrowed and self.state != .ready) return error.NotReady;
        self.frame = null;
        self.state = .idle;
    }
};

test "one frame remains owned until released; stale completion cannot affect next capture" {
    var c: Capture = .{};
    const a = try c.start(128);
    try std.testing.expectError(error.Busy, c.start(128));
    try c.complete(a, .{ .width = 4, .height = 4, .stride = 8, .length = 32, .format = .rgb565 }, true);
    _ = try c.borrow(a);
    try std.testing.expectError(error.Busy, c.start(128));
    try c.release(a);
    const b = try c.start(128);
    try std.testing.expectError(error.Stale, c.complete(a, undefined, true));
    try c.cancel(b);
    try std.testing.expectError(error.NotReady, c.complete(b, undefined, true));
    try c.stopped(b, true);
    try std.testing.expectEqual(State.idle, c.state);
}

test "raw Bayer frame retains its color layout and checks stride" {
    var c: Capture = .{};
    const a = try c.start(1280 * 720);
    try c.complete(a, .{ .width = 1280, .height = 720, .stride = 1280, .length = 1280 * 720, .format = .bayer_bggr8 }, true);
    const frame = try c.borrow(a);
    try std.testing.expectEqual(Format.bayer_bggr8, frame.format);
    try c.release(a);
    const b = try c.start(1280 * 720);
    try std.testing.expectError(error.Invalid, c.complete(b, .{ .width = 1280, .height = 720, .stride = 1279, .length = 1280 * 720, .format = .bayer_bggr8 }, true));
}
test "invalid frame rejected and uncertain cleanup pins buffer" {
    var c: Capture = .{};
    const a = try c.start(32);
    try std.testing.expectError(error.Invalid, c.complete(a, .{ .width = 4, .height = 4, .stride = 8, .length = 31, .format = .yuv422 }, true));
    const b = try c.start(32);
    try c.cancel(b);
    try c.stopped(b, false);
    try std.testing.expectError(error.Pinned, c.start(32));
}
