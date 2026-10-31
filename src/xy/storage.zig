//! Copy-only storage client. Providers carry the authenticated principal and
//! wait policy; Scheme supplies neither task identity nor SQLite/store pointers.
const std = @import("std");
pub const code_section = if (@import("builtin").os.tag == .freestanding) ".flash.xytext" else if (@import("builtin").object_format == .macho) "__TEXT,__text" else ".text";
pub const Error = error{ StorageUnavailable, StorageBusy, StorageDenied, StorageStale, StorageFull, StorageNotFound, StorageLimit, StorageOutcomeUnknown, StorageFailed };
pub const Operation = enum(u32) {
    query = 1,
    exec,
    sql_begin,
    sql_commit,
    sql_rollback,
    open,
    read,
    write,
    resize,
    remove,
    sync,
    rollback,
    snapshot,
    restore,
    release,
    collect,
    generation,
    list,
    close,
    stat,
    begin,
    lookup,
    check,
    space,
    verify,
};
pub const Request = struct {
    operation: Operation,
    handle: u32 = 0,
    offset: u32 = 0,
    count: u32 = 0,
    text: []const u8 = "",
    argument: []const u8 = "",
};
pub const Provider = struct {
    context: ?*anyopaque,
    call: *const fn (?*anyopaque, Request, []u8) Error![]const u8,
};
pub const Client = struct {
    provider: ?Provider = null,
    pub inline fn call(self: Client, request: Request, output: []u8) Error![]const u8 {
        const p = self.provider orelse return error.StorageUnavailable;
        return p.call(p.context, request, output);
    }
    pub noinline fn save(self: Client, name: []const u8, data: []const u8) linksection(code_section) Error!void {
        var output: [1024]u8 = undefined;
        _ = try self.call(.{ .operation = .begin }, &output);
        self.saveStaged(name, data, &output) catch |err| {
            _ = self.call(.{ .operation = .rollback }, &output) catch return error.StorageOutcomeUnknown;
            return err;
        };
    }
    fn saveStaged(self: Client, name: []const u8, data: []const u8, output: []u8) linksection(code_section) Error!void {
        const handle = decimalU32(try self.call(.{ .operation = .open, .offset = 1, .text = name }, output)) catch return error.StorageFailed;
        _ = try self.call(.{ .operation = .resize, .handle = handle, .offset = 0 }, output);
        var offset: usize = 0;
        while (offset < data.len) {
            const n = @min(data.len - offset, 256);
            _ = try self.call(.{ .operation = .write, .handle = handle, .offset = @intCast(offset), .text = data[offset..][0..n] }, output);
            offset += n;
        }
        _ = try self.call(.{ .operation = .sync }, output);
        _ = self.call(.{ .operation = .close, .handle = handle }, output) catch return error.StorageOutcomeUnknown;
    }
    pub noinline fn load(self: Client, name: []const u8, destination: []u8) linksection(code_section) Error![]const u8 {
        var output: [1024]u8 = undefined;
        const handle = decimalU32(try self.call(.{ .operation = .open, .text = name }, &output)) catch return error.StorageFailed;
        const result = self.loadOpened(handle, destination, &output) catch |err| {
            _ = self.call(.{ .operation = .close, .handle = handle }, &output) catch return error.StorageFailed;
            return err;
        };
        _ = try self.call(.{ .operation = .close, .handle = handle }, &output);
        return result;
    }
    fn loadOpened(self: Client, handle: u32, destination: []u8, output: []u8) linksection(code_section) Error![]const u8 {
        const size = decimalU32(try self.call(.{ .operation = .stat, .handle = handle }, output)) catch return error.StorageFailed;
        if (size > destination.len) return error.StorageLimit;
        var offset: usize = 0;
        while (offset < size) {
            const n = @min(size - offset, 64);
            const encoded = try self.call(.{ .operation = .read, .handle = handle, .offset = @intCast(offset), .count = @intCast(n) }, output);
            try copyDecimalBytes(encoded, destination[offset..][0..n]);
            offset += n;
        }
        if (!validUtf8(destination[0..size])) return error.StorageFailed;
        return destination[0..size];
    }
};

