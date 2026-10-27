//! Minimal ESP-Hosted MCU RPC profile, independently implemented from the
//! v2.13.1 public header/proto definitions. No OTA or persistent-write RPCs.
const std = @import("std");
pub const Error = error{ Malformed, Capacity, Fragmented, Checksum, Stale, Rejected };
pub const Frame = struct { interface: u8, payload: []const u8 };
pub const Decoder = struct {
    bytes: [4096]u8 = @splat(0),
    used: usize = 0,
    wanted: usize = 12,
    poisoned: bool = false,
    unchecked: u32 = 0,
    /// Borrowed frame remains valid only until the next push.
    pub fn push(self: *Decoder, byte: u8) Error!?Frame {
        if (self.poisoned) return error.Malformed;
        errdefer self.poisoned = true;
        self.bytes[self.used] = byte;
        self.used += 1;
        if (self.used == 12) {
            if (self.bytes[1] & 1 != 0) return error.Fragmented;
            if (self.bytes[0] & 15 == 5 and self.bytes[11] != 0x33) return error.Malformed;
            const offset = std.mem.readInt(u16, self.bytes[4..6], .little);
            const length = std.mem.readInt(u16, self.bytes[2..4], .little);
            if (offset != 12 or length == 0 or length > self.bytes.len - 12) return error.Malformed;
            self.wanted = 12 + @as(usize, length);
        }
        if (self.used != self.wanted) return null;
        const expected = std.mem.readInt(u16, self.bytes[6..8], .little);
        if (expected != 0 and expected != checksum(self.bytes[0..self.used])) return error.Checksum;
        if (expected == 0) self.unchecked +|= 1;
        const result = Frame{ .interface = self.bytes[0], .payload = self.bytes[12..self.used] };
        self.used = 0;
        self.wanted = 12;
        return result;
    }
};
fn checksum(bytes: []const u8) u16 {
    var sum: u16 = 0;
    for (bytes, 0..) |byte, i| if (i != 6 and i != 7) {
        sum +%= byte;
    };
    return sum;
}
pub fn frame(out: []u8, interface: u8, sequence: u16, payload: []const u8) Error![]const u8 {
    if (payload.len == 0 or payload.len > 1500 or payload.len + 12 > out.len) return error.Capacity;
    const result = out[0 .. payload.len + 12];
    @memset(result[0..12], 0);
    result[0] = interface;
    if (interface & 15 == 5) result[11] = 0x33;
    std.mem.writeInt(u16, result[2..4], @intCast(payload.len), .little);
    std.mem.writeInt(u16, result[4..6], 12, .little);
    std.mem.writeInt(u16, result[8..10], sequence, .little);
    @memcpy(result[12..], payload);
    std.mem.writeInt(u16, result[6..8], checksum(result), .little);
    return result;
}

