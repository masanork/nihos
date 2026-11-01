//! Explicit, single-flight ESP-Hosted 1.4.1 OTA transaction encoder.
//! No transport, timers, automatic retry, or firmware storage is supplied here.
//! The caller must exclusively own the SDIO/RPC channel and keep image bytes
//! immutable for the whole transaction. An uncertain transmission is fatal.
const std = @import("std");
const wire = @import("hosted.zig");

pub const slot_size = 1536 * 1024;
pub const chunk_size = 384; // Fits the existing <=512-byte Hosted frame path.
pub const Error = wire.Error || error{ InvalidImage, DigestMismatch, WrongState, UidExhausted };
pub const Phase = enum { begin, write, end, complete, failed };

pub const Client = struct {
    image: []const u8,
    digest: [32]u8,
    phase: Phase = .begin,
    offset: usize = 0,
    uid: u32,
    sequence: u16,
    pending_id: ?u32 = null,
    pending_len: usize = 0,
    output: [512]u8 = undefined,
    status: u32 = 0,

    /// expected_digest must come from the independently reviewed candidate.
    /// Image is a C6 app image, never an offset-zero merged flash image.
    pub fn init(image: []const u8, expected_digest: [32]u8, initial_uid: u32, sequence: u16) Error!Client {
        if (image.len < 36 or image.len > slot_size or image[0] != 0xe9 or
            std.mem.readInt(u16, image[12..14], .little) != 13 or
            std.mem.readInt(u32, image[32..36], .little) != 0xabcd5432) return error.InvalidImage;
        var actual: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(image, &actual, .{});
        if (!std.mem.eql(u8, &actual, &expected_digest)) return error.DigestMismatch;
        return .{ .image = image, .digest = expected_digest, .uid = initial_uid, .sequence = sequence };
    }

    /// Returns a frame once. Calling again before the response is forbidden.
    /// Treat even a failed/partial transport send as uncertain: call fail().
    pub fn next(self: *Client) Error![]const u8 {
        if (self.pending_id != null or self.phase == .complete or self.phase == .failed) return error.WrongState;
        if (self.uid == std.math.maxInt(u32)) return error.UidExhausted;
        if (self.phase == .end) {
            var actual: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(self.image, &actual, .{});
            if (!std.mem.eql(u8, &actual, &self.digest)) {
                self.fail();
                return error.DigestMismatch;
            }
        }
        var body_bytes: [chunk_size + 8]u8 = undefined;
        var body = wire.Writer{ .out = &body_bytes };
        const count: usize = if (self.phase == .write) @min(chunk_size, self.image.len - self.offset) else 0;
        const id: u32 = switch (self.phase) {
            .begin => 272,
            .write => blk: {
                try body.data(1, self.image[self.offset..][0..count]);
                break :blk 273;
            },
            .end => 274,
            else => return error.WrongState,
        };
        var payload: [480]u8 = undefined;
        const uid = self.uid + 1;
        const message = try wire.request(&payload, id, uid, body.slice());
        const result = try wire.frame(&self.output, 3, self.sequence, message);
        self.uid = uid;
        self.sequence +%= 1;
        self.pending_id = id;
        self.pending_len = count;
        return result;
    }

    /// Only matching responses change state. The caller owns timeouts and must
    /// stop on SDIO reset or unknown send outcome; no request is replayable.
    pub fn receive(self: *Client, frame: wire.Frame) Error!bool {
        if (self.pending_id == null or self.phase == .failed) return error.WrongState;
        if (frame.interface != 3) return false;
        const response = wire.rpc(frame.payload) catch |err| {
            self.fail();
            return err;
        };
        if (response.kind != 2 or response.uid != self.uid or response.id != self.pending_id.? + 256) return false;
        const status = wire.integer(response.body, 1) catch |err| {
            self.fail();
            return err;
        };
        self.status = status;
        if (status != 0) {
            self.fail();
            return error.Rejected;
        }
        switch (self.phase) {
            .begin => self.phase = .write,
            .write => {
                self.offset += self.pending_len;
                if (self.offset == self.image.len) self.phase = .end;
            },
            .end => self.phase = .complete, // Accepted, not proof of reboot/health.
            else => {
                self.fail();
                return error.WrongState;
            },
        }
        self.pending_id = null;
        self.pending_len = 0;
        return true;
    }
    pub fn fail(self: *Client) void {
        self.phase = .failed;
        self.pending_id = null;
    }
};
