//! Experimental one-datagram Hosted sender. Not wired to a runtime service.
const guard = @import("hosted_udp_lease.zig");
const wire = @import("udp_ipv4.zig");
const split = @import("hosted_network_split.zig");

pub const Phase = enum { idle, queued, retired };
pub const Outcome = enum { pending, sent };
pub const Error = guard.Error || error{ Busy, Retired, Deadline, PartialPacket };

/// The caller owns and serializes this object, the address state and the
/// stream. Before each poll it must drain/apply pending Hosted control events.
/// No automatic reconnect, hardware quiescence or socket API is provided.
pub const Sender = struct {
    binding: guard.Lease,
    state: *split.State,
    phase: Phase = .idle,
    packet: [1512]u8 = @splat(0),
    padding: [1536]u8 = @splat(0),
    length: usize = 0,
    deadline: u64 = 0,
    last_now: u64 = 0,

    pub fn init(state: *split.State, binding: guard.Lease) Error!Sender {
        try binding.check(state);
        return .{ .state = state, .binding = binding };
    }

    /// Input is copied into owned storage; it may be released on return and
    /// must not overlap the sender's packet buffer.
    pub fn enqueue(self: *Sender, peer: wire.Endpoint, payload: []const u8, sequence: u16, now: u64, deadline: u64) Error!void {
        if (self.phase == .retired) return error.Retired;
        if (self.phase != .idle) return error.Busy;
        if (deadline <= now or now < self.last_now) return error.Deadline;
        const frame = try self.binding.prepare(self.state, &self.packet, peer, payload, sequence);
        self.length = frame.len;
        self.last_now = now;
        self.deadline = deadline;
        self.phase = .queued;
    }

    /// Cancel only a queued packet: no poll is in progress and a prior
    /// pending result guarantees that no transfer started. The caller must
    /// serialize cancellation with poll and control-event processing.
    pub fn cancel(self: *Sender) Error!void {
        if (self.phase == .retired) return error.Retired;
        if (self.phase != .queued) return error.Busy;
        self.length = 0;
        self.phase = .idle;
    }

    /// Retire this owner after disconnect/reset and revoke its address only
    /// if it is still current. This does not establish DMA quiescence.
    pub fn invalidate(self: *Sender, stream: anytype) void {
        if (self.phase != .retired) self.retire(stream, true);
    }

    /// Zero credits means no write began. Nonzero partial writes or any
    /// transport error are ambiguous and permanently retire this owner.
    pub fn poll(self: *Sender, stream: anytype, now: u64) !Outcome {
        if (self.phase == .retired) return error.Retired;
        if (self.phase != .queued) return error.Busy;
        if (now < self.last_now or now >= self.deadline) {
            self.retire(stream, false);
            return error.Deadline;
        }
        self.last_now = now;
        self.binding.check(self.state) catch |err| {
            self.retire(stream, false);
            return err;
        };
        const frame = self.packet[0..self.length];
        const written = (if (frame.len <= 512) stream.send(frame) else stream.sendLong(frame, &self.padding)) catch |err| {
            self.retire(stream, true);
            return err;
        };
        if (written == 0) return .pending;
        if (written != frame.len) {
            self.retire(stream, true);
            return error.PartialPacket;
        }
        self.length = 0;
        self.phase = .idle;
        return .sent;
    }

    fn retire(self: *Sender, stream: anytype, invalidate_current: bool) void {
        // Do not destroy an address acquired by a newer generation.
        if (invalidate_current) {
            if (self.binding.check(self.state)) |_| {
                _ = self.state.invalidate();
            } else |_| {}
        }
        self.phase = .retired;
        self.length = 0;
        stream.invalidate();
    }
};
