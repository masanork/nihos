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
        const handle = std.fmt.parseInt(u32, try self.call(.{ .operation = .open, .offset = 1, .text = name }, output), 10) catch return error.StorageFailed;
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
        const handle = std.fmt.parseInt(u32, try self.call(.{ .operation = .open, .text = name }, &output), 10) catch return error.StorageFailed;
        const result = self.loadOpened(handle, destination, &output) catch |err| {
            _ = self.call(.{ .operation = .close, .handle = handle }, &output) catch return error.StorageFailed;
            return err;
        };
        _ = try self.call(.{ .operation = .close, .handle = handle }, &output);
        return result;
    }
    fn loadOpened(self: Client, handle: u32, destination: []u8, output: []u8) linksection(code_section) Error![]const u8 {
        const size = std.fmt.parseInt(u32, try self.call(.{ .operation = .stat, .handle = handle }, output), 10) catch return error.StorageFailed;
        if (size > destination.len) return error.StorageLimit;
        var offset: usize = 0;
        while (offset < size) {
            const n = @min(size - offset, 64);
            const encoded = try self.call(.{ .operation = .read, .handle = handle, .offset = @intCast(offset), .count = @intCast(n) }, output);
            if (encoded.len < 2 or encoded[0] != '(' or encoded[encoded.len - 1] != ')') return error.StorageFailed;
            var words = std.mem.tokenizeScalar(u8, encoded[1 .. encoded.len - 1], ' ');
            var copied: usize = 0;
            while (words.next()) |word| {
                if (copied == n) return error.StorageFailed;
                destination[offset + copied] = std.fmt.parseInt(u8, word, 10) catch return error.StorageFailed;
                copied += 1;
            }
            if (copied != n) return error.StorageStale;
            offset += n;
        }
        if (!std.unicode.utf8ValidateSlice(destination[0..size])) return error.StorageFailed;
        return destination[0..size];
    }
};
