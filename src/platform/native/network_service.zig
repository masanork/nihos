//! CPU0 normal-boot networking; shared host leases in the normal FS profile.
//! One FIFO chunk/TX per poll; DHCP maintenance and reset/backoff reconnect.
const options = @import("native_options");
const network_config = @import("network_config");
const shared_api = pads.shared_api;
const shared_host = @hasDecl(options, "normal_storage") and options.normal_storage;
var host_generation: u32 = 0;
const timers = @import("timer_group");
const pads = @import("c6_probe");
const sd = @import("sdio");
const stream = @import("c6_sdio");
const hosted = @import("hosted_station");
extern fn nih_c6_pads_init() callconv(.c) void;
extern fn nih_c6_power_enable() callconv(.c) u32;
extern fn nih_c6_reset(u32) callconv(.c) void;
var host = sd.Controller(pads.Bus){ .io = .{} };
var transport = stream.ProfileStream(@TypeOf(host), 64){ .host = &host };
const TimeClient = hosted.sntp.Engine(".flash.text.time");
const c6_offload = @hasDecl(network_config, "c6_time_offload") and network_config.c6_time_offload;
const time_fault_test = @hasDecl(network_config, "c6_time_fault_test") and network_config.c6_time_fault_test;
// Codegen-only experiment until TCP RX/TX and application ownership are wired.
const experimental_tcp = @hasDecl(options, "experimental_tcp") and options.experimental_tcp;
const experimental_udp = @hasDecl(options, "experimental_udp") and options.experimental_udp;
const udp_smoke_enabled = @hasDecl(options, "experimental_udp_smoke") and options.experimental_udp_smoke;
const TcpState = if (experimental_tcp) hosted.tcp_owner.Owner else void;
const UdpState = if (experimental_udp) hosted.udp_shared.Shared else void;
const UdpSmoke = if (udp_smoke_enabled) hosted.udp_smoke.Probe else void;
comptime {
    if (@alignOf(TcpState) > 64) @compileError("TCP owner exceeds network backing alignment");
    if (@alignOf(UdpState) > 64) @compileError("UDP owner exceeds network backing alignment");
    if (experimental_udp and (!c6_offload or experimental_tcp)) @compileError("UDP experiment requires C6 offload and excludes TCP experiment");
    if (udp_smoke_enabled and !experimental_udp) @compileError("UDP smoke requires the UDP experiment");
    if (@alignOf(UdpSmoke) > 64) @compileError("UDP smoke exceeds network backing alignment");
}
const Offload = if (c6_offload) hosted.c6_time_exchange.Exchange else void;
const State = struct {
    time: TimeClient = .{},
    client: hosted.Client = .{},
    offload: Offload = if (c6_offload) .{} else {},
    configuration: hosted.Configuration = .{},
    ble: hosted.ble.Client = .{},
    ble_output: [32]u8 = @splat(0),
    ble_length: usize = 0,
    decoder: hosted.wire.Decoder = .{},
};
const station_storage_bytes = (@sizeOf(State) + 63) & ~@as(usize, 63);
const udp_storage_bytes = if (experimental_udp) ((@sizeOf(UdpState) + 63) & ~@as(usize, 63)) else 0;
const udp_smoke_storage_bytes = if (udp_smoke_enabled) ((@sizeOf(UdpSmoke) + 63) & ~@as(usize, 63)) else 0;
pub const storage_bytes = station_storage_bytes + if (experimental_tcp) ((@sizeOf(TcpState) + 63) & ~@as(usize, 63)) else udp_storage_bytes + udp_smoke_storage_bytes;
// SAFETY: begin binds these exclusively reserved CPU0 PSRAM objects before poll.
var client: *hosted.Client = undefined;
// SAFETY: begin binds this with client; neither object is passed to DMA.
var decoder: *hosted.wire.Decoder = undefined;
// SAFETY: begin binds the exclusive PSRAM state before the first active poll.
// Foreground-only reset templates share the already mapped read-only display tables.
// Keep large decoder/State defaults out of resident SRAM.
const InitialTemplate = struct {
    time: TimeClient = .{},
    client: hosted.Client = .{},
    offload: Offload = if (c6_offload) .{} else {},
    configuration: hosted.Configuration = .{},
    ble: hosted.ble.Client = .{},
    ble_output: [32]u8 = @splat(0),
    ble_length: usize = 0,
};
const initial_state linksection(".flash.rodata.display") = InitialTemplate{};
// SAFETY: begin binds this before any foreground state access.
var state_storage: *State = undefined;
// SAFETY: experimental builds bind this CPU0-only tail before startAttempt.
var tcp_state: *TcpState = undefined;
// SAFETY: experimental builds bind this CPU0-only tail before startAttempt.
var udp_state: *UdpState = undefined;
// SAFETY: only smoke builds bind this separate, aligned PSRAM tail in begin.
var udp_smoke_state: *UdpSmoke = undefined;
var udp_error_code: u32 = 0;
var udp_dropped: u32 = 0;
var udp_invalid: u32 = 0;
var tcp_error_code: u32 = 0;
/// Last TCP scheduling or RX failure for experimental diagnostics; station errors remain
/// on the existing network report. No application socket API is exposed yet.
pub fn experimentalTcpError() u32 {
    return if (experimental_tcp) tcp_error_code else 0;
}
pub const ExperimentalUdpHandle = hosted.udp_socket.Handle;
pub const ExperimentalUdpReceived = hosted.udp_socket.Received;
pub const experimental_udp_max_payload = hosted.udp_shared.short_payload_limit;