/// Unsigned decimal only. The service prints canonical digits, and the std
/// formatter would otherwise be emitted into SRAM.
fn decimalU32(text: []const u8) linksection(code_section) error{StorageFailed}!u32 {
    if (text.len == 0 or text.len > 10) return error.StorageFailed;
    var n: u32 = 0;
    for (text) |c| {
        if (c < '0' or c > '9') return error.StorageFailed;
        const digit: u32 = c - '0';
        if (n > (std.math.maxInt(u32) - digit) / 10) return error.StorageFailed;
        n = n * 10 + digit;
    }
    return n;
}

fn copyDecimalBytes(encoded: []const u8, destination: []u8) linksection(code_section) Error!void {
    if (encoded.len < 2 or encoded[0] != '(' or encoded[encoded.len - 1] != ')') return error.StorageFailed;
    var index: usize = 1;
    var copied: usize = 0;
    const end = encoded.len - 1;
    while (index < end) {
        if (encoded[index] == ' ') {
            index += 1;
            continue;
        }
        if (copied == destination.len) return error.StorageFailed;
        var n: u32 = 0;
        var digits: usize = 0;
        while (index < end and encoded[index] != ' ') {
            const c = encoded[index];
            if (c < '0' or c > '9' or digits == 3) return error.StorageFailed;
            n = n * 10 + (c - '0');
            if (n > 255) return error.StorageFailed;
            index += 1;
            digits += 1;
        }
        if (digits == 0) return error.StorageFailed;
        destination[copied] = @intCast(n);
        copied += 1;
    }
    if (copied != destination.len) return error.StorageStale;
}

pub fn validUtf8(bytes: []const u8) linksection(code_section) bool {
    var index: usize = 0;
    while (index < bytes.len) {
        const c = bytes[index];
        const width: usize = if (c < 0x80) 1 else if ((c & 0xE0) == 0xC0) 2 else if ((c & 0xF0) == 0xE0) 3 else if ((c & 0xF8) == 0xF0) 4 else return false;
        if (index + width > bytes.len) return false;
        var k: usize = 1;
        while (k < width) : (k += 1) if ((bytes[index + k] & 0xC0) != 0x80) return false;
        if (width == 1) {
            index += 1;
            continue;
        }
        const cp: u32 = switch (width) {
            2 => (@as(u32, c & 0x1F) << 6) | (bytes[index + 1] & 0x3F),
            3 => (@as(u32, c & 0x0F) << 12) | (@as(u32, bytes[index + 1] & 0x3F) << 6) | (bytes[index + 2] & 0x3F),
            else => (@as(u32, c & 0x07) << 18) | (@as(u32, bytes[index + 1] & 0x3F) << 12) | (@as(u32, bytes[index + 2] & 0x3F) << 6) | (bytes[index + 3] & 0x3F),
        };
        const min: u32 = switch (width) {
            2 => 0x80,
            3 => 0x800,
            else => 0x10000,
        };
        if (cp < min or cp > 0x10FFFF or (cp >= 0xD800 and cp <= 0xDFFF)) return false;
        index += width;
    }
    return true;
}

test "decimal storage replies round-trip without the std formatter" {
    const Fixed = struct {
        fn call(_: ?*anyopaque, request: Request, output: []u8) Error![]const u8 {
            switch (request.operation) {
                .open => return std.fmt.bufPrint(output, "7", .{}) catch return error.StorageFailed,
                .stat => return std.fmt.bufPrint(output, "5", .{}) catch return error.StorageFailed,
                .read => return std.fmt.bufPrint(output, "(104 101 108 108 111)", .{}) catch return error.StorageFailed,
                .close => return output[0..0],
                else => return error.StorageFailed,
            }
        }
    };
    const client = Client{ .provider = .{ .context = null, .call = Fixed.call } };
    var destination: [8]u8 = undefined;
    try std.testing.expectEqualStrings("hello", try client.load("note", &destination));
    try std.testing.expectError(error.StorageFailed, decimalU32("+7"));
    try std.testing.expectError(error.StorageFailed, decimalU32("4294967296"));
    try std.testing.expect(!validUtf8(&.{ 0xC0, 0x80 }));
}
