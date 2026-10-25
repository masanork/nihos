//! Zig representation of the stable C platform ABI.
//!
//! Keep this file in lockstep with `include/nihos/platform_abi.h`. All fields
//! have fixed widths so that host tests and the 32-bit ESP32-P4 agree on layout.

const std = @import("std");

pub const version: u32 = 1;

pub const Status = struct {
    pub const ok: i32 = 0;
    pub const invalid_argument: i32 = -1;
    pub const unsupported: i32 = -2;
    pub const busy: i32 = -3;
    pub const io: i32 = -4;
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

test "platform ABI has fixed layout" {
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(BootInfo));
    try std.testing.expectEqual(@as(usize, 4), @alignOf(BootInfo));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(DmaRange));
    try std.testing.expectEqual(@as(usize, 4), @alignOf(DmaRange));
}
