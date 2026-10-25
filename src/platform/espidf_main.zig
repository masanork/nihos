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
extern fn nih_platform_dma_copy(copy: *abi.DmaCopy) i32;

fn write(bytes: []const u8) void {
    if (bytes.len == 0) return;
    _ = nih_platform_console_write(bytes.ptr, @intCast(bytes.len));
}

fn writeU64(label: []const u8, value: u64) void {
    var digits: [20]u8 = undefined;
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

fn writeU32(label: []const u8, value: u32) void {
    writeU64(label, value);
}

fn syncRange(bytes: []u8, direction: u32) bool {
    const range = abi.DmaRange{
        .address = @intCast(@intFromPtr(bytes.ptr)),
        .length = @intCast(bytes.len),
        .direction = direction,
        .flags = 0,
    };
    return nih_platform_cache_sync(&range) == abi.Status.ok;
}

fn fillPattern(bytes: []u8, seed: u8) void {
    var value = seed;
    for (bytes) |*byte| {
        byte.* = value;
        value +%= 17;
    }
}

fn runDmaPath(label: []const u8, source: []u8, destination: []u8) bool {
    const rounds: u32 = 8;
    var elapsed_us: u64 = 0;

    for (0..rounds) |round| {
        fillPattern(source, @intCast(round + 1));
        @memset(destination, 0);
        if (!syncRange(source, abi.DmaDirection.to_device)) return false;
        if (!syncRange(destination, abi.DmaDirection.bidirectional)) return false;

        var copy = abi.DmaCopy{
            .source_address = @intCast(@intFromPtr(source.ptr)),
            .destination_address = @intCast(@intFromPtr(destination.ptr)),
            .length = @intCast(source.len),
            .flags = 0,
            .elapsed_us = 0,
        };
        if (nih_platform_dma_copy(&copy) != abi.Status.ok) return false;
        elapsed_us += copy.elapsed_us;
        if (!syncRange(destination, abi.DmaDirection.from_device)) return false;
        if (!std.mem.eql(u8, source, destination)) return false;
    }

    write(label);
    writeU64("", elapsed_us);
    return true;
}

fn exerciseDma() bool {
    var internal_region: abi.MemoryRegion = undefined;
    var psram_region: abi.MemoryRegion = undefined;
    if (nih_platform_memory_region(abi.MemoryKind.internal, &internal_region) !=
        abi.Status.ok or
        nih_platform_memory_region(abi.MemoryKind.psram, &psram_region) !=
            abi.Status.ok)
    {
        return false;
    }
    if ((internal_region.flags & abi.MemoryFlags.dma_data) == 0 or
        (psram_region.flags & abi.MemoryFlags.dma_data) == 0)
    {
        return false;
    }

    // SAFETY: The platform keeps both transferred regions exclusively owned
    // by the Zig boot arenas for the lifetime of the firmware.
    const internal_base: [*]u8 = @ptrFromInt(internal_region.address);
    const psram_base: [*]u8 = @ptrFromInt(psram_region.address);
    var internal_arena = arena_module.Arena.init(
        internal_base[0..@intCast(internal_region.length)],
    );
    var psram_arena = arena_module.Arena.init(
        psram_base[0..@intCast(psram_region.length)],
    );

    const transfer_bytes: usize = 16 * 1024;
    const internal_source = internal_arena.alloc(transfer_bytes, 128) orelse
        return false;
    const internal_destination = internal_arena.alloc(transfer_bytes, 128) orelse
        return false;
    const psram_source = psram_arena.alloc(transfer_bytes, 128) orelse
        return false;
    const psram_destination = psram_arena.alloc(transfer_bytes, 128) orelse
        return false;

    writeU32("dma_bytes_per_path=", @intCast(transfer_bytes * 8));
    if (!runDmaPath("dma_internal_to_internal_us=", internal_source, internal_destination))
        return false;
    if (!runDmaPath("dma_internal_to_psram_us=", internal_source, psram_destination))
        return false;
    if (!runDmaPath("dma_psram_to_internal_us=", psram_source, internal_destination))
        return false;
    if (!runDmaPath("dma_psram_to_psram_us=", psram_source, psram_destination))
        return false;
    return true;
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

    if (!exerciseDma()) {
        write("nihos: AXI-GDMA copy failed\r\n");
        return;
    }
    write("axi_gdma_copy=ok\r\n");
    write("nihos: bootstrap complete\r\n");
}