pub const Writer = struct {
    out: []u8,
    used: usize = 0,
    pub fn raw(self: *Writer, bytes: []const u8) Error!void {
        if (bytes.len > self.out.len - self.used) return error.Capacity;
        @memcpy(self.out[self.used..][0..bytes.len], bytes);
        self.used += bytes.len;
    }
    fn varint(self: *Writer, number: u64) Error!void {
        var value = number;
        while (value >= 128) : (value >>= 7) try self.raw(&.{@as(u8, @truncate(value)) | 128});
        try self.raw(&.{@intCast(value)});
    }
    pub fn uint(self: *Writer, field: u32, value: u64) Error!void {
        try self.varint(@as(u64, field) << 3);
        try self.varint(value);
    }
    pub fn data(self: *Writer, field: u32, bytes: []const u8) Error!void {
        try self.varint((@as(u64, field) << 3) | 2);
        try self.varint(bytes.len);
        try self.raw(bytes);
    }
    pub fn slice(self: *const Writer) []const u8 {
        return self.out[0..self.used];
    }
};
pub const Field = struct { number: u32, kind: u3, value: u64 = 0, bytes: ?[]const u8 = null };
pub const Reader = struct {
    bytes: []const u8,
    pos: usize = 0,
    fn varint(self: *Reader) Error!u64 {
        var value: u64 = 0;
        for (0..10) |i| {
            if (self.pos == self.bytes.len) return error.Malformed;
            const byte = self.bytes[self.pos];
            self.pos += 1;
            if (i == 9 and byte > 1) return error.Malformed;
            value |= @as(u64, byte & 127) << @as(u6, @intCast(i * 7));
            if (byte & 128 == 0) return value;
        }
        return error.Malformed;
    }
    pub fn next(self: *Reader) Error!?Field {
        if (self.pos == self.bytes.len) return null;
        const tag = try self.varint();
        if (tag >> 3 == 0 or tag >> 3 > 0x1fffffff) return error.Malformed;
        var result = Field{ .number = @intCast(tag >> 3), .kind = @intCast(tag & 7) };
        switch (tag & 7) {
            0 => result.value = try self.varint(),
            1, 2, 5 => {
                const length = if (tag & 7 == 2) try self.varint() else if (tag & 7 == 1) @as(u64, 8) else 4;
                if (length > self.bytes.len - self.pos) return error.Malformed;
                result.bytes = self.bytes[self.pos..][0..@intCast(length)];
                self.pos += @intCast(length);
            },
            else => return error.Malformed,
        }
        return result;
    }
};
pub const Rpc = struct { kind: u32, id: u32, uid: u32, body: []const u8 };
pub fn rpc(payload: []const u8) Error!Rpc {
    // Exact endpoint TLV and exact protobuf length; never scan for a substring.
    if (payload.len < 12 or payload[0] != 1 or !std.mem.eql(u8, payload[1..3], &.{ 6, 0 }) or
        (!std.mem.eql(u8, payload[3..9], "RPCRsp") and !std.mem.eql(u8, payload[3..9], "RPCEvt")) or payload[9] != 2 or
        std.mem.readInt(u16, payload[10..12], .little) != payload.len - 12) return error.Malformed;
    var reader = Reader{ .bytes = payload[12..] };
    var kind: ?u32 = null;
    var id: ?u32 = null;
    var uid: ?u32 = null;
    var body: ?[]const u8 = null;
    var body_id: u32 = 0;
    while (try reader.next()) |field| {
        if (field.number <= 3) {
            if (field.bytes != null or field.value > std.math.maxInt(u32)) return error.Malformed;
            const dest = switch (field.number) {
                1 => &kind,
                2 => &id,
                3 => &uid,
                else => return error.Malformed,
            };
            if (dest.* != null) return error.Malformed;
            dest.* = @intCast(field.value);
        } else if (field.number >= 256) {
            if (body != null or field.kind != 2) return error.Malformed;
            body = field.bytes orelse return error.Malformed;
            body_id = field.number;
        }
    }
    const message_id = id orelse return error.Malformed;
    const message_kind = kind orelse return error.Malformed;
    if (body_id != message_id or (message_kind != 2 and message_kind != 3)) return error.Malformed;
    if (!std.mem.eql(u8, payload[3..9], if (message_kind == 2) "RPCRsp" else "RPCEvt")) return error.Malformed;
    return .{ .kind = message_kind, .id = message_id, .uid = uid orelse 0, .body = body orelse return error.Malformed };
}
pub fn request(out: []u8, id: u32, uid: u32, body: []const u8) Error![]const u8 {
    if (out.len < 12 or uid == 0) return error.Capacity;
    var writer = Writer{ .out = out[12..] };
    try writer.uint(1, 1);
    try writer.uint(2, id);
    try writer.uint(3, uid);
    try writer.data(id, body);
    @memcpy(out[0..10], &[_]u8{ 1, 6, 0, 'R', 'P', 'C', 'R', 's', 'p', 2 });
    std.mem.writeInt(u16, out[10..12], @intCast(writer.used), .little);
    return out[0 .. 12 + writer.used];
}
pub fn integer(bytes: []const u8, number: u32) Error!u32 {
    var reader = Reader{ .bytes = bytes };
    var result: ?u32 = null;
    while (try reader.next()) |field| if (field.number == number) {
        if (result != null or field.bytes != null) return error.Malformed;
        // Protobuf int32 may encode a negative result as a ten-byte varint.
        result = @truncate(field.value);
    };
    return result orelse 0; // Proto3 default for omitted scalar fields.
}
pub fn data(bytes: []const u8, number: u32) Error!?[]const u8 {
    var reader = Reader{ .bytes = bytes };
    var result: ?[]const u8 = null;
    while (try reader.next()) |field| if (field.number == number) {
        if (result != null or field.kind != 2) return error.Malformed;
        result = field.bytes orelse return error.Malformed;
    };
    return result;
}
pub const capabilities = [_]u8{ 0x22, 15, 0x44, 1, 0, 0x45, 1, 0x0d, 0x46, 1, 0, 0x47, 1, 80, 0x48, 1, 60 };
