//! C boundary shared by the native owner and host qualification backend.
//! Backend methods authenticate the current task before touching pool memory.
pub fn Adapter(comptime Backend: type) type {
    return struct {
        pub fn open(count: usize) callconv(.c) c_int {
            Backend.open(count) catch return -1;
            return 0;
        }

        pub fn openProfile(profile: u32) callconv(.c) c_int {
            if (profile != 1) return -1;
            Backend.openConfigured(@import("size_pool.zig").sqlite_probe) catch return -1;
            return 0;
        }

        pub fn close() callconv(.c) c_int {
            Backend.close() catch return -1;
            return 0;
        }

        pub fn malloc(length: usize) callconv(.c) ?*anyopaque {
            if (length == 0) return null;
            const rounded = roundup(length);
            if (rounded == 0) return null;
            const object = Backend.resize(null, rounded) catch return null;
            return if (object) |live| @ptrCast(live.cell.bytes.ptr) else null;
        }

        pub fn free(pointer: ?*anyopaque) callconv(.c) c_int {
            const address = @intFromPtr(pointer orelse return 0);
            Backend.release(address) catch return -1;
            return 0;
        }

        pub fn capacity(pointer: ?*anyopaque) callconv(.c) usize {
            return Backend.capacity(@intFromPtr(pointer orelse return 0)) catch 0;
        }

        pub fn realloc(pointer: ?*anyopaque, length: usize) callconv(.c) ?*anyopaque {
            var size = length;
            if (length != 0) {
                size = roundup(length);
                if (size == 0) return null;
                if (pointer) |p| {
                    const previous = Backend.capacity(@intFromPtr(p)) catch return null;
                    if (previous > size) size = previous;
                }
            }
            const object = Backend.resize(if (pointer) |p| @intFromPtr(p) else null, size) catch return null;
            return if (object) |live| @ptrCast(live.cell.bytes.ptr) else null;
        }

        pub fn roundup(length: usize) callconv(.c) usize {
            const pool = @import("size_pool.zig");
            const index = pool.classFor(length) orelse return 0;
            return pool.classes[index];
        }

        pub fn exportSymbols() void {
            @export(&open, .{ .name = "nih_task_allocator_open" });
            @export(&openProfile, .{ .name = "nih_task_allocator_open_profile" });
            @export(&close, .{ .name = "nih_task_allocator_close" });
            @export(&malloc, .{ .name = "nih_task_malloc" });
            @export(&free, .{ .name = "nih_task_free" });
            @export(&capacity, .{ .name = "nih_task_capacity" });
            @export(&realloc, .{ .name = "nih_task_realloc" });
            @export(&roundup, .{ .name = "nih_task_roundup" });
        }
    };
}