/// CPU0-only, short-transfer experiment. The caller owns address resolution
/// and must serialize every call with poll(). Not an application socket API.
fn experimentalUdpNow() !u64 {
    if (!experimental_udp) return error.UdpDisabled;
    if (phase != .active or !offload_active or !client.connected or client.phase != .done) return error.NetworkUnavailable;
    if (client.peer_chip != 13 or !client.version_known or
        !@import("std").mem.eql(u32, &client.version, &.{ 3, 0, 10 }) or
        client.peer_rpc_version != 2 or client.peer_mode != 1 or client.peer_sdio_buffer_blocks == null) return error.UnsupportedPeer;
    return clock.counter() orelse error.Clock;
}
pub fn experimentalUdpBind(port: u16) !ExperimentalUdpHandle {
    if (comptime !experimental_udp) return error.UdpDisabled;
    _ = try experimentalUdpNow();
    const handle = try udp_state.bind(&state_storage.offload.addresses, client.mac_address, port, .{ .first = 49152, .last = 61439 });
    udp_error_code = 0;
    return handle;
}
pub fn experimentalUdpSend(handle: ExperimentalUdpHandle, peer: hosted.udp_ipv4.Endpoint, payload: []const u8, deadline_us: u64) !void {
    if (comptime !experimental_udp) return error.UdpDisabled;
    const now = try experimentalUdpNow();
    const std = @import("std");
    const ip = std.mem.readInt(u32, &peer.ip, .big);
    if (peer.port == 0 or peer.mac[0] & 1 != 0 or std.mem.allEqual(u8, &peer.mac, 0) or
        ip >> 24 == 0 or ip >> 24 == 127 or ip >> 24 >= 224 or ip >> 16 == 0xa9fe) return error.InvalidArgument;
    try udp_state.socket.sendTo(handle, peer, payload, client.sequence, now, deadline_us);
    client.sequence +%= 1;
}
pub fn experimentalUdpRead(handle: ExperimentalUdpHandle, out: []u8) !?ExperimentalUdpReceived {
    if (comptime !experimental_udp) return error.UdpDisabled;
    _ = try experimentalUdpNow();
    return udp_state.socket.read(handle, out);
}
pub fn experimentalUdpClose(handle: ExperimentalUdpHandle) !void {
    if (comptime !experimental_udp) return error.UdpDisabled;
    _ = try experimentalUdpNow();
    try udp_state.socket.close(handle);
}
pub fn experimentalUdpError() u32 {
    return if (experimental_udp) udp_error_code else 0;
}
pub fn experimentalUdpDrops() u32 {
    return if (experimental_udp) udp_dropped else 0;
}
pub fn experimentalUdpInvalid() u32 {
    return if (experimental_udp) udp_invalid else 0;
}
const UdpSmokeIo = struct {
    pub fn bind(_: *@This(), port: u16) !ExperimentalUdpHandle {
        return experimentalUdpBind(port);
    }
    pub fn send(_: *@This(), handle: ExperimentalUdpHandle, peer: hosted.udp_ipv4.Endpoint, data: []const u8, deadline: u64) !void {
        if (network_config.udp_smoke_ssid.len != 0) {
            if (udp_smoke_state.report.ssid_match == 0) return error.PeerSsidUnknown;
            if (udp_smoke_state.report.ssid_match != 1) return error.PeerSsidMismatch;
        }
        if (!@import("std").mem.allEqual(u8, &network_config.udp_smoke_bssid, 0)) {
            if (udp_smoke_state.report.ap_match == 0) return error.PeerAccessPointUnknown;
            if (udp_smoke_state.report.ap_match != 1) return error.PeerAccessPointMismatch;
        }
        const address = state_storage.offload.addresses.address orelse return error.NetworkUnavailable;
        if (!hosted.udp_smoke.directPeer(address.ip, address.mask, peer.ip)) return error.PeerNotDirect;
        return experimentalUdpSend(handle, peer, data, deadline);
    }
    pub fn read(_: *@This(), handle: ExperimentalUdpHandle, out: []u8) !?ExperimentalUdpReceived {
        return experimentalUdpRead(handle, out);
    }
    pub fn close(_: *@This(), handle: ExperimentalUdpHandle) !void {
        return experimentalUdpClose(handle);
    }
};
/// One bounded, explicit-peer diagnostic. It never executes in normal builds.
pub noinline fn experimentalUdpSmokePoll() linksection(".flash.xytext") void {
    if (comptime !udp_smoke_enabled) return;
    const now = clock.counter() orelse return;
    var io: UdpSmokeIo = .{};
    udp_smoke_state.step(&io, now);
}
pub fn experimentalUdpSmokeSnapshot() hosted.udp_smoke.Report {
    if (comptime !udp_smoke_enabled) return .{};
    var value = udp_smoke_state.snapshot();
    value.udp_error = udp_error_code;
    value.rx_dropped = udp_dropped;
    value.rx_invalid = udp_invalid;
    return value;
}
pub const ExperimentalTcpHandle = hosted.tcp_owner.Handle;
pub const ExperimentalSshAdapter = hosted.ssh_tcp.Adapter;

