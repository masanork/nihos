//! Opt-in native boot fixture. Requires backed-up C6 running the AT candidate.
//! Exclusive, polling SDMMC ownership before CPU1 release, no filesystem/NVS IO.
const std = @import("std");
const sd = @import("sdio");
const pipe = @import("c6_sdio");
const control = @import("at_controller");
const timers = @import("timer_group");
const wifi = control.wifi;
pub const WifiJoin = wifi.Join;
var station: ?wifi.Probe = null;
extern fn nih_c6_pads_init() callconv(.c) void;
extern fn nih_c6_reset(u32) callconv(.c) void;
extern fn nih_c6_fourbit_pins() callconv(.c) void;
extern fn nih_rom_cache_writeback(u32, u32, u32) callconv(.c) i32;
extern fn nih_rom_cache_invalidate(u32, u32, u32) callconv(.c) i32;
var dma_data: [512]u8 align(64) = @splat(0);
var dma_descriptor: [16]u32 align(64) = @splat(0);
var clock_failed = false;
const Bus = struct {
    clock: timers.Timer = timers.Timer.fromGroup(0x500c2000, 0).?,
    pub fn read(_: Bus, offset: usize) u32 {
        return @as(*volatile u32, @ptrFromInt(sd.base + offset)).*;
    }
    pub fn write(_: Bus, offset: usize, value: u32) void {
        @as(*volatile u32, @ptrFromInt(sd.base + offset)).* = value;
        asm volatile ("fence iorw, iorw" ::: .{ .memory = true });
    }
    pub fn delay(self: Bus, microseconds: u32) void {
        if (clock_failed) return;
        const started = self.clock.counter() orelse {
            clock_failed = true;
            return;
        };
        for (0..200_000_000) |_| {
            const now = self.clock.counter() orelse {
                clock_failed = true;
                return;
            };
            if (now >= started and now - started >= microseconds) return;
        }
        clock_failed = true;
    }
    pub fn fourBitPins(_: Bus) void {
        nih_c6_fourbit_pins();
    }
    pub fn prepareDma(_: Bus, writing: bool, source: []const u8, length: usize) ?u32 {
        if (length == 0 or length > 512 or length % 4 != 0) return null;
        // Cache operations cover exclusively owned complete 64-byte lines.
        if (writing) {
            @memset(&dma_data, 0);
            @memcpy(dma_data[0..length], source);
        }
        dma_descriptor = @splat(0);
        dma_descriptor[0] = (1 << 31) | (1 << 4) | (1 << 3) | (1 << 2);
        dma_descriptor[1] = @intCast(length);
        dma_descriptor[2] = @intFromPtr(&dma_data);
        if (nih_rom_cache_writeback(1 << 4, @intFromPtr(&dma_data), 512) != 0 or
            (!writing and nih_rom_cache_invalidate(1 << 4, @intFromPtr(&dma_data), 512) != 0) or
            nih_rom_cache_writeback(1 << 4, @intFromPtr(&dma_descriptor), 64) != 0) return null;
        asm volatile ("fence iorw, iorw" ::: .{ .memory = true });
        return @intFromPtr(&dma_descriptor);
    }
    pub fn finishDma(_: Bus, writing: bool, destination: []u8) bool {
        asm volatile ("fence iorw, iorw" ::: .{ .memory = true });
        if (nih_rom_cache_invalidate(1 << 4, @intFromPtr(&dma_descriptor), 64) != 0) return false;
        if (@as(*volatile u32, &dma_descriptor[0]).* & ((1 << 31) | (1 << 30)) != 0) return false;
        if (!writing) {
            if (nih_rom_cache_invalidate(1 << 4, @intFromPtr(&dma_data), 512) != 0) return false;
            for (destination, 0..) |*byte, i| byte.* = @as(*volatile u8, &dma_data[i]).*;
        }
        return true;
    }
};

var host = sd.Controller(Bus){ .io = .{} };
var stream = pipe.Stream(@TypeOf(host)){ .host = &host };
var owner: control.Controller = .{};
var rx: [512]u8 = @splat(0);
pub const Report = struct {
    status: u32 = 0,
    stage: u32 = 0,
    error_code: u32 = 0,
    command: u32 = 0,
    interrupts: u32 = 0,
    response: u32 = 0,
    dma: u32 = 0,
    cleanup_failed: u32 = 0,
    commands: u32 = 0,
    rca: u32 = 0,
    ocr: u32 = 0,
    tx: u32 = 0,
    rx: u32 = 0,
    discarded: u32 = 0,
    profile: u32 = 0,
    version_lines: u32 = 0,
    heap_lines: u32 = 0,
    heap: u32 = 0,
    minimum_heap: u32 = 0,
    notices: u32 = 0,
    clock_khz: u32 = 0,
    bus_bits: u32 = 0,
    wifi_step: u32 = 0,
    dhcp: u32 = 0,
    wifi_state: u32 = 0,
    ip: u32 = 0,
    gateway: u32 = 0,
    netmask: u32 = 0,
    connected_events: u32 = 0,
    got_ip_events: u32 = 0,
};

