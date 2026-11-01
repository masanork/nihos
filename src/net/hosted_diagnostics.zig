//! Optional nihos C6 diagnostics in the Hosted 1.4.1 version response.
const wire = @import("hosted.zig");
pub const Diagnostics = struct { uptime_seconds: u32, free_heap_bytes: u32 };

/// Returns null for unmodified firmware. Zero is a valid diagnostic value, so
/// field presence is checked explicitly. The response must first be matched
/// to the outstanding GetCoprocessorFwVersion request by the caller.
pub fn parse(body: []const u8) wire.Error!?Diagnostics {
    var reader = wire.Reader{ .bytes = body };
    var schema: ?u32 = null;
    var uptime: ?u32 = null;
    var heap: ?u32 = null;
    while (try reader.next()) |field| {
        const dest = switch (field.number) {
            100 => &schema,
            101 => &uptime,
            102 => &heap,
            else => continue,
        };
        if (dest.* != null or field.kind != 0 or field.value > 0xffffffff) return error.Malformed;
        dest.* = @intCast(field.value);
    }
    if (schema == null and uptime == null and heap == null) return null;
    if (schema == null or schema.? != 1 or uptime == null or heap == null) return error.Malformed;
    return .{ .uptime_seconds = uptime.?, .free_heap_bytes = heap.? };
}
