//! Zig representation of the stable C platform ABI.
//!
//! Keep this file in lockstep with `include/nihos/platform_abi.h`. All fields
//! have fixed widths so that host tests and the 32-bit ESP32-P4 agree on layout.

const std = @import("std");

pub const version: u32 = 2;

pub const Status = struct {
    pub const ok: i32 = 0;
    pub const invalid_argument: i32 = -1;
    pub const unsupported: i32 = -2;
    pub const busy: i32 = -3;
    pub const io: i32 = -4;
    pub const no_memory: i32 = -5;
};

pub const BootInfo = extern struct {
    abi_version: u32,
    chip_revision: u32,
    cpu_count: u32,
    internal_heap_bytes: u32,
    psram_heap_bytes: u32,
    flash_bytes: u32,
};

pub const DmaRange = extern struct {
    address: u32,
    length: u32,
    direction: u32,
    flags: u32,
};

pub const DmaDirection = struct {
    pub const to_device: u32 = 1;
    pub const from_device: u32 = 2;
    pub const bidirectional: u32 = 3;
};

pub const MemoryKind = struct {
    pub const internal: u32 = 1;
    pub const psram: u32 = 2;
};

pub const MemoryFlags = struct {
    pub const writable: u32 = 1 << 0;
    pub const cacheable: u32 = 1 << 1;
    pub const dma_data: u32 = 1 << 2;
};

pub const MemoryRegion = extern struct {
    kind: u32,
    flags: u32,
    address: u32,
    length: u32,
    cache_line_bytes: u32,
};

pub const DmaCopy = extern struct {
    source_address: u32,
    destination_address: u32,
    length: u32,
    flags: u32,
    elapsed_us: u32,
};

pub const DisplayPixelFormat = struct {
    pub const rgb565_le: u32 = 1;
};

pub const DisplayFrameFlags = struct {
    pub const writable: u32 = 1 << 0;
    pub const cacheable: u32 = 1 << 1;
    pub const scanout: u32 = 1 << 2;
};

pub const DisplayInfo = extern struct {
    width: u32,
    height: u32,
    stride_bytes: u32,
    pixel_format: u32,
    framebuffer_address: u32,
    framebuffer_bytes: u32,
    framebuffer_flags: u32,
};

pub const DisplayPresent = extern struct {
    framebuffer_address: u32,
    framebuffer_bytes: u32,
    flags: u32,
    elapsed_us: u32,
    vsync_count: u32,
};

pub const DisplayVsync = extern struct {
    timeout_ms: u32,
    flags: u32,
    elapsed_us: u32,
    vsync_count: u32,
};

test "platform ABI has fixed layout" {
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(BootInfo));
    try std.testing.expectEqual(@as(usize, 4), @alignOf(BootInfo));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(DmaRange));
    try std.testing.expectEqual(@as(usize, 4), @alignOf(DmaRange));
    try std.testing.expectEqual(@as(usize, 20), @sizeOf(MemoryRegion));
    try std.testing.expectEqual(@as(usize, 4), @alignOf(MemoryRegion));
    try std.testing.expectEqual(@as(usize, 20), @sizeOf(DmaCopy));
    try std.testing.expectEqual(@as(usize, 4), @alignOf(DmaCopy));
    try std.testing.expectEqual(@as(usize, 28), @sizeOf(DisplayInfo));
    try std.testing.expectEqual(@as(usize, 4), @alignOf(DisplayInfo));
    try std.testing.expectEqual(@as(usize, 20), @sizeOf(DisplayPresent));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(DisplayVsync));
}