fn snapshot(report: Report) Report {
    var result = report;
    result.command = host.last_command;
    result.interrupts = host.last_interrupts;
    result.response = host.last_response;
    result.dma = host.last_dma;
    result.cleanup_failed = @intFromBool(host.cleanup_failed);
    result.commands = host.commands;
    result.rca = host.rca;
    result.ocr = host.ocr;
    result.clock_khz = if (host.prepared) 400 else 0;
    result.bus_bits = if (!host.prepared) 0 else if (host.four_bit) 4 else 1;
    if (station) |value| {
        result.wifi_step = @backingInt(value.step) + 1;
        result.dhcp = value.dhcp orelse 0;
        result.wifi_state = value.state orelse 0;
        result.ip = value.ip orelse 0;
        result.gateway = value.gateway orelse 0;
        result.netmask = value.netmask orelse 0;
        result.connected_events = value.connected_events;
        result.got_ip_events = value.got_ip_events;
    }
    return result;
}

fn notice(report: *Report, item: control.Notice) !void {
    switch (item) {
        .profile_ready => report.profile += 1,
        .line => |line| {
            if (station) |*value| try value.line(line);
            if (std.mem.startsWith(u8, line, "AT version:")) report.version_lines += 1;
            if (std.mem.startsWith(u8, line, "+SYSRAM:")) {
                var fields = std.mem.splitScalar(u8, line[8..], ',');
                report.heap = try std.fmt.parseInt(u32, fields.next() orelse return error.HeapReply, 10);
                report.minimum_heap = try std.fmt.parseInt(u32, fields.next() orelse return error.HeapReply, 10);
                if (fields.next() != null or report.heap == 0 or report.minimum_heap == 0) return error.HeapReply;
                report.heap_lines += 1;
            }
        },
        .available, .data => report.notices += 1,
    }
}

fn pump(clock: timers.Timer, report: *Report, wait_profile: bool, budget: u64) !void {
    const started = clock.counter() orelse return error.Clock;
    for (0..1_000_000) |_| {
        const count = try stream.receive(&rx);
        report.rx +|= @intCast(count);
        for (rx[0..count]) |byte| {
            const now = clock.counter() orelse return error.Clock;
            if (try owner.push(byte, now)) |item| try notice(report, item);
        }
        const now = clock.counter() orelse return error.Clock;
        if (clock_failed or now < started) return error.Clock;
        if (now - started > budget) return error.Timeout;
        const bytes = try owner.tx(now);
        if (bytes.len != 0) {
            const sent = try stream.send(bytes);
            try owner.consumeTx(sent, clock.counter() orelse return error.Clock);
            report.tx +|= @intCast(sent);
        }
        // A trailing URC can share a FIFO read with the final OK. Finish that
        // frame before the next query rather than treating submit's Busy as a
        // command failure. The overall pump budget also bounds a torn idle URC.
        const boundary = owner.decoder.mode == .text and owner.decoder.line_len == 0;
        if (wait_profile and owner.ready() and boundary) return;
        if (!wait_profile and boundary) if (owner.takeCompletion()) |completion| {
            if (completion.failure != null) return error.CommandRejected;
            return;
        };
        host.io.delay(100);
    }
    return error.Timeout;
}

fn exercise(clock: timers.Timer, report: *Report, join: ?WifiJoin) !void {
    report.stage = 1;
    nih_c6_pads_init();
    host.io.delay(20_000);
    nih_c6_reset(1);
    host.io.delay(2_000_000);
    if (clock_failed) return error.Clock;
    report.stage = 2;
    try host.prepare(true);
    report.stage = 3;
    try host.identify();
    report.stage = 4;
    try host.enableFunction();
    report.stage = 5;
    // Discard the fresh peer's boot banner before controller negotiation. Keep
    // accounting for every FIFO byte, rather than rebasing the hardware counter.
    const started = clock.counter() orelse return error.Clock;
    var quiet_since = started;
    var settled = false;
    for (0..10_000) |_| {
        const count = try stream.receive(&rx);
        report.discarded +|= @intCast(count);
        const now = clock.counter() orelse return error.Clock;
        if (clock_failed or now < started or now - started > 500_000) return error.Clock;
        if (count != 0) quiet_since = now;
        if (now - quiet_since >= 50_000) {
            settled = true;
            break;
        }
        host.io.delay(100);
    }
    if (!settled) return error.Timeout;
    report.stage = 6;
    try owner.recover(clock.counter() orelse return error.Clock, 1_000_000);
    try pump(clock, report, true, 15_000_000);
    report.stage = 7;
    var now = clock.counter() orelse return error.Clock;
    _ = try owner.submit(.version, now, now + 1_000_000);
    try pump(clock, report, false, 1_000_000);
    now = clock.counter() orelse return error.Clock;
    _ = try owner.submit(.memory, now, now + 1_000_000);
    try pump(clock, report, false, 1_000_000);
    if (report.profile != 1 or report.version_lines < 2 or report.heap_lines != 1) return error.MissingEvidence;
    if (join) |credentials| {
        report.stage = 9;
        station = .{};
        while (station.?.step != .done) {
            const command = try station.?.command(credentials);
            const timeout: u64 = if (station.?.step == .join) 30_000_000 else 2_000_000;
            now = clock.counter() orelse return error.Clock;
            _ = try owner.submit(command, now, now + timeout);
            try pump(clock, report, false, timeout);
            try station.?.complete();
        }
    }
    report.status = 1;
    report.stage = if (join != null) 10 else 8;
}

pub fn run(clock: timers.Timer, join: ?WifiJoin) Report {
    host = .{ .io = .{ .clock = clock } };
    stream = .{ .host = &host };
    owner = .{};
    station = null;
    clock_failed = false;
    clock.start();
    clock.disarm();
    defer clock.stop();
    var report: Report = .{};
    exercise(clock, &report, join) catch |err| {
        report.error_code = @intFromError(err);
        owner.transportFailed();
        stream.invalidate();
    };
    return snapshot(report);
}