// Experimental CPU0-only interface. The caller must supply a securely chosen
// ephemeral port/sequence before production use and must serialize all calls
// with poll(). This is not exposed to xy and is disabled in normal builds.
fn experimentalTcpNow() !u64 {
    if (!experimental_tcp) return error.TcpDisabled;
    if (phase != .active or offload_active) return error.NetworkUnavailable;
    return clock.counter() orelse error.Clock;
}
pub fn experimentalTcpOpen(remote: [4]u8, remote_port: u16, local_port: u16, initial_seq: u32, deadline_us: u64) !ExperimentalTcpHandle {
    if (comptime !experimental_tcp) return error.TcpDisabled;
    const now = try experimentalTcpNow();
    return tcp_state.open(client, .{ .address = remote, .port = remote_port }, local_port, initial_seq, now, deadline_us / 1000);
}
pub fn experimentalTcpReady(handle: ExperimentalTcpHandle) !bool {
    if (comptime !experimental_tcp) return error.TcpDisabled;
    const now = try experimentalTcpNow();
    return tcp_state.ready(client, handle, now);
}
/// Zero indicates peer EOF; WouldBlock means no data is available yet.
pub fn experimentalTcpRead(handle: ExperimentalTcpHandle, out: []u8) !usize {
    if (comptime !experimental_tcp) return error.TcpDisabled;
    const now = try experimentalTcpNow();
    return tcp_state.read(client, handle, now, out);
}
/// The returned count is accepted into TCP, not acknowledged by the peer.
pub fn experimentalTcpWrite(handle: ExperimentalTcpHandle, bytes: []const u8, deadline_us: u64) !usize {
    if (comptime !experimental_tcp) return error.TcpDisabled;
    const now = try experimentalTcpNow();
    return tcp_state.write(client, handle, now, deadline_us / 1000, bytes);
}
/// CPU0 cancellation retires the handle without reusing its TCP tuple.
pub fn experimentalTcpCancel(handle: ExperimentalTcpHandle) !void {
    if (comptime !experimental_tcp) return error.TcpDisabled;
    _ = try experimentalTcpNow();
    try tcp_state.cancel(handle);
}
pub fn experimentalTcpCloseWrite(handle: ExperimentalTcpHandle, deadline_us: u64) !void {
    if (comptime !experimental_tcp) return error.TcpDisabled;
    const now = try experimentalTcpNow();
    return tcp_state.closeWrite(client, handle, now, deadline_us / 1000);
}
/// TCP close completion does not replace TIME_WAIT or permit port reuse.
pub fn experimentalTcpCloseComplete(handle: ExperimentalTcpHandle) !bool {
    if (comptime !experimental_tcp) return error.TcpDisabled;
    const now = try experimentalTcpNow();
    return tcp_state.closeComplete(client, handle, now);
}
/// The adapter borrows the CPU0 network owner. The caller must advance it
/// before each SSH pump poll and discard it after failure or network reset.
pub fn experimentalSshAdapter(handle: ExperimentalTcpHandle, write_timeout_ms: u64) !ExperimentalSshAdapter {
    if (comptime !experimental_tcp) return error.TcpDisabled;
    const now = try experimentalTcpNow();
    return ExperimentalSshAdapter.init(tcp_state, client, handle, now, write_timeout_ms);
}
/// Caller-owned SSH state must occupy stable, exclusive memory throughout its
/// lifetime. Credentials and cryptographic entropy remain caller-owned. This
/// API is CPU0-only, experimental, and not connected to xy.
pub const ExperimentalSshSession = hosted.ssh_session_owner.Owner;
pub fn experimentalSshSessionStart(backing: *ExperimentalSshSession, handle: ExperimentalTcpHandle, deadline_us: u64, write_timeout_ms: u64, secret: [32]u8, pin: [32]u8, cookie: [16]u8, cols: u32, rows: u32) !void {
    if (comptime !experimental_tcp) return error.TcpDisabled;
    const now = try experimentalTcpNow();
    if (deadline_us <= now or cols == 0 or rows == 0) return error.InvalidArgument;
    const adapter = try ExperimentalSshAdapter.init(tcp_state, client, handle, now, write_timeout_ms);
    backing.begin(adapter, now, deadline_us, secret, pin, cookie, cols, rows);
}
// The boot path binds this address only after PSRAM reservation admission.
// SAFETY: accessed only while reserved_ssh_slot is bound on CPU0.
var reserved_ssh: *ExperimentalSshSession = undefined;
var reserved_ssh_slot: hosted.ssh_reservation.Slot = .{};
/// Bind once during CPU0 boot, before begin and before any session exists.
pub fn bindExperimentalSshStorage(backing: *ExperimentalSshSession) !void {
    if (comptime !experimental_tcp) return error.TcpDisabled;
    try reserved_ssh_slot.bind();
    reserved_ssh = backing;
}
/// Only true after boot admitted and bound the experimental PSRAM region.
pub fn experimentalSshStorageBound() bool {
    return experimental_tcp and reserved_ssh_slot.bound;
}
/// The returned address is exclusively borrowed until release, including after
/// a network reset. The owner must not copy it or retain it after release.
pub fn experimentalSshReservedStart(handle: ExperimentalTcpHandle, deadline_us: u64, write_timeout_ms: u64, secret: [32]u8, pin: [32]u8, cookie: [16]u8, cols: u32, rows: u32) !*ExperimentalSshSession {
    if (comptime !experimental_tcp) return error.TcpDisabled;
    try reserved_ssh_slot.checkAvailable();
    try experimentalSshSessionStart(reserved_ssh, handle, deadline_us, write_timeout_ms, secret, pin, cookie, cols, rows);
    reserved_ssh_slot.claim();
    return reserved_ssh;
}
pub fn experimentalSshReservedRelease(backing: *ExperimentalSshSession) !void {
    if (comptime !experimental_tcp) return error.TcpDisabled;
    if (!reserved_ssh_slot.bound or !reserved_ssh_slot.owned or backing != reserved_ssh) return error.InvalidArgument;
    revokeReservedSsh();
    try reserved_ssh_slot.release();
}
// Keep the borrow reserved until explicit release, so reset cannot hand its
// storage to a second caller while the first caller still has a pointer.
fn revokeReservedSsh() void {
    if (experimental_tcp and reserved_ssh_slot.revoke()) reserved_ssh.abort();
}
/// Use the same monotonic source for session poll/read/write. The caller must
/// continue polling the network owner between SSH operations, and must abort
/// the session if this clock becomes unavailable or on cancellation.
pub fn experimentalSshSessionNow() !u64 {
    return experimentalTcpNow();
}
var rx: [512]u8 = @splat(0);
// SAFETY: begin binds the free-running UI timer before leaving the off phase.
var clock: timers.Timer = undefined;
var next: u64 = 0;
var limit: u64 = 0;
var phase: enum(u32) { off, power_wait, reset_wait, active, backoff, failed } = .off;
var report: Report = .{};
// SAFETY: begin binds the owned configuration before starting the transport.
var configuration: *hosted.Configuration = undefined;
var failures: u8 = 0;
var ready_at: ?u64 = null;
var attempt_bound = false;
var counted_renewals: u32 = 0;
var test_renewed = false;
var test_reset = false;
var offload_active = false;
var offload_epoch: u64 = 1;
var offload_due: u64 = 0;
var offload_sample: ?hosted.sntp.Sample = null;
pub const TimeFaultReport = extern struct { stage: u32 = 0, dropped: u32 = 0, expired: u32 = 0 };
var time_fault: TimeFaultReport = .{};
pub fn timeFaultSnapshot() TimeFaultReport {
    return time_fault;
}
var offload_report: hosted.sntp.Report = .{ .phase = 0, .attempts = 0, .replies = 0, .rejected = 0, .failures = 0, .server = 0, .stratum = 0, .rtt_us = 0, .unix_high = 0, .unix_low = 0 };
pub const Report = extern struct {
    phase: u32 = 0,
    station: u32 = 0,
    error_code: u32 = 0,
    ip: u32 = 0,
    linklocal: u32 = 0,
    echo_requests: u32 = 0,
    rx: u32 = 0,
    tx: u32 = 0,
    polls: u32 = 0,
    max_poll_us: u32 = 0,
    renewals: u32 = 0,
    reconnects: u32 = 0,
    acquisitions: u32 = 0,
    failures: u32 = 0,
    disconnect_reason: u32 = 0,
    failed_station: u32 = 0,
    configured: u32 = 0,
    capabilities: u32 = 0,
    bluetooth_status: u32 = 0,
};

