//! Read-only Hosted 3 C6 OTA-layout snapshot. This does not prove recovery.
const std = @import("std");
const wire = @import("hosted.zig");
pub const request_id: u32 = 0x4e4f_4951;
pub const result_id: u32 = 0x4e4f_4952;
pub const Error = wire.Error || error{ InvalidArgument, Incomplete, Deadline, WrongState };
pub const Partition = struct { offset: u32, size: u32 };
pub const Info = struct {
    flash_size: u32,
    running: Partition,
    boot: Partition,
    next: Partition,
    running_state: ?u32,
    secure_boot: bool,
    flash_encrypted: bool,
};

/// A single bounded query. The owner must never reuse a nonce on this stream,
/// must retire it on reset, and must hold the transport exclusively. Route only
/// this request's acknowledgement and result event to receive().
pub const Session = struct {
    phase: enum { idle, waiting, complete, failed } = .idle,
    uid: u32 = 0,
    nonce: u32 = 0,
    last_now: u64 = 0,
    deadline: u64 = 0,
    acknowledged: bool = false,
    result: ?Info = null,

    pub fn start(self: *Session, out: []u8, uid: u32, nonce: u32, now: u64, deadline: u64) Error![]const u8 {
        if (self.phase != .idle) return error.WrongState;
        if (deadline <= now) return error.InvalidArgument;
        const packet = try request(out, uid, nonce);
        self.* = .{ .phase = .waiting, .uid = uid, .nonce = nonce, .last_now = now, .deadline = deadline };
        return packet;
    }
    pub fn receive(self: *Session, rpc: wire.Rpc, now: u64) Error!void {
        if (self.phase != .waiting) return error.WrongState;
        errdefer self.fail();
        if (now < self.last_now or now >= self.deadline) return error.Deadline;
        self.last_now = now;
        if (rpc.kind == 2 and rpc.id == 644) {
            if (self.acknowledged) return error.Stale;
            try acceptAck(rpc, self.uid);
            self.acknowledged = true;
        } else if (rpc.kind == 3 and rpc.id == 788) {
            if (self.result != null) return error.Stale;
            self.result = try parseEvent(rpc, self.nonce);
        } else return error.Malformed;
        if (self.acknowledged and self.result != null) self.phase = .complete;
    }
    pub fn expire(self: *Session, now: u64) bool {
        if (self.phase == .waiting and (now < self.last_now or now >= self.deadline)) {
            self.fail();
            return true;
        }
        return false;
    }
    pub fn fail(self: *Session) void {
        self.phase = .failed;
        self.result = null;
    }
};

/// Caller owns a unique, nonzero nonce and the exclusive Hosted RPC stream.
pub fn request(out: []u8, uid: u32, nonce: u32) Error![]const u8 {
    if (uid == 0 or nonce == 0) return error.InvalidArgument;
    var raw: [8]u8 = @splat(0);
    raw[0] = 1;
    std.mem.writeInt(u32, raw[4..8], nonce, .little);
    var custom: [32]u8 = undefined;
    var w: wire.Writer = .{ .out = &custom };
    try w.uint(1, request_id);
    try w.data(2, &raw);
    return try wire.request(out, 388, uid, w.slice());
}
pub fn acceptAck(rpc: wire.Rpc, expected_uid: u32) Error!void {
    if (expected_uid == 0 or rpc.kind != 2 or rpc.id != 644 or rpc.uid != expected_uid) return error.Stale;
    if (try wire.integer(rpc.body, 1) != 0) return error.Rejected;
}
fn partition(raw: []const u8, pos: usize, flash_size: u32) Error!Partition {
    const offset = std.mem.readInt(u32, raw[pos..][0..4], .little);
    const size = std.mem.readInt(u32, raw[pos + 4 ..][0..4], .little);
    if (size == 0 or offset > flash_size or size > flash_size - offset) return error.Malformed;
    return .{ .offset = offset, .size = size };
}
pub fn parseEvent(rpc: wire.Rpc, nonce: u32) Error!Info {
    if (nonce == 0) return error.InvalidArgument;
    if (rpc.kind != 3 or rpc.id != 788) return error.Malformed;
    var reader: wire.Reader = .{ .bytes = rpc.body };
    var status: ?u32 = null;
    var id: ?u32 = null;
    var data: ?[]const u8 = null;
    while (try reader.next()) |field| switch (field.number) {
        1, 2 => {
            if (field.kind != 0 or field.value > std.math.maxInt(u32)) return error.Malformed;
            const dest = if (field.number == 1) &status else &id;
            if (dest.* != null) return error.Malformed;
            dest.* = @intCast(field.value);
        },
        3 => {
            if (field.kind != 2 or data != null) return error.Malformed;
            data = field.bytes orelse return error.Malformed;
        },
        else => return error.Malformed,
    };
    if ((status orelse 0) != 0 or id != result_id) return error.Rejected;
    const raw = data orelse return error.Malformed;
    if (raw.len != 40 or raw[0] != 1 or raw[1] & 0x80 != 0 or raw[2] != 0 or raw[3] != 0) return error.Malformed;
    if (std.mem.readInt(u32, raw[4..8], .little) != nonce) return error.Stale;
    const flags = raw[1];
    if (flags & 0x47 != 0x47) return error.Incomplete;
    const flash_size = std.mem.readInt(u32, raw[8..12], .little);
    const running = try partition(raw, 12, flash_size);
    const boot = try partition(raw, 20, flash_size);
    const next = try partition(raw, 28, flash_size);
    if (running.offset < next.offset + next.size and next.offset < running.offset + running.size) return error.Malformed;
    const state = std.mem.readInt(u32, raw[36..40], .little);
    if (flags & 0x20 == 0 and state != 0) return error.Malformed;
    return .{ .flash_size = flash_size, .running = running, .boot = boot, .next = next, .running_state = if (flags & 0x20 != 0) state else null, .secure_boot = flags & 8 != 0, .flash_encrypted = flags & 0x10 != 0 };
}
