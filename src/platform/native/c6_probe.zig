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
extern fn nih_c6_power_failure_detail() callconv(.c) u32;
extern fn nih_rom_putc(u8) callconv(.c) i32;
extern fn nih_c6_serial_read() callconv(.c) i32;
extern fn nih_rom_cache_writeback(u32, u32, u32) callconv(.c) i32;
extern fn nih_rom_cache_invalidate(u32, u32, u32) callconv(.c) i32;
var dma_data: [512]u8 align(64) = @splat(0);
var dma_descriptor: [16]u32 align(64) = @splat(0);
var clock_failed = false;
pub const ShortBus = struct {
    pub const shared_host = @hasDecl(options, "normal_storage") and options.normal_storage;
    lease: shared_api.Lease = .{},
    clock: timers.Timer = timers.Timer.fromGroup(0x500c2000, 0).?,
    pub fn setClock(self: *ShortBus, clock: timers.Timer) void {
        self.clock = clock;
    }
    pub fn ownsSlot(self: ShortBus, slot: u32) bool {
        return slot == 1 and shared_api.owns(self.lease);
    }
    pub fn read(self: ShortBus, offset: usize) u32 {
        if (shared_host) return shared_api.read(self.lease, offset);
        return @as(*volatile u32, @ptrFromInt(sd.base + offset)).*;
    }
    pub fn write(self: ShortBus, offset: usize, value: u32) void {
        if (shared_host) return shared_api.write(self.lease, offset, value);
        @as(*volatile u32, @ptrFromInt(sd.base + offset)).* = value;
        asm volatile ("fence iorw, iorw" ::: .{ .memory = true });
    }
    pub fn delay(self: ShortBus, microseconds: u32) void {
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
    pub fn fourBitPins(_: ShortBus) void {
        nih_c6_fourbit_pins();
    }
    pub fn prepareDma(self: ShortBus, writing: bool, source: []const u8, length: usize) ?u32 {
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
    pub fn finishDma(self: ShortBus, writing: bool, destination: []u8) bool {
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
    pub fn releaseDma(_: ShortBus) bool {
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
// Only an explicit diagnostic root selects a different DMA provider.
pub const Bus = if (@hasDecl(@import("root"), "C6Bus")) @import("root").C6Bus(ShortBus) else ShortBus;

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
    host.io.setClock(clock);
    clock_failed = false;
}
pub fn clockFailed() bool {
    return clock_failed;
}
pub const Report = struct {
    power_failure: u32 = 0,
    short_sent: u32 = 0,
    short_echo: u32 = 0,
    long_echo: u32 = 0,
    long_attempts: u32 = 0,
    long_burst: u32 = 0,
    long_settle_ms: u32 = 0,
    long_final_wait_ms: u32 = 0,
    long_echo_mask: u32 = 0,
    echo_arp: u32 = 0,
    long_logical: u32 = 0,
    long_wire: u32 = 0,
    long_hash: u32 = 0,
    long_sent: u32 = 0,
    long_dma_state: u32 = 0,
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
    host.io.delay(300_000);
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
    host = .{ .io = .{} };
    host.io.setClock(clock);
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
    if (nih_c6_power_enable() != 1) {
        report.power_failure = nih_c6_power_failure_detail();
        return error.PowerEnable;
    }
    host.io.delay(20_000);
    nih_c6_reset(1);
    // Long-DMA boot diagnostics retain the reset settling time used by their
    // original physical fixture. The normal network owner has its own path.
    const root = @import("root");
    const long_probe = @hasDecl(root, "C6LongDmaEnabled") and root.C6LongDmaEnabled;
    host.io.delay(if (long_probe) 2_000_000 else 300_000);
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
            if (@hasDecl(@import("root"), "C6LongProbe"))
                try @import("root").C6LongProbe(&hosted_stream, &hosted_decoder, &hosted_client, hosted_client.mac_address, report.ip, hosted.wire.station_interface, hosted.wire.frame, hosted.wire.frameInPlace, clock, report);
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
    host = .{ .io = .{} };
    host.io.setClock(clock);
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
        for ("NIHOS_C6_HOSTED_ERROR name=") |byte| _ = nih_rom_putc(byte);
        for (@errorName(err)) |byte| _ = nih_rom_putc(byte);
        for ("\r\n") |byte| _ = nih_rom_putc(byte);
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

/// Experimental C6-owned SNTP fixture using the Hosted transport.
/// Sends no OTA requests.
pub const TimeReport = struct {
    status: u32 = 0,
    stage: u32 = 0,
    error_code: u32 = 0,
    tx: u32 = 0,
    rx: u32 = 0,
    peer_chip: u32 = 0,
    fw_known: u32 = 0,
    major: u32 = 0,
    minor: u32 = 0,
    patch: u32 = 0,
    phase: u32 = 0,
    station_phase: u32 = 0,
    station_active_id: u32 = 0,
    station_uid: u32 = 0,
    station_connected: u32 = 0,
    station_last_response: u32 = 0,
    station_rpc_status: u32 = 0,
    last_rpc_id: u32 = 0,
    last_rpc_kind: u32 = 0,
    split_generation: u32 = 0,
    split_address_known: u32 = 0,
    attempts: u32 = 0,
    acknowledged: u32 = 0,
    got_result: u32 = 0,
    synced: u32 = 0,
    seconds_low: u32 = 0,
    seconds_high: u32 = 0,
    age_seconds: u32 = 0,
};
var hosted_time: hosted.c6_time_exchange.Exchange = .{};
// SAFETY: the split UDP fixture initializes the owner before stepping it.
var hosted_split_udp: hosted.split_udp_owner.Owner = undefined;

/// Separate diagnostic: C6 owns DHCP, and one owner sends a single UDP frame.
noinline fn exerciseHostedSplitUdp(clock: timers.Timer, report: *Report, join: hosted.Join) !void {
    const config = @import("root").SplitUdpConfig;
    report.stage = 1;
    nih_c6_pads_init();
    if (nih_c6_power_enable() != 1) {
        report.power_failure = nih_c6_power_failure_detail();
        return error.PowerEnable;
    }
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
    try host.writeDoorbell(1, 0x8c, 1);
    report.stage = 5;
    const started = clock.counter() orelse return error.Clock;
    try hosted_time.begin(join, 1, started, started + 100_000_000);
    while (true) {
        const count = try hosted_stream.receive(&rx);
        report.rx +|= @intCast(count);
        for (rx[0..count]) |byte| if (try hosted_decoder.push(byte)) |frame| {
            try hosted_time.receive(frame, clock.counter() orelse return error.Clock);
        };
        const now = clock.counter() orelse return error.Clock;
        if (clock_failed or now < started) return error.Clock;
        if (now >= hosted_time.deadline) return error.Timeout;
        const acquisition = try hosted.split_udp_owner.acquisition(&hosted_time, &hosted_decoder);
        if (acquisition == .drain) {
            // A split control frame must finish before transferring ownership;
            // calling tx here would start an unrelated C6 time request.
            host.io.delay(100);
            continue;
        }
        if (acquisition == .ready) {
            const address = hosted_time.addresses.address orelse return error.Stale;
            report.ip = address.ip;
            report.netmask = address.mask;
            report.gateway = address.gateway;
            report.stage = 6;
            const peer = hosted.split_udp_owner.Peer{ .ip = config.udp_ip, .mac = config.udp_mac, .port = config.udp_port };
            const deadline = @min(now + 20_000_000, hosted_time.deadline);
            if (config.udp_burst) {
                try hosted_split_udp.initBurst(&hosted_time, &hosted_decoder, peer, 16, 250_000, 8_000_000, now, deadline);
            } else {
                try hosted_split_udp.init(&hosted_time, &hosted_decoder, peer, 1, now, deadline);
            }
            report.stage = 7;
            defer {
                report.long_sent = if (hosted_split_udp.sent_count != 0) @intCast(hosted_split_udp.output.len) else 0;
                report.long_attempts = hosted_split_udp.sent_count;
                report.long_burst = @intFromBool(config.udp_burst);
                report.long_echo_mask = hosted_split_udp.echo_mask;
                report.long_echo = @as(u32, @popCount(hosted_split_udp.echo_mask)) +| hosted_split_udp.duplicate_echoes;
                if (hosted_split_udp.sent_count != 0 and hosted_split_udp.last_now >= hosted_split_udp.last_send)
                    report.long_final_wait_ms = @intCast(@min((hosted_split_udp.last_now - hosted_split_udp.last_send) / 1000, 0xffffffff));
            }
            while (hosted_split_udp.phase != .complete) {
                try hosted_split_udp.step(&hosted_stream, clock.counter() orelse return error.Clock);
                if (clock_failed) return error.Clock;
                host.io.delay(100);
            }
            report.status = 1;
            report.stage = 12;
            return;
        }
        const bytes = try hosted_time.tx(now);
        if (bytes.len > 0) {
            const sent = try hosted_stream.send(bytes);
            try hosted_time.sent(sent, clock.counter() orelse return error.Clock);
            report.tx +|= @intCast(sent);
        }
        host.io.delay(100);
    }
}

pub fn runHostedSplitUdp(clock: timers.Timer, join: hosted.Join) Report {
    host = .{ .io = .{} };
    host.io.setClock(clock);
    hosted_stream = .{ .host = &host };
    hosted_decoder = .{};
    hosted_time = .{};
    clock_failed = false;
    clock.start();
    clock.disarm();
    defer clock.stop();
    var report: Report = .{};
    exerciseHostedSplitUdp(clock, &report, join) catch |err| {
        report.error_code = @intFromError(err);
        hosted_stream.invalidate();
    };
    report.fw_known = @intFromBool(hosted_time.station.version_known);
    report.fw_major = hosted_time.station.version[0];
    report.fw_minor = hosted_time.station.version[1];
    report.fw_patch = hosted_time.station.version[2];
    report.peer_chip = hosted_time.station.peer_chip;
    report.connected_events = @intFromBool(hosted_time.station.connected);
    report.hosted_phase = @backingInt(hosted_time.station.phase) + 1;
    report.hosted_frames = hosted_time.station.frames;
    report.hosted_priv = hosted_time.station.priv_events;
    report.rpc_status = hosted_time.station.rpc_status;
    report.rpc_response = hosted_time.last_rpc_id;
    return snapshot(report);
}
noinline fn exerciseHostedTime(clock: timers.Timer, report: *TimeReport, join: hosted.Join) !void {
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
    try host.writeDoorbell(1, 0x8c, 1);
    report.stage = 5;
    const started = clock.counter() orelse return error.Clock;
    try hosted_time.begin(join, 1, started, started + 100_000_000);
    var next_request_at = started;
    while (true) {
        const count = try hosted_stream.receive(&rx);
        report.rx +|= @intCast(count);
        for (rx[0..count]) |byte| if (try hosted_decoder.push(byte)) |frame| {
            try hosted_time.receive(frame, clock.counter() orelse return error.Clock);
        };
        const now = clock.counter() orelse return error.Clock;
        if (clock_failed or now < started) return error.Clock;
        if (hosted_time.phase == .done and hosted_decoder.used == 0) {
            report.attempts +|= 1;
            if (hosted_time.sample != null) {
                report.status = 1;
                report.stage = 6;
                return;
            }
            try hosted_time.nextSnapshot(now);
            next_request_at = now + 1_000_000;
        }
        if (hosted_time.phase == .ready and now < next_request_at) {
            host.io.delay(100);
            continue;
        }
        const bytes = try hosted_time.tx(now);
        if (bytes.len > 0) {
            const count_sent = try hosted_stream.send(bytes);
            try hosted_time.sent(count_sent, clock.counter() orelse return error.Clock);
            report.tx +|= @intCast(count_sent);
        }
        host.io.delay(100);
    }
}
pub fn runHostedTime(clock: timers.Timer, join: hosted.Join) TimeReport {
    host = .{ .io = .{ .clock = clock } };
    hosted_stream = .{ .host = &host };
    hosted_decoder = .{};
    hosted_time = .{};
    clock_failed = false;
    clock.start();
    clock.disarm();
    defer clock.stop();
    var report: TimeReport = .{};
    exerciseHostedTime(clock, &report, join) catch |err| {
        for ("NIHOS_C6_TIME_ERROR ") |byte| _ = nih_rom_putc(byte);
        for (@errorName(err)) |byte| _ = nih_rom_putc(byte);
        for ("\r\n") |byte| _ = nih_rom_putc(byte);
        if (hosted_time.status_body_len != 0) {
            const digits = "0123456789abcdef";
            for ("NIHOS_C6_SPLIT_STATUS_HEX ") |byte| _ = nih_rom_putc(byte);
            for (hosted_time.status_body[0..hosted_time.status_body_len]) |byte| {
                _ = nih_rom_putc(digits[byte >> 4]);
                _ = nih_rom_putc(digits[byte & 15]);
            }
            if (hosted_time.status_body_truncated) for (" truncated") |byte| {
                _ = nih_rom_putc(byte);
            };
            for ("\r\n") |byte| _ = nih_rom_putc(byte);
        }
        report.error_code = @intFromError(err);
        hosted_stream.invalidate();
    };
    const peer = &hosted_time.station;
    report.peer_chip = peer.peer_chip;
    report.fw_known = @intFromBool(peer.version_known);
    report.major = peer.version[0];
    report.minor = peer.version[1];
    report.patch = peer.version[2];
    report.phase = @backingInt(hosted_time.phase) + 1;
    report.station_phase = @backingInt(peer.phase) + 1;
    report.station_active_id = peer.active_id orelse 0;
    report.station_uid = peer.uid;
    report.station_connected = @intFromBool(peer.connected);
    report.station_last_response = peer.last_response;
    report.station_rpc_status = peer.rpc_status;
    report.last_rpc_id = hosted_time.last_rpc_id;
    report.last_rpc_kind = hosted_time.last_rpc_kind;
    report.split_generation = @truncate(hosted_time.addresses.generation);
    report.split_address_known = @intFromBool(hosted_time.addresses.address != null);
    report.acknowledged = @intFromBool(hosted_time.acknowledged);
    report.got_result = @intFromBool(hosted_time.got_result);
    if (hosted_time.sample) |sample| {
        report.synced = 1;
        report.seconds_low = @truncate(sample.seconds);
        report.seconds_high = @truncate(sample.seconds >> 32);
        report.age_seconds = sample.age_seconds;
    }
    return report;
}

pub const OtaInfoReport = struct {
    status: u32 = 0,
    stage: u32 = 0,
    error_code: u32 = 0,
    peer_chip: u32 = 0,
    fw_known: u32 = 0,
    major: u32 = 0,
    minor: u32 = 0,
    patch: u32 = 0,
    desc_known: u32 = 0,
    ack_known: u32 = 0,
    ack_status: u32 = 0,
    result_known: u32 = 0,
    flash_size: u32 = 0,
    running_offset: u32 = 0,
    running_size: u32 = 0,
    boot_offset: u32 = 0,
    boot_size: u32 = 0,
    next_offset: u32 = 0,
    next_size: u32 = 0,
    state_known: u32 = 0,
    running_state: u32 = 0,
    secure_boot: u32 = 0,
    flash_encrypted: u32 = 0,
};
// SAFETY: runOtaInfo initializes the exchange before any read or diagnostic step.
var ota_info_exchange: hosted.c6_ota_info_exchange.Exchange = undefined;
// SAFETY: runOtaInfo initializes the stream guard before exerciseOtaInfo uses it.
var ota_info_guard: hosted.c6_ota_info_exchange.ReadOnlyStream(@TypeOf(hosted_stream)) = undefined;
fn traceOtaInfo(stage: u8) void {
    for ("NIHOS_C6_OTA_INFO_STAGE ") |byte| _ = nih_rom_putc(byte);
    _ = nih_rom_putc(stage);
    _ = nih_rom_putc('\r');
    _ = nih_rom_putc('\n');
}
fn printOtaInfoBytes(bytes: []const u8) void {
    const digits = "0123456789abcdef";
    for (bytes) |b| {
        _ = nih_rom_putc(digits[b >> 4]);
        _ = nih_rom_putc(digits[b & 15]);
    }
}
noinline fn exerciseOtaInfo(clock: timers.Timer, report: *OtaInfoReport) !void {
    report.stage = 1;
    traceOtaInfo('1');
    nih_c6_pads_init();
    if (nih_c6_power_enable() != 1) return error.PowerEnable;
    host.io.delay(20_000);
    nih_c6_reset(1);
    host.io.delay(2_000_000);
    if (clock_failed) return error.Clock;
    report.stage = 2;
    traceOtaInfo('2');
    try host.prepare(true);
    report.stage = 3;
    traceOtaInfo('3');
    try host.identify();
    report.stage = 4;
    traceOtaInfo('4');
    try host.enableFunction();
    try host.writeDoorbell(1, 0x8c, 1);
    report.stage = 5;
    traceOtaInfo('5');
    const start = clock.counter() orelse return error.Clock;
    // The fixture creates one exchange after reset, so the nonce is never
    // reused on a live stream. A longer-lived owner must allocate fresh nonces.
    ota_info_exchange = try hosted.c6_ota_info_exchange.Exchange.init(0x12345678, start, start + 30_000_000);
    traceOtaInfo('6');
    var previous_state = ota_info_exchange.state;
    while (true) {
        const now = clock.counter() orelse return error.Clock;
        try ota_info_exchange.step(&ota_info_guard, now);
        if (ota_info_exchange.state != previous_state) {
            traceOtaInfo('A' + @as(u8, @intCast(@backingInt(ota_info_exchange.state))));
            previous_state = ota_info_exchange.state;
        }
        if (ota_info_exchange.state == .complete) {
            report.status = 1;
            report.stage = 6;
            return;
        }
        if (clock_failed) return error.Clock;
        host.io.delay(100);
    }
}
pub fn runOtaInfo(clock: timers.Timer) OtaInfoReport {
    traceOtaInfo('0');
    host = .{ .io = .{ .clock = clock } };
    hosted_stream = .{ .host = &host };
    ota_info_guard = .{ .inner = &hosted_stream };
    clock_failed = false;
    var report: OtaInfoReport = .{};
    // Safe default even if power or transport setup fails before init().
    ota_info_exchange = hosted.c6_ota_info_exchange.Exchange.init(1, 0, 1) catch |err| {
        report.error_code = @intFromError(err);
        return report;
    };
    exerciseOtaInfo(clock, &report) catch |err| {
        report.error_code = @intFromError(err);
        hosted_stream.invalidate();
    };
    const peer = &ota_info_exchange.client;
    report.peer_chip = peer.peer_chip;
    report.fw_known = @intFromBool(peer.version_known);
    report.major = peer.version[0];
    report.minor = peer.version[1];
    report.patch = peer.version[2];
    report.ack_known = @intFromBool(ota_info_exchange.ack_status != null);
    report.ack_status = ota_info_exchange.ack_status orelse 0;
    if (ota_info_exchange.description) |value| {
        report.desc_known = 1;
        for ("NIHOS_C6_APP_DESC version=") |b| _ = nih_rom_putc(b);
        printOtaInfoBytes(value.version.slice());
        for (" project=") |b| _ = nih_rom_putc(b);
        printOtaInfoBytes(value.project.slice());
        for (" idf=") |b| _ = nih_rom_putc(b);
        printOtaInfoBytes(value.idf.slice());
        for (" elf_sha256=") |b| _ = nih_rom_putc(b);
        if (value.elf_sha256) |digest| printOtaInfoBytes(&digest) else _ = nih_rom_putc('-');
        for ("\r\n") |b| _ = nih_rom_putc(b);
    }
    if (ota_info_exchange.state == .complete) if (ota_info_exchange.query.result) |value| {
        report.result_known = 1;
        report.flash_size = value.flash_size;
        report.running_offset = value.running.offset;
        report.running_size = value.running.size;
        report.boot_offset = value.boot.offset;
        report.boot_size = value.boot.size;
        report.next_offset = value.next.offset;
        report.next_size = value.next.size;
        report.state_known = @intFromBool(value.running_state != null);
        report.running_state = value.running_state orelse 0;
        report.secure_boot = @intFromBool(value.secure_boot);
        report.flash_encrypted = @intFromBool(value.flash_encrypted);
    };
    return report;
}

/// OTA preflight: complete the version handshake, then stop before OTA Begin.
/// This path does not update C6 or send any persistent-write RPC.
pub const OtaPreflight = struct { status: u32 = 0, stage: u32 = 0, last_command: u32 = 0, last_interrupts: u32 = 0, error_code: u32 = 0, peer_chip: u32 = 0, version_known: u32 = 0, major: u32 = 0, minor: u32 = 0, patch: u32 = 0, diag_known: u32 = 0, diag_uptime: u32 = 0, diag_heap: u32 = 0 };
var ota_preflight_stage: u32 = 0;
noinline fn exerciseOtaPreflight(clock: timers.Timer, image: []const u8, hash: [32]u8) !OtaPreflight {
    const started = clock.counter() orelse return error.Clock;
    try ota_update_guard.session.initInPlace(image, hash, started, started + 30_000_000);
    const root = @import("root");
    ota_update_guard.session.allow_213 = @hasDecl(root, "C6OtaAllow213") and root.C6OtaAllow213;
    ota_update_guard.session.allow_310 = @hasDecl(root, "C6OtaAllow310") and root.C6OtaAllow310;
    ota_preflight_stage = 1;
    nih_c6_pads_init();
    if (nih_c6_power_enable() != 1) return error.PowerEnable;
    host.io.delay(20_000);
    nih_c6_reset(1);
    // Prior Tab5 long Hosted diagnostics saw repeated CMD52 response
    // timeouts at 300 ms and completed initialization after a 2 s settle.
    // This is a conservative preflight setting, not a proven root cause.
    host.io.delay(2_000_000);
    if (clock_failed) return error.Clock;
    ota_preflight_stage = 2;
    try host.prepare(true);
    ota_preflight_stage = 3;
    try host.identify();
    ota_preflight_stage = 4;
    try host.enableFunction();
    ota_preflight_stage = 5;
    try host.writeDoorbell(1, 0x8c, 1);
    ota_preflight_stage = 6;
    while (true) {
        const session = &ota_update_guard.session;
        const now = clock.counter() orelse return error.Clock;
        if (@hasDecl(root, "C6OtaSimulation") and root.C6OtaSimulation) {
            try session.step(&ota_safe, now);
        } else {
            try session.step(&hosted_stream, now);
        }
        if (session.state == .transfer) {
            const diag = session.client.c6_diagnostics;
            return .{ .status = 1, .stage = ota_preflight_stage, .last_command = host.last_command, .last_interrupts = host.last_interrupts, .peer_chip = session.client.peer_chip, .version_known = @intFromBool(session.client.version_known), .major = session.client.version[0], .minor = session.client.version[1], .patch = session.client.version[2], .diag_known = @intFromBool(diag != null), .diag_uptime = if (diag) |d| d.uptime_seconds else 0, .diag_heap = if (diag) |d| d.free_heap_bytes else 0 };
        }
        if (clock_failed) return error.Clock;
        host.io.delay(100);
    }
}
pub fn runOtaPreflight(clock: timers.Timer, image: []const u8, hash: [32]u8) OtaPreflight {
    host = .{ .io = .{ .clock = clock } };
    hosted_stream = .{ .host = &host };
    clock_failed = false;
    ota_preflight_stage = 0;
    clock.start();
    clock.disarm();
    defer clock.stop();
    return exerciseOtaPreflight(clock, image, hash) catch |err| blk: {
        for ("NIHOS_C6_PREFLIGHT_ERROR ") |byte| _ = nih_rom_putc(byte);
        for (@errorName(err)) |byte| _ = nih_rom_putc(byte);
        for ("\r\n") |byte| _ = nih_rom_putc(byte);
        break :blk .{ .error_code = @intFromError(err), .stage = ota_preflight_stage, .last_command = host.last_command, .last_interrupts = host.last_interrupts };
    };
}

/// Explicit single-use updater for the standalone P4 fixture. Never called by
/// normal network boot. The guard will not send Begin before the serial token.
pub const OtaUpdate = struct { status: u32 = 0, stage: u32 = 0, error_code: u32 = 0, acknowledged_bytes: u32 = 0 };
// SAFETY: the OTA entry points initialize the guard before use.
var ota_update_guard: hosted.ota_guard.Guard = undefined;
// SAFETY: the simulation path initializes this before use.
var ota_fake: hosted.ota_fake.Fake = undefined;
// SAFETY: the simulation path initializes this before use.
var ota_safe: hosted.ota_fake.NoOtaStream(@TypeOf(hosted_stream)) = undefined;
var ota_update_stage: u32 = 0;
fn printOtaHex(value: u32) void {
    const digits = "0123456789abcdef";
    for (0..8) |index| _ = nih_rom_putc(digits[(value >> @as(u5, @intCast(28 - index * 4))) & 15]);
}
noinline fn exerciseOtaUpdate(clock: timers.Timer, image: []const u8, hash: [32]u8) !OtaUpdate {
    const started = clock.counter() orelse return error.Clock;
    try ota_update_guard.initInPlace(image, hash, started, started + 600_000_000);
    const root = @import("root");
    const simulation = @hasDecl(root, "C6OtaSimulation") and root.C6OtaSimulation;
    ota_update_guard.session.allow_213 = @hasDecl(root, "C6OtaAllow213") and root.C6OtaAllow213;
    ota_update_guard.session.allow_310 = @hasDecl(root, "C6OtaAllow310") and root.C6OtaAllow310;
    if (@hasDecl(root, "C6OtaRequiredPeer")) ota_update_guard.session.required_peer = root.C6OtaRequiredPeer;
    if (simulation) {
        ota_fake = .{ .image = image };
        ota_safe = .{ .inner = &hosted_stream };
    }
    ota_update_stage = 1;
    nih_c6_pads_init();
    if (nih_c6_power_enable() != 1) return error.PowerEnable;
    host.io.delay(20_000);
    nih_c6_reset(1);
    host.io.delay(2_000_000);
    if (clock_failed) return error.Clock;
    ota_update_stage = 2;
    try host.prepare(true);
    ota_update_stage = 3;
    try host.identify();
    ota_update_stage = 4;
    try host.enableFunction();
    ota_update_stage = 5;
    try host.writeDoorbell(1, 0x8c, 1);
    ota_update_stage = 6;
    var announced = false;
    var progress: usize = 0;
    while (true) {
        const now = clock.counter() orelse return error.Clock;
        if (simulation) {
            if (ota_update_guard.state == .transfer) {
                try ota_update_guard.step(&ota_fake, now);
            } else {
                try ota_update_guard.step(&ota_safe, now);
            }
        } else {
            try ota_update_guard.step(&hosted_stream, now);
        }
        if (ota_update_guard.state == .awaiting_start) {
            if (!announced) {
                // Discard bounded stale input before advertising readiness.
                for (0..1024) |_| if (nih_c6_serial_read() < 0) break else {};
                if (simulation) {
                    ota_fake.explicit_activation = ota_update_guard.session.ota_client.activation == .explicit_rpc;
                    for ("NIHOS_C6_OTA_SIMULATED\r\n") |byte| _ = nih_rom_putc(byte);
                }
                if (@hasDecl(root, "C6OtaRequiredPeer")) {
                    const peer = &ota_update_guard.session.client;
                    for ("NIHOS_C6_OTA_ORIGIN chip=") |byte| _ = nih_rom_putc(byte);
                    printOtaHex(peer.peer_chip);
                    for (" major=") |byte| _ = nih_rom_putc(byte);
                    printOtaHex(peer.version[0]);
                    for (" minor=") |byte| _ = nih_rom_putc(byte);
                    printOtaHex(peer.version[1]);
                    for (" patch=") |byte| _ = nih_rom_putc(byte);
                    printOtaHex(peer.version[2]);
                    for ("\r\n") |byte| _ = nih_rom_putc(byte);
                }
                for ("NIHOS_C6_OTA_READY\r\n") |byte| _ = nih_rom_putc(byte);
                announced = true;
            }
            const byte = nih_c6_serial_read();
            if (byte >= 0) _ = try ota_update_guard.feed(@intCast(byte), now);
        }
        if (ota_update_guard.state == .transfer) {
            ota_update_stage = 7;
            if (ota_update_guard.session.transfer) |*transfer| {
                if (transfer.client.offset >= progress + 262144) {
                    progress = transfer.client.offset;
                    for ("NIHOS_C6_OTA_PROGRESS\r\n") |byte| _ = nih_rom_putc(byte);
                }
            }
        }
        if (ota_update_guard.state == .complete) {
            ota_update_stage = 8;
            // Hosted 1.4.1 schedules reboot five seconds after accepted End.
            if (simulation and (ota_fake.phase != .complete or ota_fake.offset != image.len)) return error.Malformed;
            for (0..if (simulation) @as(usize, 0) else 70) |_| {
                host.io.delay(100_000);
                if (clock_failed) return error.Clock;
            }
            return .{ .status = 1, .stage = ota_update_stage, .acknowledged_bytes = @intCast(image.len) };
        }
        if (clock_failed) return error.Clock;
        host.io.delay(100);
    }
}
pub fn runOtaUpdate(clock: timers.Timer, image: []const u8, hash: [32]u8) OtaUpdate {
    host = .{ .io = .{ .clock = clock } };
    hosted_stream = .{ .host = &host };
    clock_failed = false;
    ota_update_stage = 0;
    clock.start();
    clock.disarm();
    defer clock.stop();
    return exerciseOtaUpdate(clock, image, hash) catch |err| blk: {
        for ("NIHOS_C6_OTA_ERROR ") |byte| _ = nih_rom_putc(byte);
        for (@errorName(err)) |byte| _ = nih_rom_putc(byte);
        for ("\r\n") |byte| _ = nih_rom_putc(byte);
        const offset: u32 = if (ota_update_stage >= 7) (if (ota_update_guard.session.transfer) |*transfer| @intCast(transfer.client.offset) else 0) else 0;
        break :blk .{ .stage = ota_update_stage, .error_code = @intFromError(err), .acknowledged_bytes = offset };
    };
}