/// CPU0 only, between display initialization and CPU1 release. The shared I2C
/// bus is idle here; its expander bits are preserved. Shared-mode reconnect
/// changes only C6 pads/reset; the common owner alone resets SDMMC.
pub fn begin(timer: timers.Timer, join: hosted.Join, backing: *align(64) [storage_bytes]u8) void {
    const state: *State = @ptrCast(backing);
    state_storage = state;
    if (experimental_tcp) {
        tcp_state = @ptrFromInt(@intFromPtr(backing) + station_storage_bytes);
        tcp_state.init();
        tcp_error_code = 0;
    }
    if (experimental_udp) {
        udp_state = @ptrFromInt(@intFromPtr(backing) + station_storage_bytes);
        udp_state.init();
        udp_error_code = 0;
        udp_dropped = 0;
        udp_invalid = 0;
    }
    if (udp_smoke_enabled) {
        udp_smoke_state = @ptrFromInt(@intFromPtr(backing) + station_storage_bytes + udp_storage_bytes);
        udp_smoke_state.* = .{};
    }
    @memcpy(@import("std").mem.asBytes(state)[0..@sizeOf(InitialTemplate)], @import("std").mem.asBytes(&initial_state));
    state.decoder.reset();
    client = if (c6_offload) &state.offload.station else &state.client;
    decoder = &state.decoder;
    clock = timer;
    configuration = &state.configuration;
    report = .{};
    configuration.set(join) catch return stop(error.InvalidArgument, null);
    failures = 0;
    test_renewed = false;
    test_reset = false;
    offload_epoch = 1;
    offload_sample = null;
    time_fault = .{};
    offload_report = .{ .phase = 0, .attempts = 0, .replies = 0, .rejected = 0, .failures = 0, .server = 0, .stratum = 0, .rtt_us = 0, .unix_high = 0, .unix_low = 0 };
    const now = clock.counter() orelse return stop(error.Clock, null);
    if (udp_smoke_enabled) udp_smoke_state.start(.{
        .ip = network_config.udp_smoke_ip,
        .mac = network_config.udp_smoke_mac,
        .port = network_config.udp_smoke_port,
    }, now, now +| 120_000_000) catch return stop(error.InvalidArgument, now);
    pads.useClock(clock);
    nih_c6_pads_init();
    if (nih_c6_power_enable() != 1 or pads.clockFailed()) return stop(error.PowerEnable, now);
    startAttempt(now);
}
// Foreground-only reconnect path; Flash is mapped before network begin.
noinline fn startAttempt(now: u64) linksection(if (@hasDecl(options, "xy_workspace") and options.xy_workspace) ".flash.xytext" else ".text") void {
    if (experimental_tcp) revokeReservedSsh();
    if (experimental_udp) udp_state.init();
    if (experimental_tcp) tcp_state.reset() catch {
        phase = .failed;
        return;
    };
    state_storage.time.disconnect();
    pads.useClock(clock);
    nih_c6_pads_init();
    host = .{ .io = .{ .clock = clock } };
    host_generation = 0;
    transport = .{ .host = &host };
    @memcpy(@import("std").mem.asBytes(client), @import("std").mem.asBytes(&initial_state.client));
    decoder.reset();
    state_storage.ble = .{};
    state_storage.ble_length = 0;
    offload_active = c6_offload and configuration.mode != .disabled;
    offload_sample = null;
    if (c6_offload and offload_active) {
        offload_epoch = @max(offload_epoch, state_storage.offload.addresses.generation) +| 1;
        state_storage.offload.begin(configuration.get(), offload_epoch, now, now +| 100_000_000) catch return stop(error.Stale, now);
        offload_due = now;
        offload_report.phase = @backingInt(hosted.sntp.Phase.waiting);
    } else {
        client.beginDual(configuration.get(), now, network_config.ipv6);
        client.keep_serving = true;
    }
    attempt_bound = false;
    counted_renewals = 0;
    ready_at = null;
    report.error_code = 0;
    phase = .power_wait;
    next = now + 20_000;
    limit = now + 100_000_000;
}
fn collectRenewals() void {
    if (client.dhcp_client) |v4| {
        report.renewals +|= v4.renewals -| counted_renewals;
        counted_renewals = v4.renewals;
    }
}
noinline fn stop(err: anyerror, now: ?u64) linksection(if (@hasDecl(options, "xy_workspace") and options.xy_workspace) ".flash.xytext" else ".text") void {
    if (experimental_tcp) revokeReservedSsh();
    if (experimental_udp) {
        udp_state.socket.invalidate();
        udp_state.retired = true;
    }
    const tcp_reset_failed = if (experimental_tcp) blk: {
        tcp_state.reset() catch break :blk true;
        break :blk false;
    } else false;
    state_storage.time.disconnect();
    offload_sample = null;
    if (c6_offload and offload_active) state_storage.offload.invalidate();
    report.disconnect_reason = client.disconnect_reason;
    report.failed_station = @backingInt(client.phase);
    collectRenewals();
    report.error_code = @intFromError(err);
    report.failures +|= 1;
    transport.invalidate();
    @memcpy(@import("std").mem.asBytes(client), @import("std").mem.asBytes(&initial_state.client));
    decoder.reset();
    state_storage.ble = .{};
    state_storage.ble_length = 0;
    nih_c6_reset(0);
    if (tcp_reset_failed or now == null or err == error.Clock or pads.clockFailed()) {
        phase = .failed;
        return;
    }
    // Retry indefinitely with bounded delay and no retained addresses/output.
    const seconds: u64 = @min(@as(u64, 60), @as(u64, 1) << @as(u6, @intCast(@min(failures, 6))));
    failures +|= 1;
    phase = .backoff;
    next = now.? +| (seconds * 1_000_000);
}
noinline fn step(now: u64) linksection(".flash.text.time") !void {
    if (phase == .power_wait) {
        nih_c6_reset(1);
        phase = .reset_wait;
        next = now + 2_000_000;
        return;
    }
    if (phase == .reset_wait) {
        if (shared_host) try host.prepareShared() else try host.prepare(true);
        if (shared_host) host_generation = shared_api.generation();
        try host.identify();
        try host.enableFunction();
        try host.writeDoorbell(1, 0x8c, 1);
        // RPC timeouts start after enumeration, not during C6 reset.
        const join = client.join;
        const start = clock.counter() orelse return error.Clock;
        if (c6_offload and offload_active) {
            try state_storage.offload.begin(join, offload_epoch, start, start +| 100_000_000);
        } else {
            client.beginDual(join, start, network_config.ipv6);
            client.keep_serving = true;
        }
        phase = .active;
        return;
    }
    if (options.network_test and !test_reset) if (ready_at) |since| {
        if (now - since >= 40_000_000) {
            test_reset = true;
            return error.TestDisconnect;
        }
    };
    if (now >= limit and client.phase != .done) return error.Timeout;
    if (c6_offload and offload_active) try recoverC6TimeTimeout(now);
    const count = try transport.receive(&rx);
    report.rx +|= @intCast(count);
    for (rx[0..count]) |byte| if (try decoder.push(byte)) |frame| {
        if (frame.interface == 4) state_storage.ble.receiveHosted(frame.packet_type, frame.payload, now);
        if (udp_smoke_enabled and frame.interface == 3) {
            const event = hosted.wire.rpc(frame.payload) catch null;
            if (event) |rpc| if (rpc.kind == 3) {
                if (rpc.id == 775) {
                    udp_smoke_state.report.ap_match = hosted.udp_smoke.compareApEvent(rpc.body, network_config.udp_smoke_bssid);
                    udp_smoke_state.report.ssid_match = hosted.udp_smoke.compareSsidEvent(rpc.body, &network_config.udp_smoke_ssid);
                }
                if (rpc.id == 776) {
                    udp_smoke_state.report.ap_match = 0;
                    udp_smoke_state.report.ssid_match = 0;
                }
            };
        }
        const received = clock.counter() orelse return error.Clock;
        if (c6_offload and offload_active) {
            try recoverC6TimeTimeout(received);
            // Explicit test image only: drop the first time RPC's response,
            // leaving unrelated station and BLE traffic untouched.
            if (time_fault_test and time_fault.stage == 1 and frame.interface == 3) {
                const rpc = try hosted.wire.rpc(frame.payload);
                if ((rpc.kind == 2 and rpc.id == 644) or (rpc.kind == 3 and rpc.id == 788)) {
                    time_fault.dropped +|= 1;
                    continue;
                }
            }
            try state_storage.offload.receive(frame, received);
            try finishC6Time(received);
            if (experimental_udp) try udpReceive(frame);
        } else {
            try client.receive(frame, received);
            if (experimental_tcp) tcpReceive(frame, received);
        }
        collectRenewals();
        if (!offload_active and frame.interface == 1) {
            // DHCP expiry/disconnect is processed before exposing the frame.
            if (client.dhcp_client) |v4| if (v4.lease != null) state_storage.time.receive(frame.payload, now);
        }
    };
    const stamp = clock.counter() orelse return error.Clock;
    const ble = &state_storage.ble;
    if (ble.phase == .off and client.bluetooth_setup_done) ble.begin(if (client.bluetooth_ready) client.peer_capabilities else 0);
    ble.tick(stamp);
    if (stamp < client.started) return error.Clock;
    if (c6_offload and offload_active and state_storage.offload.addresses.address != null) {
        if (!attempt_bound) {
            attempt_bound = true;
            report.acquisitions +|= 1;
        }
        if (ready_at == null) ready_at = stamp;
        if (ready_at) |since| if (stamp - since >= 30_000_000) {
            failures = 0;
        };
    }
    if (client.dhcp_client) |*v4| if (v4.lease != null) {
        if (!attempt_bound) {
            attempt_bound = true;
            report.acquisitions +|= 1;
        }
        if (client.phase == .done and ready_at == null) ready_at = stamp;
        if (ready_at) |since| {
            if (stamp - since >= 30_000_000) failures = 0;
            if (options.network_test and !test_renewed and stamp - since >= 10_000_000) {
                v4.requestRenewal(stamp);
                test_renewed = true;
            }
        }
    };
    if (c6_offload and offload_active) try recoverC6TimeTimeout(stamp);
    const bytes = if (c6_offload and offload_active)
        if (state_storage.offload.phase == .ready and stamp < offload_due) &.{} else try state_storage.offload.tx(stamp)
    else
        try client.tx(stamp);
    // Age an unsent UDP deadline even while another producer has priority.
    if (experimental_udp and offload_active) _ = try udpPoll(stamp, count == 0, bytes.len != 0, true);
    // A previously staged TCP packet owns the next whole Hosted send, even
    // when station maintenance has since become ready.
    if (experimental_tcp and !offload_active and try tcpPoll(stamp, bytes.len != 0, true)) return;
    if (bytes.len != 0) {
        const sent = try transport.send(bytes);
        if (sent != 0 and sent != bytes.len) return error.PartialPacket;
        if (sent != 0) {
            const sent_at = clock.counter() orelse return error.Clock;
            if (c6_offload and offload_active) {
                if (state_storage.offload.phase == .queued) offload_report.attempts +|= 1;
                try state_storage.offload.sent(sent, sent_at);
                if (time_fault_test and time_fault.stage == 0 and state_storage.offload.phase == .waiting) {
                    time_fault.stage = 1;
                    state_storage.offload.deadline = sent_at +| 3_000_000;
                }
            } else client.sent(sent_at);
        }
        report.tx +|= @intCast(sent);
    } else {
        if (!offload_active and try timePoll(stamp)) return;
        if (state_storage.ble_length == 0) {
            const command = ble.tx(stamp);
            if (command.len != 0) {
                const packet = try hosted.wire.typedFrame(&state_storage.ble_output, 4, client.sequence, 1, command);
                client.sequence +%= 1;
                state_storage.ble_length = packet.len;
            }
        }
        if (state_storage.ble_length != 0) {
            const sent = try transport.send(state_storage.ble_output[0..state_storage.ble_length]);
            if (sent != 0 and sent != state_storage.ble_length) return error.PartialPacket;
            if (sent != 0) {
                state_storage.ble_length = 0;
                ble.sent(clock.counter() orelse return error.Clock);
                report.tx +|= @intCast(sent);
            }
        } else if (experimental_tcp and !offload_active) {
            _ = try tcpPoll(stamp, false, false);
        } else if (experimental_udp and offload_active) {
            _ = try udpPoll(stamp, count == 0, false, false);
        }
    }
}

