//! Experimental on-media page map codec. No allocation or device I/O.
const std = @import("std");
pub const page_bytes = 4096;
pub const crc_offset = page_bytes - 4;
pub const header_bytes = 48;
pub const leaf_entries = (crc_offset - header_bytes) / 16;
pub const children = (crc_offset - header_bytes) / 32;
pub const max_height = 3;
pub const magic: u32 = 0x4e494d35;
pub const version: u32 = 5;
pub const Error = error{Corrupt};
pub const Bounds = struct {
    low: u32 = 0,
    high: u32 = 0,
    pub fn include(self: *Bounds, other: Bounds) void {
        if (other.low == 0) return;
        self.low = if (self.low == 0) other.low else @min(self.low, other.low);
        self.high = @max(self.high, other.high);
    }
    pub fn intersects(self: Bounds, start: u64, end: u64) bool {
        return self.low < end and self.high > start;
    }
};
pub const Ref = struct { page: u64 = 0, checksum: u32 = 0, data: Bounds = .{}, nodes: Bounds = .{} };
pub const Data = struct { page: u64, checksum: u32 };
pub const Limits = struct { start: u64, end: u64 };
pub fn pages(length: u64) u64 {
    return length / page_bytes + @intFromBool(length % page_bytes != 0);
}
pub fn capacity(level: u8) u64 {
    var result: u64 = leaf_entries;
    for (0..level) |_| result *= children;
    return result;
}
pub fn height(length: u64) Error!u8 {
    if (length == 0 or pages(length) > capacity(max_height)) return error.Corrupt;
    var level: u8 = 0;
    while (pages(length) > capacity(level)) level += 1;
    return level;
}
pub fn count(level: u8, base: u64, length: u64) Error!usize {
    if (level > max_height or base >= pages(length) or base % capacity(level) != 0) return error.Corrupt;
    const remaining = @min(capacity(level), pages(length) - base);
    const stride = if (level == 0) 1 else capacity(level - 1);
    return @intCast(remaining / stride + @intFromBool(remaining % stride != 0));
}
pub fn init(bytes: *[page_bytes]u8, level: u8, base: u64, length: u64) Error!void {
    bytes.* = @splat(0);
    try setHeader(bytes, level, base, length);
}
pub fn setHeader(bytes: *[page_bytes]u8, level: u8, base: u64, length: u64) Error!void {
    std.mem.writeInt(u32, bytes[0..4], magic, .little);
    std.mem.writeInt(u32, bytes[4..8], version, .little);
    std.mem.writeInt(u32, bytes[8..12], level, .little);
    std.mem.writeInt(u32, bytes[12..16], @intCast(try count(level, base, length)), .little);
    std.mem.writeInt(u64, bytes[16..24], base, .little);
    // Bind immutable nodes to their logical coverage, not the mutable whole-
    // file byte length. Full subtrees can then survive a later EOF change.
    std.mem.writeInt(u64, bytes[24..32], @min(capacity(level), pages(length) - base), .little);
}
pub fn setData(bytes: *[page_bytes]u8, index: usize, ref: Data) void {
    const entry = bytes[header_bytes + index * 16 ..][0..16];
    std.mem.writeInt(u64, entry[0..8], ref.page, .little);
    std.mem.writeInt(u32, entry[8..12], ref.checksum, .little);
    std.mem.writeInt(u32, entry[12..16], 0, .little);
}
pub fn data(bytes: *const [page_bytes]u8, index: usize) Data {
    const entry = bytes[header_bytes + index * 16 ..][0..16];
    return .{ .page = std.mem.readInt(u64, entry[0..8], .little), .checksum = std.mem.readInt(u32, entry[8..12], .little) };
}
pub fn setChild(bytes: *[page_bytes]u8, index: usize, ref: Ref) void {
    const entry = bytes[header_bytes + index * 32 ..][0..32];
    std.mem.writeInt(u64, entry[0..8], ref.page, .little);
    std.mem.writeInt(u32, entry[8..12], ref.checksum, .little);
    std.mem.writeInt(u32, entry[12..16], ref.data.low, .little);
    std.mem.writeInt(u32, entry[16..20], ref.data.high, .little);
    std.mem.writeInt(u32, entry[20..24], ref.nodes.low, .little);
    std.mem.writeInt(u32, entry[24..28], ref.nodes.high, .little);
    std.mem.writeInt(u32, entry[28..32], 0, .little);
}
pub fn child(bytes: *const [page_bytes]u8, index: usize) Ref {
    const entry = bytes[header_bytes + index * 32 ..][0..32];
    return .{ .page = std.mem.readInt(u64, entry[0..8], .little), .checksum = std.mem.readInt(u32, entry[8..12], .little), .data = .{ .low = std.mem.readInt(u32, entry[12..16], .little), .high = std.mem.readInt(u32, entry[16..20], .little) }, .nodes = .{ .low = std.mem.readInt(u32, entry[20..24], .little), .high = std.mem.readInt(u32, entry[24..28], .little) } };
}
fn validBounds(bounds: Bounds, limits: Limits) bool {
    return bounds.low >= limits.start and bounds.high > bounds.low and bounds.high <= limits.end;
}
fn summarize(bytes: *const [page_bytes]u8, page: u64, level: u8, base: u64, length: u64, limits: Limits) Error!Ref {
    if (limits.end > std.math.maxInt(u32) or page < limits.start or page >= limits.end) return error.Corrupt;
    const used = try count(level, base, length);
    var result = Ref{ .page = page, .nodes = .{ .low = @intCast(page), .high = @intCast(page + 1) } };
    const entries: usize = if (level == 0) leaf_entries else children;
    const stride: usize = if (level == 0) 16 else 32;
    for (0..entries) |i| {
        const entry = bytes[header_bytes + i * stride ..][0..stride];
        if (i >= used) {
            for (entry) |byte| if (byte != 0) return error.Corrupt;
            continue;
        }
        if (level == 0) {
            const ref = data(bytes, i);
            if (ref.page == 0) {
                for (entry) |byte| if (byte != 0) return error.Corrupt;
                continue;
            }
            if (ref.page < limits.start or ref.page >= limits.end or std.mem.readInt(u32, entry[12..16], .little) != 0) return error.Corrupt;
            result.data.include(.{ .low = @intCast(ref.page), .high = @intCast(ref.page + 1) });
        } else {
            const ref = child(bytes, i);
            if (ref.page == 0) {
                for (entry) |byte| if (byte != 0) return error.Corrupt;
                continue;
            }
            const empty_data = ref.data.low == 0 and ref.data.high == 0;
            if ((!empty_data and !validBounds(ref.data, limits)) or !validBounds(ref.nodes, limits) or ref.page < ref.nodes.low or ref.page >= ref.nodes.high or
                std.mem.readInt(u32, entry[28..32], .little) != 0) return error.Corrupt;
            result.data.include(ref.data);
            result.nodes.include(ref.nodes);
        }
    }
    return result;
}
pub fn seal(bytes: *[page_bytes]u8, page: u64, level: u8, base: u64, length: u64, limits: Limits) Error!Ref {
    var result = try summarize(bytes, page, level, base, length, limits);
    std.mem.writeInt(u32, bytes[32..36], result.data.low, .little);
    std.mem.writeInt(u32, bytes[36..40], result.data.high, .little);
    std.mem.writeInt(u32, bytes[40..44], result.nodes.low, .little);
    std.mem.writeInt(u32, bytes[44..48], result.nodes.high, .little);
    result.checksum = std.hash.Crc32.hash(bytes[0..crc_offset]);
    std.mem.writeInt(u32, bytes[crc_offset..][0..4], result.checksum, .little);
    return result;
}
pub fn validate(bytes: *const [page_bytes]u8, expected: Ref, level: u8, base: u64, length: u64, limits: Limits) Error!Ref {
    if (level > max_height or std.hash.Crc32.hash(bytes[0..crc_offset]) != expected.checksum or
        std.mem.readInt(u32, bytes[crc_offset..][0..4], .little) != expected.checksum or
        std.mem.readInt(u32, bytes[0..4], .little) != magic or std.mem.readInt(u32, bytes[4..8], .little) != version or
        std.mem.readInt(u32, bytes[8..12], .little) != level or std.mem.readInt(u32, bytes[12..16], .little) != try count(level, base, length) or
        std.mem.readInt(u64, bytes[16..24], .little) != base or std.mem.readInt(u64, bytes[24..32], .little) != @min(capacity(level), pages(length) - base)) return error.Corrupt;
    var result = try summarize(bytes, expected.page, level, base, length, limits);
    result.checksum = expected.checksum;
    if (std.mem.readInt(u32, bytes[32..36], .little) != result.data.low or std.mem.readInt(u32, bytes[36..40], .little) != result.data.high or
        std.mem.readInt(u32, bytes[40..44], .little) != result.nodes.low or std.mem.readInt(u32, bytes[44..48], .little) != result.nodes.high) return error.Corrupt;
    if (expected.nodes.low != 0 and (!std.meta.eql(expected.data, result.data) or !std.meta.eql(expected.nodes, result.nodes))) return error.Corrupt;
    return result;
}
