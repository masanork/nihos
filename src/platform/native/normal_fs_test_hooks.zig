//! Host probe boundary only. Freestanding products cannot enter these hooks.
pub const enabled = @import("builtin").os.tag != .freestanding;
pub extern fn nih_fs_test_now() callconv(.c) u64;
pub extern fn nih_fs_test_read(u32) callconv(.c) u32;
pub extern fn nih_fs_test_write(u32, u32) callconv(.c) void;
pub extern fn nih_fs_test_mask() callconv(.c) u32;
pub extern fn nih_fs_test_restore(u32) callconv(.c) void;
pub extern fn nih_fs_test_quarantine() callconv(.c) noreturn;

pub extern fn nih_fs_test_pointer(u32) callconv(.c) usize;
pub extern fn nih_fs_test_address(usize) callconv(.c) u32;