// Deliberately denies long DMA in this profile, even if a caller bypasses the
// 458-byte socket admission limit. No DMA buffer or peer long-frame contract
// is established by the normal network provider.
const ShortUdpStream = struct {
    stream: *@TypeOf(transport),
    pub fn send(self: *@This(), bytes: []const u8) !usize {
        return self.stream.send(bytes);
    }
    pub fn sendLong(_: *@This(), _: []const u8, _: *[1536]u8) !usize {
        return error.LongUdpDisabled;
    }
    pub fn invalidate(self: *@This()) void {
        self.stream.invalidate();
    }
};

noinline fn udpReceive(frame: hosted.wire.Frame) linksection(".flash.xytext") !void {
    if (!experimental_udp) return;
    const handle = udp_state.socket.current orelse return;
    const result = try udp_state.receiveProcessed(handle, frame);
    if (result == .dropped) udp_dropped +|= 1;
    if (result == .invalid) udp_invalid +|= 1;
}

noinline fn udpPoll(now: u64, drained: bool, station_pending: bool, other_pending: bool) linksection(".flash.xytext") !bool {
    if (!experimental_udp) return false;
    const handle = udp_state.socket.current orelse return false;
    const length = if (udp_state.socket.sender) |*value| value.length else 0;
    var short: ShortUdpStream = .{ .stream = &transport };
    const result = udp_state.poll(handle, &short, decoder, now, drained, station_pending, other_pending) catch |err| {
        udp_error_code = @intFromError(err);
        if (err == error.Deadline) return false;
        return err;
    };
    if (udp_smoke_enabled and length != 0) {
        const diag = &udp_smoke_state.report;
        if (result == .sent) {
            diag.sent +|= 1;
        } else if (result == .pending) {
            diag.pending +|= 1;
            if (station_pending or other_pending) diag.blocked +|= 1;
            if (!drained) diag.undrained +|= 1;
            if (decoder.used != 0) diag.decoder_busy +|= 1;
        }
    }
    if (result == .sent) report.tx +|= @intCast(length);
    return result == .sent;
}

