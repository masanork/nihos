//! Native C6 transport fixture and shared CPU0-only DMA/pad support.
//! Exclusive, polling SDMMC ownership before CPU1 release, no filesystem/NVS IO.
const std = @import("std");
const options = @import("native_options");
pub const shared_api = @import("shared_sdmmc_abi.zig");
const sd = @import("sdio");
const pipe = @import("c6_sdio");
const control = @import("at_controller");
const timers = @import("timer_group");
const hosted = @import("hosted_station");
const wifi = control.wifi;
pub const WifiJoin = wifi.Join;
pub const HostedJoin = hosted.Join;
var station: ?wifi.Probe = null;
extern fn nih_c6_pads_init() callconv(.c) void;
extern fn nih_c6_reset(u32) callconv(.c) void;
extern fn nih_c6_fourbit_pins() callconv(.c) void;
extern fn nih_c6_power_enable() callconv(.c) u32;
extern fn nih_rom_putc(u8) callconv(.c) i32;
extern fn nih_rom_cache_writeback(u32, u32, u32) callconv(.c) i32;
extern fn nih_rom_cache_invalidate(u32, u32, u32) callconv(.c) i32;
var dma_data: [512]u8 align(64) = @splat(0);
var dma_descriptor: [16]u32 align(64) = @splat(0);
var clock_failed = false;
pub const Bus = struct {
    pub const shared_host = @hasDecl(options, "normal_storage") and options.normal_storage;
    lease: shared_api.Lease = .{},
    clock: timers.Timer = timers.Timer.fromGroup(0x500c2000, 0).?,
    pub fn ownsSlot(self: Bus, slot: u32) bool {
        return slot == 1 and shared_api.owns(self.lease);
    }
    pub fn read(self: Bus, offset: usize) u32 {
        if (shared_host) return shared_api.read(self.lease, offset);
        return @as(*volatile u32, @ptrFromInt(sd.base + offset)).*;
    }
    pub fn write(self: Bus, offset: usize, value: u32) void {
        if (shared_host) return shared_api.write(self.lease, offset, value);
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
    pub fn prepareDma(self: Bus, writing: bool, source: []const u8, length: usize) ?u32 {
        if (shared_host and !self.ownsSlot(1)) return null;
        if (length == 0 or length > 512 or length % 4 != 0) return null;
        // CPU0 display IRQs also use the ROM cache command engine. Serialize
        // only these private 512/64-byte cache operations, never SDIO waits.
        const previous = maskCache();
        defer restoreCache(previous);
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
    pub fn finishDma(self: Bus, writing: bool, destination: []u8) bool {
        if (shared_host and !self.ownsSlot(1)) return false;
        const previous = maskCache();
        defer restoreCache(previous);
        asm volatile ("fence iorw, iorw" ::: .{ .memory = true });
        if (nih_rom_cache_invalidate(1 << 4, @intFromPtr(&dma_descriptor), 64) != 0) return false;
        if (@as(*volatile u32, &dma_descriptor[0]).* & ((1 << 31) | (1 << 30)) != 0) return false;
        if (!writing) {
            if (nih_rom_cache_invalidate(1 << 4, @intFromPtr(&dma_data), 512) != 0) return false;
            for (destination, 0..) |*byte, i| byte.* = @as(*volatile u8, &dma_data[i]).*;
        }
        return true;
    }
    pub fn releaseDma(_: Bus) bool {
        return releaseDmaBuffer();
    }
};
fn releaseDmaBuffer() bool {
    const previous = maskCache();
    defer restoreCache(previous);
    asm volatile ("fence iorw,iorw" ::: .{ .memory = true });
    if (nih_rom_cache_invalidate(1 << 4, @intFromPtr(&dma_data), 512) != 0 or
        nih_rom_cache_invalidate(1 << 4, @intFromPtr(&dma_descriptor), 64) != 0) return false;
    dma_descriptor = @splat(0);
    if (nih_rom_cache_writeback(1 << 4, @intFromPtr(&dma_descriptor), 64) != 0) return false;
    asm volatile ("fence iorw,iorw" ::: .{ .memory = true });
    return true;
}
pub fn releaseNormalDma() u32 {
    return @intFromBool(releaseDmaBuffer());
}

fn maskCache() u32 {
    return asm volatile ("csrrci %[previous], mstatus, 8"
        : [previous] "=r" (-> u32),
        :
        : .{ .memory = true });
}
fn restoreCache(previous: u32) void {
    if (previous & 8 != 0) asm volatile ("csrsi mstatus, 8" ::: .{ .memory = true });
}

var host = sd.Controller(Bus){ .io = .{} };
var stream = pipe.Stream(@TypeOf(host)){ .host = &host };
var owner: control.Controller = .{};
var rx: [512]u8 = @splat(0);
var hosted_stream = pipe.ProfileStream(@TypeOf(host), 64){ .host = &host };
var hosted_client: hosted.Client = .{};
var hosted_decoder: hosted.wire.Decoder = .{};
/// Bind the LL power shim's delay clock without starting/stopping a timer.
/// The integrated owner and standalone fixture are mutually exclusive builds.
pub fn useClock(clock: timers.Timer) void {
    host.io.clock = clock;
    clock_failed = false;
}
pub fn clockFailed() bool {
    return clock_failed;
}
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
    hosted_phase: u32 = 0,
    hosted_frames: u32 = 0,
    hosted_priv: u32 = 0,
    hosted_unchecked: u32 = 0,
    hosted_ignored: u32 = 0,
    rpc_status: u32 = 0,
    rpc_response: u32 = 0,
    disconnect_reason: u32 = 0,
    fw_known: u32 = 0,
    fw_major: u32 = 0,
    fw_minor: u32 = 0,
    fw_patch: u32 = 0,
    dhcp_offered: u32 = 0,
    dhcp_server: u32 = 0,
    dhcp_seconds: u32 = 0,
    peer_chip: u32 = 0,
    peer_mode: u32 = 255,
    peer_version: u32 = 0,
    hosted_network_drops: u32 = 0,
    ip6_stage: u32 = 0,
    ip6_link_valid: u32 = 0,
    ip6_slaac_valid: u32 = 0,
    ip6_ras: u32 = 0,
    ip6_ns: u32 = 0,
    ip6_na: u32 = 0,
    ip6_ping: u32 = 0,
    ip6_dropped: u32 = 0,
    ip6_received: u32 = 0,
    ip6_rs_sent: u32 = 0,
    ip6_echo_requests: u32 = 0,
    ip6_linklocal: [4]u32 = @splat(0),
    ip6_slaac: [4]u32 = @splat(0),
    ip6_router: [4]u32 = @splat(0),
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

// Used only by the LL shim's bounded, open-drain I2C power-enable transaction.
export fn nih_c6_delay_us(value: u32) callconv(.c) void {
    host.io.delay(value);
}

// Keep the Hosted execution path as a distinct function for the image audit.
noinline fn exerciseHosted(clock: timers.Timer, report: *Report, join: hosted.Join, enable_ipv6: bool) !void {
    report.stage = 1;
    nih_c6_pads_init();
    if (nih_c6_power_enable() != 1) return error.PowerEnable;
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
    // Factory ESP-Hosted gates its INIT event on the scratch-7 datapath bit.
    // Scratch-7 is a host->slave doorbell, not a stable configuration byte.
    // The peer can clear it before RAW readback; require a successful R5,
    // then use the INIT event as acknowledgement instead of byte equality.
    try host.writeDoorbell(1, 0x8c, 1);
    report.stage = 11;
    const started = clock.counter() orelse return error.Clock;
    hosted_client.beginDual(join, started, enable_ipv6);
    for (0..2_000_000) |_| {
        const count = try hosted_stream.receive(&rx);
        report.rx +|= @intCast(count);
        for (rx[0..count]) |byte| if (try hosted_decoder.push(byte)) |frame| {
            try hosted_client.receive(frame, clock.counter() orelse return error.Clock);
        };
        const now = clock.counter() orelse return error.Clock;
        if (clock_failed or now < started) return error.Clock;
        if (now - started > 100_000_000) return error.Timeout;
        if (hosted_client.ipv6_client) |client| if (client.ll_valid and report.ip6_link_valid == 0) {
            report.ip6_link_valid = 1;
            for ("NIHOS_C6_IPV6_LINK_READY\r\n") |byte| _ = nih_rom_putc(byte);
        };
        if (hosted_client.phase == .done and hosted_decoder.used == 0) {
            if (hosted_client.dhcp_client.?.lease) |lease| {
                report.ip = lease.ip;
                report.gateway = lease.gateway;
                report.netmask = lease.mask;
                report.dhcp_server = lease.server;
                report.dhcp_seconds = lease.seconds;
            }
            report.status = 1;
            report.stage = 12;
            return;
        }
        const bytes = try hosted_client.tx(now);
        if (bytes.len != 0) {
            const sent = try hosted_stream.send(bytes);
            if (sent != 0 and sent != bytes.len) return error.PartialPacket;
            if (sent != 0) hosted_client.sent(clock.counter() orelse return error.Clock);
            report.tx +|= @intCast(sent);
        }
        host.io.delay(100);
    }
    return error.Timeout;
}

pub fn runHosted(clock: timers.Timer, join: hosted.Join, enable_ipv6: bool) Report {
    host = .{ .io = .{ .clock = clock } };
    hosted_stream = .{ .host = &host };
    hosted_client = .{};
    hosted_decoder = .{};
    station = null;
    clock_failed = false;
    clock.start();
    clock.disarm();
    defer clock.stop();
    var report: Report = .{};
    exerciseHosted(clock, &report, join, enable_ipv6) catch |err| {
        report.error_code = @intFromError(err);
        hosted_stream.invalidate();
    };
    report.hosted_phase = @backingInt(hosted_client.phase) + 1;
    report.hosted_frames = hosted_client.frames;
    report.hosted_priv = hosted_client.priv_events;
    report.hosted_unchecked = hosted_decoder.unchecked;
    report.hosted_ignored = hosted_client.ignored_rpcs;
    report.rpc_status = hosted_client.rpc_status;
    report.rpc_response = hosted_client.last_response;
    report.disconnect_reason = hosted_client.disconnect_reason;
    report.fw_known = @intFromBool(hosted_client.version_known);
    report.fw_major = hosted_client.version[0];
    report.fw_minor = hosted_client.version[1];
    report.fw_patch = hosted_client.version[2];
    report.peer_chip = hosted_client.peer_chip;
    report.peer_mode = hosted_client.peer_mode;
    report.peer_version = hosted_client.peer_version;
    report.hosted_network_drops = hosted_client.malformed_network;
    report.connected_events = @intFromBool(hosted_client.connected);
    if (hosted_client.dhcp_client) |client| report.dhcp_offered = client.offered;
    if (hosted_client.ipv6_client) |client| {
        report.ip6_stage = @backingInt(client.stage) + 1;
        report.ip6_link_valid = @intFromBool(client.ll_valid);
        report.ip6_slaac_valid = @intFromBool(client.slaac_valid);
        report.ip6_ras = client.ras;
        report.ip6_ns = client.ns_received;
        report.ip6_na = client.na_received;
        report.ip6_ping = client.ping_replies;
        report.ip6_dropped = client.dropped;
        report.ip6_received = client.received;
        report.ip6_rs_sent = client.solicitations;
        report.ip6_echo_requests = client.echo_requests;
        for (0..4) |i| {
            report.ip6_linklocal[i] = std.mem.readInt(u32, client.ll[i * 4 ..][0..4], .big);
            report.ip6_slaac[i] = std.mem.readInt(u32, client.address[i * 4 ..][0..4], .big);
            report.ip6_router[i] = std.mem.readInt(u32, client.router[i * 4 ..][0..4], .big);
        }
    }
    return snapshot(report);
}
