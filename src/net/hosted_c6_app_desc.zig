//! Hosted AppGetDesc reports application metadata, not flash identity.
const wire = @import("hosted.zig");
pub const request_id: u32 = 267;
pub const response_id: u32 = 523;
pub const Text = struct {
    bytes: [32]u8 = @splat(0),
    len: u8 = 0,
    pub fn slice(self: *const Text) []const u8 {
        return self.bytes[0..self.len];
    }
};
pub const Description = struct {
    version: Text,
    project: Text,
    idf: Text,
    elf_sha256: ?[32]u8 = null,
};
fn text(bytes: []const u8) wire.Error!Text {
    if (bytes.len == 0 or bytes.len > 32) return error.Malformed;
    const clean = if (bytes[bytes.len - 1] == 0) bytes[0 .. bytes.len - 1] else bytes;
    if (clean.len == 0) return error.Malformed;
    for (clean) |b| if (b < 32 or b > 126) return error.Malformed;
    var out: Text = .{};
    @memcpy(out.bytes[0..clean.len], clean);
    out.len = @intCast(clean.len);
    return out;
}
pub fn parse(rpc: wire.Rpc, uid: u32) wire.Error!Description {
    if (uid == 0 or rpc.kind != 2 or rpc.id != response_id or rpc.uid != uid) return error.Stale;
    if (try wire.integer(rpc.body, 1) != 0) return error.Rejected;
    const desc = (try wire.data(rpc.body, 2)) orelse return error.Malformed;
    const version = (try wire.data(desc, 4)) orelse return error.Malformed;
    const project = (try wire.data(desc, 5)) orelse return error.Malformed;
    const idf = (try wire.data(desc, 8)) orelse return error.Malformed;
    const elf = try wire.data(desc, 9);
    if (elf != null and elf.?.len != 32) return error.Malformed;
    var out: Description = .{ .version = try text(version), .project = try text(project), .idf = try text(idf) };
    if (elf) |digest| {
        var value: [32]u8 = undefined;
        @memcpy(&value, digest);
        out.elf_sha256 = value;
    }
    return out;
}