noinline fn tcpReceive(frame: hosted.wire.Frame, now: u64) linksection(".flash.xytext") void {
    if (!experimental_tcp) return;
    _ = tcp_state.receiveProcessed(client, frame, now) catch |err| blk: {
        tcp_error_code = @intFromError(err);
        break :blk false;
    };
}

// Called only inside the CPU0/shared-host lease. The transport borrows no
// owner buffer after send returns; zero credits leave the staged frame intact.
noinline fn tcpPoll(now: u64, station_pending: bool, other_pending: bool) linksection(".flash.xytext") !bool {
    if (!experimental_tcp) return false;
    const bytes = (tcp_state.nextTcp(client, now, station_pending, other_pending) catch |err| {
        tcp_error_code = @intFromError(err);
        return false;
    }) orelse return false;
    const sent = try transport.send(bytes);
    if (sent != 0 and sent != bytes.len) {
        tcp_state.sent(client, sent, now) catch |err| {
            tcp_error_code = @intFromError(err);
        };
        return error.PartialPacket;
    }
    const sent_at = if (sent != 0) clock.counter() orelse return error.Clock else now;
    try tcp_state.sent(client, sent, sent_at);
    report.tx +|= @intCast(sent);
    return true;
}
pub fn poll() void {
    if (phase == .off or phase == .failed) return;
    const now = clock.counter() orelse return stop(error.Clock, null);
    if (now < next) return;
    if (phase == .backoff) {
        report.reconnects +|= 1;
        startAttempt(now);
        return;
    }
    if (shared_host and host_generation != 0 and host_generation != shared_api.generation()) return stop(error.HostReset, now);
    const lease: ?shared_api.Lease = if (shared_host) shared_api.acquire(1) catch |err| {
        if (err == error.Busy) return;
        return stop(error.SharedHostUnavailable, now);
    } else null;
    if (lease) |held| host.io.lease = held;
    defer if (lease) |held| {
        const released = shared_api.release(held);
        host.io.lease = .{};
        if (released != .clean) stop(error.SharedHostFence, now);
    };
    next = now + 2_000;
    report.polls +|= 1;
    step(now) catch |err| stop(err, now);
    collectRenewals();
    const after = clock.counter() orelse return stop(error.Clock, null);
    if (after < now or pads.clockFailed()) return stop(error.Clock, null);
    report.max_poll_us = @max(report.max_poll_us, @as(u32, @intCast(@min(after - now, 0xffffffff))));
}
pub fn snapshot() Report {
    var result = report;
    result.phase = @backingInt(phase);
    result.station = @backingInt(client.phase);
    result.configured = @intFromBool(configuration.mode != .disabled);
    result.capabilities = client.peer_capabilities;
    result.bluetooth_status = client.bluetooth_status;
    if (c6_offload and offload_active) {
        if (state_storage.offload.addresses.address) |address| result.ip = address.ip;
    } else if (client.dhcp_client) |v4| {
        if (v4.lease) |lease| result.ip = lease.ip;
    }
    if (client.ipv6_client) |v6| {
        result.linklocal = @intFromBool(v6.ll_valid);
        result.echo_requests = v6.echo_requests;
    }
    return result;
}
pub fn bluetoothSnapshot() hosted.ble.Report {
    return state_storage.ble.snapshot();
}

