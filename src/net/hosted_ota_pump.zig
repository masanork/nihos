//! Single-owner, explicitly driven OTA transport. No automatic retransmission
//! after a successful/uncertain send. Caller supplies an absolute deadline,
//! an immutable reviewed image and an exclusively owned fresh Hosted stream.
const ota = @import("hosted_ota.zig");
const wire = @import("hosted.zig");

pub const State = enum { ready, queued, waiting, complete, failed };
pub const Pump = struct {
    client: ota.Client,
    decoder: wire.Decoder = .{},
    state: State = .ready,
    queued_len: usize = 0,
    deadline: u64,
    last_now: u64,
    rx: [512]u8 = @splat(0),

    pub fn init(client: ota.Client, now: u64, deadline: u64) error{InvalidDeadline}!Pump {
        if (deadline <= now) return error.InvalidDeadline;
        return .{ .client = client, .last_now = now, .deadline = deadline };
    }
    /// stream has send([]const u8) and receive([]u8), both returning !usize.
    /// A zero send is explicitly defined by ProfileStream as no credits/no
    /// write; only that case can retain and retry the same unsent frame.
    pub fn step(self: *Pump, stream: anytype, now: u64) !void {
        if (self.state == .complete or self.state == .failed) return error.WrongState;
        errdefer {
            self.state = .failed;
            self.client.fail();
        }
        if (now < self.last_now or now >= self.deadline) return error.Timeout;
        self.last_now = now;
        if (self.state == .waiting) {
            const count = try stream.receive(&self.rx);
            if (count > self.rx.len) return error.InvalidBuffer;
            for (self.rx[0..count]) |byte| {
                if (try self.decoder.push(byte)) |frame| {
                    if (self.state == .waiting and try self.client.receive(frame)) {
                        self.state = if (self.client.phase == .complete) .complete else .ready;
                    }
                }
            }
        }
        if (self.state == .ready) {
            const frame = try self.client.next();
            self.queued_len = frame.len;
            self.state = .queued;
        }
        if (self.state == .queued) {
            const count = try stream.send(self.client.output[0..self.queued_len]);
            if (count != 0 and count != self.queued_len) return error.PartialPacket;
            if (count == self.queued_len) self.state = .waiting;
        }
    }
};
