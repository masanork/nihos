//! CPU0-only SRAM fixture. No scheduler, IDF application runtime or heap use.
const std = @import("std");
const c6 = @import("c6_probe");
const timers = @import("timer_group");
const config = @import("wifi_config");
pub const SplitUdpConfig = config;
pub const panic = std.debug.no_panic;
const long_dma_enabled = @hasDecl(config, "long_dma") and config.long_dma;
pub const C6LongDmaEnabled = long_dma_enabled;
pub fn C6Bus(comptime Short: type) type {
    return if (long_dma_enabled) @import("long_dma").C6Bus(Short) else Short;
}
extern fn nih_rom_putc(u8) callconv(.c) i32;
extern fn nih_rom_set_cpu1_entry(u32) callconv(.c) void;
extern fn nih_rom_l2_line_size(u32) callconv(.c) u32;
extern fn nih_rom_l2_enable(u32) callconv(.c) void;
extern fn nih_rom_cache_invalidate(u32, u32, u32) callconv(.c) i32;
extern fn nih_rom_cache_writeback(u32, u32, u32) callconv(.c) i32;
fn reg(address: usize) *volatile u32 {
    return @ptrFromInt(address);
}
fn print(bytes: []const u8) void {
    for (bytes) |byte| {
        if (byte == '\n') _ = nih_rom_putc('\r');
        _ = nih_rom_putc(byte);
    }
}
fn hex(value: u32) void {
    const digits = "0123456789abcdef";
    for (0..8) |i| _ = nih_rom_putc(digits[(value >> @as(u5, @intCast(28 - i * 4))) & 15]);
}
fn printAddress(value: u32) void {
    var buffer: [16]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "{d}.{d}.{d}.{d}", .{
        value >> 24, (value >> 16) & 255, (value >> 8) & 255, value & 255,
    }) catch @panic("IPv4 formatting overflow");
    print(text);
}
fn print6(words: [4]u32) void {
    const digits = "0123456789abcdef";
    for (words, 0..) |word, i| {
        if (i != 0) print(":");
        for (0..8) |j| {
            if (j == 4) print(":");
            _ = nih_rom_putc(digits[(word >> @as(u5, @intCast(28 - j * 4))) & 15]);
        }
    }
}
fn halt() noreturn {
    while (true) asm volatile ("wfi");
}

export fn nih_c6_exception(cause: u32, pc: u32, value: u32) callconv(.c) noreturn {
    print("NIHOS_C6_TRAP cause=");
    hex(cause);
    print(" pc=");
    hex(pc);
    print(" value=");
    hex(value);
    print("\n");
    halt();
}

export fn nih_c6_main() callconv(.c) noreturn {
    reg(0x50116018).* = 0x50d83aa1;
    reg(0x50116000).* &= ~@as(u32, 1 << 31);
    nih_rom_set_cpu1_entry(0);
    print("\nNIHOS_C6_BOOT backend=zig-sram rtos=none cpu1=parked\n");
    if (long_dma_enabled) {
        print("NIHOS_C6_LONG_DMA build=diagnostic data=");
        hex(@intFromPtr(&@import("long_dma").buffer.data));
        print(" descriptor=");
        hex(@intFromPtr(&@import("long_dma").buffer.descriptor));
        print("\n");
    }
    // Print the complete pinned ROM ABI address set audited by the shared ELF
    // checker. These addresses are metadata, not claims that all were called.
    print("NIHOS_C6_ROM");
    inline for (.{ &nih_rom_putc, &nih_rom_set_cpu1_entry, &nih_rom_l2_line_size, &nih_rom_l2_enable, &nih_rom_cache_invalidate, &nih_rom_cache_writeback }) |function| {
        print(" ");
        hex(@intFromPtr(function));
    }
    print("\n");
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
        print("NIHOS_C6_FAIL timer\n");
        halt();
    }
    clock.start();
    const join: ?c6.WifiJoin = if (!config.enabled) null else if (config.saved) .saved else .{ .network = .{ .ssid = &config.ssid, .password = &config.password } };
    const hosted_join: c6.HostedJoin = if (config.enabled and !config.saved)
        .{ .network = .{ .ssid = &config.ssid, .password = &config.password } }
    else
        .saved;
    const report = if (config.hosted and config.udp_enabled and long_dma_enabled) c6.runHostedSplitUdp(clock, hosted_join) else c6.run(clock, join);

    print("NIHOS_NATIVE_C6");
    inline for (.{ "status", "stage", "error_code", "power_failure", "peer_chip", "fw_known", "fw_major", "fw_minor", "fw_patch", "connected_events", "hosted_phase", "hosted_frames", "hosted_priv", "rpc_status", "rpc_response", "ip", "gateway", "netmask", "long_sent", "long_attempts", "long_burst", "long_echo", "long_echo_mask", "long_final_wait_ms" }) |field| {
        print(" " ++ field ++ "=");
        const value = @field(report, field);
        if (@TypeOf(value) == u32) hex(value) else for (value) |word| hex(word);
    }
    print("\n");
    if (config.enabled or config.hosted) {
        if (report.status == 1 and report.ip != 0 and report.stage == (if (config.hosted) @as(u32, 12) else 10)) {
            print(if (config.hosted) "NIHOS_C6_HOSTED_WIFI_PASS ip=" else "NIHOS_C6_WIFI_PASS ip=");
            printAddress(report.ip);
            print(" gateway=");
            printAddress(report.gateway);
            print(" netmask=");
            printAddress(report.netmask);
            print("\n");
        } else print(if (config.hosted) "NIHOS_C6_HOSTED_WIFI_FAIL\n" else "NIHOS_C6_WIFI_FAIL\n");
    } else print(if (report.status == 1) "NIHOS_C6_AT_PASS\n" else "NIHOS_C6_AT_FAIL\n");
    if (config.ipv6) {
        print("NIHOS_C6_IPV6 linklocal=");
        print6(report.ip6_linklocal);
        print(" address=");
        print6(report.ip6_slaac);
        print(" router=");
        print6(report.ip6_router);
        print("\n");
        print(if (report.status == 1 and report.ip6_link_valid == 1 and report.ip6_slaac_valid == 1 and report.ip6_ping != 0)
            "NIHOS_C6_IPV6_PASS\n"
        else if (report.ip6_link_valid == 1) "NIHOS_C6_IPV6_PARTIAL\n" else "NIHOS_C6_IPV6_FAIL\n");
    }
    halt();
}