/// CPU0 only. Starts another bounded discovery session after the previous one.
pub fn scanBluetooth() !void {
    if (phase != .active or client.priv_events == 0) return error.NotStarted;
    if (state_storage.ble.phase != .idle and state_storage.ble.phase != .failed) return error.Busy;
    state_storage.ble_length = 0;
    state_storage.ble.begin(client.peer_capabilities);
}

/// CPU0 settings-service entry point. Replaces credentials atomically after
/// validation and revokes all addresses/output by starting a fresh C6 epoch.
pub fn configure(join: hosted.Join) !void {
    if (phase == .off) return error.NotStarted;
    try configuration.set(join);
    const now = clock.counter() orelse return error.Clock;
    nih_c6_reset(0);
    startAttempt(now);
}

/// Called after the station's own tx() maintenance. Shares its monotonic epoch;
/// DNS/NTP failures stay local and never reset C6 or revoke the DHCP lease.
// Foreground network work can share the mapped xy Flash page. Keep the boot
// page for startup and PMP, including in the standard connected xy image.
noinline fn timePoll(now: u64) linksection(if (experimental_tcp or (@hasDecl(options, "xy_workspace") and options.xy_workspace)) ".flash.xytext" else ".flash.text.time") !bool {
    const v4 = client.dhcp_client orelse {
        state_storage.time.disconnect();
        return false;
    };
    const lease = v4.lease orelse {
        state_storage.time.disconnect();
        return false;
    };
    state_storage.time.bind(client.mac_address, lease, now);
    const ethernet = state_storage.time.tx(now);
    if (ethernet.len == 0) return false;
    // At most 128 Ethernet bytes. This CPU stack packet is copied by the
    // existing bounded transport; it is not lent to a DMA engine.
    // frame() initializes the complete returned header and payload.
    var framed: [144]u8 = undefined;
    const packet = try hosted.wire.frame(&framed, 1, client.sequence, ethernet);
    const sent = try transport.send(packet);
    if (sent != 0 and sent != packet.len) return error.PartialPacket;
    if (sent != 0) {
        client.sequence +%= 1;
        state_storage.time.sent(clock.counter() orelse return error.Clock);
        report.tx +|= @intCast(sent);
    }
    return true;
}
/// A missing time response must not reset an otherwise healthy station.
/// Retired IDs remain distinct, so late time frames can be safely ignored.
noinline fn recoverC6TimeTimeout(now: u64) linksection(".flash.text.time") !void {
    if (!c6_offload or !offload_active) return;
    const retry = now +| hosted.c6_time_policy.retry_unavailable;
    if (try state_storage.offload.retireTimedOutTime(now, retry +| 100_000_000)) {
        offload_report.failures +|= 1;
        if (time_fault_test and time_fault.stage == 1) {
            time_fault.stage = 2;
            time_fault.expired +|= 1;
        }
        offload_sample = null;
        offload_due = retry;
    }
}
/// Publish only a current, correlated C6 sample. SNTP itself is unauthenticated.
fn finishC6Time(now: u64) !void {
    if (!c6_offload or !offload_active) return;
    const exchange = &state_storage.offload;
    if (exchange.phase != .done) return;
    const decision = hosted.c6_time_policy.decide(exchange.sample, now);
    if (decision.sample) |sample| {
        offload_sample = sample;
        offload_report.replies +|= 1;
        const seconds = sample.unix_us / 1_000_000;
        offload_report.unix_high = @truncate(seconds >> 32);
        offload_report.unix_low = @truncate(seconds);
    } else if (decision.rejected) offload_report.rejected +|= 1;
    try exchange.nextSnapshot(now);
    offload_due = now +| decision.delay;
    exchange.deadline = offload_due +| 100_000_000;
}
pub fn timeSnapshot() hosted.sntp.Report {
    if (c6_offload and offload_active) return offload_report;
    return state_storage.time.snapshot();
}
pub fn takeTime() ?hosted.sntp.Sample {
    const now = clock.counter() orelse return null;
    if (c6_offload and offload_active) {
        return hosted.c6_time_policy.take(&offload_sample, now, state_storage.offload.addresses.current(state_storage.offload.clock.generation) != null);
    }
    return state_storage.time.take(now);
}

pub fn releaseDmaForHost() u32 {
    return pads.releaseNormalDma();
}
