//! Explicit one-shot 1.4.1 -> experimental 2.13.1 time candidate fixture.
pub const C6OtaAllow213 = true;
pub const C6OtaRequiredPeer = [3]u32{ 1, 4, 1 };
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
    const expected = [_]u8{ 0x7f, 0x03, 0x6e, 0x61, 0x6d, 0xf4, 0xd4, 0x78, 0x20, 0x15, 0xca, 0xf3, 0x0f, 0x18, 0x5f, 0x78, 0x59, 0xaf, 0x11, 0x54, 0x38, 0xf3, 0x94, 0x46, 0x36, 0x00, 0xd0, 0xf8, 0xd6, 0x99, 0x95, 0xbe };
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
        if (post.status == 1 and post.peer_chip == 13 and post.version_known == 1 and
            post.major == 2 and post.minor == 13 and post.patch == 1)
        {
            print("NIHOS_C6_OTA_TARGET_VERSION_OK\r\n");
        } else {
            print("NIHOS_C6_OTA_TARGET_VERSION_FAIL\r\n");
        }
    }
    halt();
}
