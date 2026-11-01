//! Trusted foreground client for the normal sqld task. All transport data is copied.
pub const storage = @import("text_console").scratch.scheme.storage;
const wire = @import("sqld_wire.zig");
pub const Request = wire.Request;
pub const Response = wire.Response;
pub const Report = wire.Report;
extern fn nih_sqld_native_submit(*Request) callconv(.c) i32;
extern fn nih_sqld_native_take(*Response) callconv(.c) i32;
extern fn nih_sqld_front_pump() callconv(.c) void;
pub extern fn nih_sqld_native_prepare(u32, u32) callconv(.c) void;
pub extern fn nih_sqld_native_status() callconv(.c) i32;
pub extern fn nih_sqld_native_poll() callconv(.c) void;
extern fn nih_sqld_native_report(*Report) callconv(.c) void;
pub fn report() Report {
    var out = Report{};
    nih_sqld_native_report(&out);
    return out;
}
fn failure(code: i32) storage.Error {
    return switch (code) {
        -16 => error.StorageBusy,
        -13 => error.StorageDenied,
        -9 => error.StorageStale,
        -28 => error.StorageFull,
        -2 => error.StorageNotFound,
        -7, -22 => error.StorageLimit,
        -115 => error.StorageOutcomeUnknown,
        -19 => error.StorageUnavailable,
        else => error.StorageFailed,
    };
}
fn call(_: ?*anyopaque, request: storage.Request, output: []u8) linksection(".flash.xytext") storage.Error![]const u8 {
    if (request.text.len >= 512 or request.argument.len >= 64) return error.StorageLimit;
    const q: *Request = @ptrFromInt(0x48204000);
    q.* = .{ .operation = @backingInt(request.operation), .handle = request.handle, .offset = request.offset, .count = request.count, .length = @intCast(request.text.len) };
    @memcpy(q.text[0..request.text.len], request.text);
    @memcpy(q.argument[0..request.argument.len], request.argument);
    const submitted = nih_sqld_native_submit(q);
    if (submitted != 0) return failure(submitted);
    const r: *Response = @ptrFromInt(0x48205000);
    r.* = .{};
    while (true) {
        const taken = nih_sqld_native_take(r);
        if (taken < 0) return failure(taken);
        if (taken == 1) break;
        if (nih_sqld_native_status() != 2) return error.StorageOutcomeUnknown;
        // Keep display/network and deferred input alive while the owner parks
        // for storage. No second Scheme evaluation or document mutation occurs.
        nih_sqld_front_pump();
    }
    if (r.epoch != q.epoch or r.sequence != q.sequence) return error.StorageStale;
    if (r.status != 0) return if (r.outcome == 2) error.StorageOutcomeUnknown else failure(r.status);
    if (r.length > r.text.len or r.length > output.len) return error.StorageLimit;
    @memcpy(output[0..r.length], r.text[0..r.length]);
    return output[0..r.length];
}
pub const provider linksection(".flash.xyrodata") = storage.Provider{ .context = null, .call = call };
comptime {
    if (@sizeOf(Request) != 604 or @sizeOf(Response) != 1048) @compileError("sqld C ABI layout changed");
}
