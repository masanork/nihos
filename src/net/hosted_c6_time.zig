//! Experimental Hosted 2.13 C6 SNTP snapshot contract. Not authenticated time.
const std = @import("std");
fn timeSection() []const u8 {
    const root = @import("root");
    if (@hasDecl(root, "C6TimeFlash") and root.C6TimeFlash) return ".flash.text.time";
    return if (@import("builtin").object_format == .macho) "__TEXT,__text" else ".text";
}
const hosted = @import("hosted.zig");
const request_message_id: u32 = 0x4e54_5151;
const result_message_id: u32 = 0x4e54_5152;
const Error = hosted.Error || error{ Busy, Deadline, InvalidArgument };
pub const Sample = struct { seconds: u64, age_seconds: u32 };
pub const Session = struct {
    generation: u64 = 0,
    next_id: u32 = 1,
    outstanding: ?u32 = null,
    deadline: u64 = 0,
    pub noinline fn reset(self: *Session, generation: u64) linksection(timeSection()) void {
        self.generation = generation;
        self.outstanding = null;
    }
    pub noinline fn start(self: *Session, out: []u8, uid: u32, now: u64, deadline: u64) linksection(timeSection()) Error![]const u8 {
        if (self.generation == 0 or self.next_id == 0) return error.Stale;
        if (self.outstanding != null) return error.Busy;
        if (uid == 0 or deadline <= now) return error.InvalidArgument;
        var raw: [16]u8 = @splat(0);
        raw[0] = 1;
        std.mem.writeInt(u32, raw[4..8], self.next_id, .little);
        std.mem.writeInt(u64, raw[8..16], self.generation, .little);
        var custom: [32]u8 = undefined;
        var writer = hosted.Writer{ .out = &custom };
        try writer.uint(1, request_message_id);
        try writer.data(2, &raw);
        const packet = try hosted.request(out, 388, uid, writer.slice());
        self.outstanding = self.next_id;
        self.next_id +%= 1; // zero means exhaustion; reset does not reuse IDs.
        self.deadline = deadline;
        return packet;
    }
    /// Retire a request after a rejected acknowledgement or local cancellation.
    pub noinline fn cancel(self: *Session) linksection(timeSection()) void {
        self.outstanding = null;
    }
    pub noinline fn expire(self: *Session, now: u64) linksection(timeSection()) bool {
        if (self.outstanding != null and now >= self.deadline) {
            self.outstanding = null;
            return true;
        }
        return false;
    }
    pub noinline fn receive(self: *Session, rpc: hosted.Rpc, now: u64) linksection(timeSection()) Error!?Sample {
        if (self.expire(now)) return error.Deadline;
        const id = self.outstanding orelse return error.Stale;
        if (rpc.kind != 3 or rpc.id != 788) return error.Malformed;
        var reader = hosted.Reader{ .bytes = rpc.body };
        var status: ?u32 = null;
        var message_id: ?u32 = null;
        var data: ?[]const u8 = null;
        while (try reader.next()) |field| switch (field.number) {
            1, 2 => {
                if (field.kind != 0 or field.value > std.math.maxInt(u32)) return error.Malformed;
                const target = if (field.number == 1) &status else &message_id;
                if (target.* != null) return error.Malformed;
                target.* = @intCast(field.value);
            },
            3 => {
                if (field.kind != 2 or data != null) return error.Malformed;
                data = field.bytes orelse return error.Malformed;
            },
            else => return error.Malformed,
        };
        if ((status orelse 0) != 0 or message_id != result_message_id) return error.Rejected;
        const raw = data orelse return error.Malformed;
        if (raw.len != 32 or raw[0] != 1 or raw[1] > 1 or raw[2] != 0 or raw[3] != 0 or
            !std.mem.eql(u8, raw[28..32], &.{ 0, 0, 0, 0 })) return error.Malformed;
        if (std.mem.readInt(u32, raw[4..8], .little) != id or
            std.mem.readInt(u64, raw[8..16], .little) != self.generation) return error.Stale;
        const seconds = std.mem.readInt(u64, raw[16..24], .little);
        const age = std.mem.readInt(u32, raw[24..28], .little);
        if (raw[1] == 0 and (seconds != 0 or age != 0)) return error.Malformed;
        self.outstanding = null;
        return if (raw[1] == 1) Sample{ .seconds = seconds, .age_seconds = age } else null;
    }
};
/// The CustomRpc transport acknowledgement says nothing about synchronization.
pub noinline fn acceptAck(rpc: hosted.Rpc, expected_uid: u32) linksection(timeSection()) Error!void {
    if (expected_uid == 0 or rpc.kind != 2 or rpc.id != 644 or rpc.uid != expected_uid) return error.Stale;
    if (try hosted.integer(rpc.body, 1) != 0) return error.Rejected;
}
