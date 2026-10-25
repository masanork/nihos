//! First target-side Zig entry point.
//!
//! ESP-IDF calls `app_main` in the C shim. The shim collects vendor-owned boot
//! facts and then crosses the stable ABI exactly once into this file.

const std = @import("std");
const abi = @import("abi.zig");

pub const panic = std.debug.no_panic;

extern fn nih_platform_console_write(data: [*]const u8, length: u32) i32;

fn write(bytes: []const u8) void {
    if (bytes.len == 0) return;
    _ = nih_platform_console_write(bytes.ptr, @intCast(bytes.len));
}

fn writeU32(label: []const u8, value: u32) void {
    var digits: [10]u8 = undefined;
    var remaining = value;
    var start = digits.len;

    if (remaining == 0) {
        start -= 1;
        digits[start] = '0';
    } else {
        while (remaining != 0) {
            start -= 1;
            digits[start] = @intCast('0' + remaining % 10);
            remaining /= 10;
        }
    }

    write(label);
    write(digits[start..]);
    write("\r\n");
}

export fn nihos_zig_main(info: *const abi.BootInfo) void {
    write("\r\nnihos: Zig kernel entry\r\n");
    if (info.abi_version != abi.version) {
        write("nihos: platform ABI mismatch\r\n");
        return;
    }

    writeU32("abi=", info.abi_version);
    writeU32("chip_revision=", info.chip_revision);
    writeU32("cpu_count=", info.cpu_count);
    writeU32("internal_heap_bytes=", info.internal_heap_bytes);
    writeU32("psram_heap_bytes=", info.psram_heap_bytes);
    writeU32("flash_bytes=", info.flash_bytes);
    write("nihos: bootstrap complete\r\n");
}
