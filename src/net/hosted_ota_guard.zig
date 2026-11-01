//! OTA session with explicit one-shot serial command gating. Hardware ownership,
//! byte delivery and deadline clocks are managed by the caller.
const session = @import("hosted_ota_session.zig");
const arm = @import("hosted_ota_arm.zig");
pub const State = enum { handshake, awaiting_start, transfer, complete, failed };
pub const Guard = struct {
    session: session.Session,
    start: arm.Arm,
    state: State,
    deadline: u64,
    last_now: u64,

    /// Initialize in final storage: the session is larger than a P4 stack.
    pub fn initInPlace(self: *Guard, image: []const u8, digest: [32]u8, now: u64, deadline: u64) !void {
        try self.session.initInPlace(image, digest, now, deadline);
        self.start = try arm.Arm.init(digest, now, deadline);
        self.state = .handshake;
        self.deadline = deadline;
        self.last_now = now;
    }
    fn checkTime(self: *Guard, now: u64) !void {
        if (now < self.last_now or now >= self.deadline) return error.Timeout;
        self.last_now = now;
    }
    /// No Begin is sent while waiting for the exact start token.
    pub fn step(self: *Guard, stream: anytype, now: u64) !void {
        if (self.state == .complete or self.state == .failed) return error.WrongState;
        errdefer self.state = .failed;
        try self.checkTime(now);
        if (self.state == .awaiting_start) return;
        try self.session.step(stream, now);
        if (self.state == .handshake and self.session.state == .transfer) self.state = .awaiting_start;
        if (self.session.state == .complete) self.state = .complete;
    }
    pub fn feed(self: *Guard, byte: u8, now: u64) !bool {
        if (self.state != .awaiting_start) return error.WrongState;
        errdefer self.state = .failed;
        try self.checkTime(now);
        const armed = try self.start.feed(byte, now);
        if (armed) self.state = .transfer;
        return armed;
    }
};
