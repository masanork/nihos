//! P4-only mapped-image read probe. Never touches the C6 or starts OTA.
const std = @import("std");
pub const panic = std.debug.no_panic;
extern fn nih_rom_putc(u8) callconv(.c) i32;
extern fn nih_rom_set_cpu1_entry(u32) callconv(.c) void;
extern fn nih_rom_l2_line_size(u32) callconv(.c) u32;
extern fn nih_rom_l2_enable(u32) callconv(.c) void;
extern fn nih_rom_cache_invalidate(u32, u32, u32) callconv(.c) i32;
extern fn nih_rom_cache_writeback(u32, u32, u32) callconv(.c) i32;
extern const nih_c6_candidate_start: u8;
extern const nih_c6_candidate_end: u8;
fn print(bytes: []const u8) void {
    for (bytes) |b| _ = nih_rom_putc(b);
}
fn hex(value: u32) void {
    const digits = "0123456789abcdef";
    for (0..8) |i| _ = nih_rom_putc(digits[(value >> @as(u5, @intCast(28 - i * 4))) & 15]);
}
fn halt() noreturn {
    while (true) asm volatile ("wfi");
}
export fn nih_c6_exception(cause: u32, pc: u32, value: u32) callconv(.c) noreturn {
    print("NIHOS_C6_MAP_TRAP cause=");
    hex(cause);
    print(" pc=");
    hex(pc);
    print(" value=");
    hex(value);
    print("\r\n");
    halt();
}
export fn nih_c6_main() callconv(.c) noreturn {
    nih_rom_set_cpu1_entry(0);
    print("NIHOS_C6_MAP_BOOT\r\nNIHOS_C6_ROM");
    inline for (.{ &nih_rom_putc, &nih_rom_set_cpu1_entry, &nih_rom_l2_line_size, &nih_rom_l2_enable, &nih_rom_cache_invalidate, &nih_rom_cache_writeback }) |f| {
        print(" ");
        hex(@intFromPtr(f));
    }
    print("\r\n");
    const start = @intFromPtr(&nih_c6_candidate_start);
    const end = @intFromPtr(&nih_c6_candidate_end);
    if (start != 0x40010024 or end <= start or end - start > 1536 * 1024) {
        print("NIHOS_C6_MAP_INVALID\r\n");
        halt();
    }
    const bytes: [*]const u8 = @ptrFromInt(start);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes[0 .. end - start], &digest, .{});
    print("NIHOS_C6_MAP_RESULT bytes=");
    hex(@intCast(end - start));
    print(" sha256=");
    for (0..8) |i| hex(std.mem.readInt(u32, digest[i * 4 ..][0..4], .big));
    print("\r\n");
    halt();
}
