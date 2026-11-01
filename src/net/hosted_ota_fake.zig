//! In-memory C6 OTA responder for a P4 transfer-only diagnostic. This type
//! never accesses hardware or writes flash. It rejects nonsequential bytes.
const std = @import("std");
const wire = @import("hosted.zig");
const ota = @import("hosted_ota.zig");
pub const Fake = struct {
    image: []const u8,
    response: [128]u8 = undefined,
    used: usize = 0,
    offset: usize = 0,
    last_uid: u32 = 0,
    phase: enum { begin, write, end, activate, complete } = .begin,
    explicit_activation: bool = false,
    pub fn send(self: *Fake, frame: []const u8) !usize {
        if (frame.len < 24 or frame[0] != 3 or self.used != 0) return error.Malformed;
        var reader: wire.Reader = .{ .bytes = frame[24..] };
        var id: u32 = 0;
        var uid: u32 = 0;
        var body: ?[]const u8 = null;
        while (try reader.next()) |field| {
            if (field.number == 2) id = @intCast(field.value);
            if (field.number == 3) uid = @intCast(field.value);
            if (field.number >= 256) body = field.bytes;
        }
        if (uid == 0 or (self.last_uid != 0 and uid != self.last_uid + 1)) return error.Stale;
        const payload = body orelse return error.Malformed;
        switch (self.phase) {
            .begin => {
                if (id != 272 or payload.len != 0) return error.Malformed;
                self.phase = .write;
            },
            .write => {
                if (id != 273) return error.Malformed;
                const chunk = (try wire.data(payload, 1)) orelse return error.Malformed;
                if (chunk.len == 0 or chunk.len > ota.chunk_size or chunk.len > self.image.len - self.offset or
                    !std.mem.eql(u8, chunk, self.image[self.offset..][0..chunk.len])) return error.Malformed;
                self.offset += chunk.len;
                if (self.offset == self.image.len) self.phase = .end;
            },
            .end => {
                if (id != 274 or payload.len != 0) return error.Malformed;
                self.phase = if (self.explicit_activation) .activate else .complete;
            },
            .activate => {
                if (id != 266 or payload.len != 0) return error.Malformed;
                self.phase = .complete;
            },
            .complete => return error.Malformed,
        }
        self.last_uid = uid;
        var buffer: [96]u8 = undefined;
        const response = try wire.request(&buffer, id + 256, uid, &.{});
        buffer[13] = 2;
        self.used = (try wire.frame(&self.response, 3, 0, response)).len;
        return frame.len;
    }
    pub fn receive(self: *Fake, destination: []u8) !usize {
        if (self.used > destination.len) return error.Capacity;
        const count = self.used;
        @memcpy(destination[0..count], self.response[0..count]);
        self.used = 0;
        return count;
    }
};

/// Wrap the physical stream in simulation mode and reject OTA RPCs even if
/// the simulated/physical routing above it is accidentally changed.
pub fn NoOtaStream(comptime Stream: type) type {
    return struct {
        inner: *Stream,
        const Self = @This();
        pub fn receive(self: *Self, destination: []u8) !usize {
            return self.inner.receive(destination);
        }
        pub fn send(self: *Self, frame: []const u8) !usize {
            if (frame.len < 12) return error.Malformed;
            if (frame[0] == 5) return self.inner.send(frame);
            if (frame[0] != 3 or frame.len < 24 or
                !std.mem.eql(u8, frame[15..21], "RPCRsp")) return error.Malformed;
            var reader: wire.Reader = .{ .bytes = frame[24..] };
            var id: ?u32 = null;
            while (try reader.next()) |field| {
                if (field.number == 2) {
                    if (id != null or field.kind != 0 or field.value > 0xffffffff) return error.Malformed;
                    id = @intCast(field.value);
                }
            }
            const command = id orelse return error.Malformed;
            if (command == 266 or (command >= 272 and command <= 274)) return error.PersistentWriteForbidden;
            return self.inner.send(frame);
        }
    };
}
