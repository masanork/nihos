//! First target-side Zig entry point.
//!
//! ESP-IDF calls `app_main` in the C shim. The shim collects vendor-owned boot
//! facts and then crosses the stable ABI exactly once into this file.

const std = @import("std");
const abi = @import("abi");
const arena_module = @import("arena");

pub const panic = std.debug.no_panic;

extern fn nih_platform_console_write(data: [*]const u8, length: u32) i32;
extern fn nih_platform_memory_region(kind: u32, out: *abi.MemoryRegion) i32;
extern fn nih_platform_cache_sync(range: *const abi.DmaRange) i32;

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

fn exerciseMemory(kind: u32) bool {
    var region: abi.MemoryRegion = undefined;
    if (nih_platform_memory_region(kind, &region) != abi.Status.ok) return false;
    if (region.kind != kind or region.length == 0 or
        region.cache_line_bytes == 0 or
        (region.flags & abi.MemoryFlags.writable) == 0)
    {
        return false;
    }

    // SAFETY: The platform transfers exclusive ownership of this writable
    // region to the Zig boot arena for the lifetime of the firmware.
    const base: [*]u8 = @ptrFromInt(region.address);
    var arena = arena_module.Arena.init(base[0..@intCast(region.length)]);
    const small = arena.alloc(37, 8) orelse return false;
    const cache_line: usize = @intCast(region.cache_line_bytes);
    const aligned = arena.alloc(cache_line, cache_line) orelse return false;
    if (@intFromPtr(aligned.ptr) % cache_line != 0) return false;

    @memset(small, 0x3c);
    @memset(aligned, 0xa5);

    if (kind == abi.MemoryKind.psram) {
        if ((region.flags & abi.MemoryFlags.cacheable) == 0) return false;
        var range = abi.DmaRange{
            .address = @intCast(@intFromPtr(aligned.ptr)),
            .length = @intCast(aligned.len),
            .direction = abi.DmaDirection.to_device,
            .flags = 0,
        };
        if (nih_platform_cache_sync(&range) != abi.Status.ok) return false;
        range.direction = abi.DmaDirection.from_device;
        if (nih_platform_cache_sync(&range) != abi.Status.ok) return false;
        for (aligned) |byte| {
            if (byte != 0xa5) return false;
        }
    }

    writeU32(if (kind == abi.MemoryKind.internal)
        "internal_arena_bytes="
    else
        "psram_arena_bytes=", region.length);
    return true;
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

    if (!exerciseMemory(abi.MemoryKind.internal)) {
        write("nihos: internal arena failed\r\n");
        return;
    }
    write("internal_allocator=ok\r\n");

    if (!exerciseMemory(abi.MemoryKind.psram)) {
        write("nihos: PSRAM arena or cache sync failed\r\n");
        return;
    }
    write("psram_allocator=ok\r\n");
    write("psram_cache_sync=ok\r\n");
    write("nihos: bootstrap complete\r\n");
}
