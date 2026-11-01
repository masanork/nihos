//! P4 Hosted 3 candidate simulation; physical C6 transport blocks OTA commands.
pub const C6OtaSimulation = true;
pub const C6OtaAllow213 = true;
pub const C6OtaRequiredPeer = [3]u32{ 2, 13, 1 };
const std = @import("std");
const c6 = @import("c6_probe");
const timers = @import("timer_group");
pub const panic = std.debug.no_panic;
extern fn nih_rom_putc(u8) callconv(.c) i32;
extern fn nih_rom_set_cpu1_entry(u32) callconv(.c) void;
extern fn nih_rom_l2_line_size(u32) callconv(.c) u32;
extern fn nih_rom_l2_enable(u32) callconv(.c) void;
extern fn nih_rom_cache_invalidate(u32, u32, u32) callconv(.c) i32;
extern fn nih_rom_cache_writeback(u32, u32, u32) callconv(.c) i32;
extern const nih_c6_candidate_start: u8;
extern const nih_c6_candidate_end: u8;
fn reg(address: usize) *volatile u32 {
    return @ptrFromInt(address);
}
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
    const expected = [_]u8{ 0x04, 0xbd, 0x14, 0xfa, 0xf9, 0x43, 0x45, 0x3c, 0xcf, 0x39, 0x07, 0x5b, 0xc6, 0x14, 0x56, 0x46, 0x3b, 0x3f, 0x36, 0x26, 0x43, 0xa3, 0xa6, 0x3d, 0xab, 0x0f, 0x82, 0xa5, 0x3f, 0x4d, 0xc8, 0xfe };
    if (!std.mem.eql(u8, &digest, &expected)) {
        print("NIHOS_C6_PREFLIGHT_HASH_FAIL\r\n");
        halt();
    }
    reg(0x50116018).* = 0x50d83aa1;
    reg(0x50116000).* &= ~@as(u32, 1 << 31);
    reg(0x500e601c).* |= 1 << 21;
    reg(0x500e60c4).* |= 1 << 6;
    reg(0x500e60c4).* &= ~@as(u32, 1 << 6);
    reg(0x500c2064).* = 0x50d83aa1;
    reg(0x500c2048).* = 0;
    reg(0x500c2064).* = 0;
    reg(0x500e6094).* = (reg(0x500e6094).* & ~@as(u32, 3 << 22)) | (1 << 24);
    const clock = timers.Timer.fromGroup(0x500c2000, 0).?;
    clock.channel.config = 40 << 13;
    if (!clock.configureOneShot(1_000_000)) {
        print("NIHOS_C6_PREFLIGHT_TIMER_FAIL\r\n");
        halt();
    }
    clock.start();
    const update = c6.runOtaUpdate(clock, bytes[0 .. end - start], expected);
    print("NIHOS_C6_OTA_RESULT");
    inline for (comptime std.meta.fieldNames(c6.OtaUpdate)) |field| {
        print(" " ++ field ++ "=");
        hex(@field(update, field));
    }
    print("\r\n");
    if (update.status == 1) {
        const post = c6.runOtaPreflight(clock, bytes[0 .. end - start], expected);
        print("NIHOS_C6_OTA_POST");
        inline for (comptime std.meta.fieldNames(c6.OtaPreflight)) |field| {
            print(" " ++ field ++ "=");
            hex(@field(post, field));
        }
        print("\r\n");
    }
    halt();
}
