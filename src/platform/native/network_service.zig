//! CPU0 normal-boot networking; shared host leases in the normal FS profile.
//! One FIFO chunk/TX per poll; DHCP maintenance and reset/backoff reconnect.
const options = @import("native_options");
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
const State = struct {
    time: TimeClient = .{},
    client: hosted.Client = .{},
    decoder: hosted.wire.Decoder = .{},
    configuration: hosted.Configuration = .{},
    ble: hosted.ble.Client = .{},
    ble_output: [32]u8 = @splat(0),
    ble_length: usize = 0,
};
pub const storage_bytes = (@sizeOf(State) + 63) & ~@as(usize, 63);
// SAFETY: begin binds these exclusively reserved CPU0 PSRAM objects before poll.
var client: *hosted.Client = undefined;
// SAFETY: begin binds this with client; neither object is passed to DMA.
var decoder: *hosted.wire.Decoder = undefined;
// SAFETY: begin binds the exclusive PSRAM state before the first active poll.
// Foreground-only reset templates share the already mapped read-only display tables.
// Keep large decoder/State defaults out of resident SRAM.
const initial_state linksection(".flash.rodata.display") = State{};
var state_storage: *State = undefined;
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
    @memcpy(@import("std").mem.asBytes(state), @import("std").mem.asBytes(&initial_state));
    client = &state.client;
    decoder = &state.decoder;
    clock = timer;
    configuration = &state.configuration;
    report = .{};
    configuration.set(join) catch return stop(error.InvalidArgument, null);
    failures = 0;
    test_renewed = false;
    test_reset = false;
    const now = clock.counter() orelse return stop(error.Clock, null);
    pads.useClock(clock);
    nih_c6_pads_init();
    if (nih_c6_power_enable() != 1 or pads.clockFailed()) return stop(error.PowerEnable, now);
    startAttempt(now);
}
fn startAttempt(now: u64) void {
    state_storage.time.disconnect();
    pads.useClock(clock);
    nih_c6_pads_init();
    host = .{ .io = .{ .clock = clock } };
    host_generation = 0;
    transport = .{ .host = &host };
    @memcpy(@import("std").mem.asBytes(client), @import("std").mem.asBytes(&initial_state.client));
    @memcpy(@import("std").mem.asBytes(decoder), @import("std").mem.asBytes(&initial_state.decoder));
    state_storage.ble = .{};
    state_storage.ble_length = 0;
    client.beginDual(configuration.get(), now, true);
    client.keep_serving = true;
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
fn stop(err: anyerror, now: ?u64) void {
    state_storage.time.disconnect();
    report.disconnect_reason = client.disconnect_reason;
    report.failed_station = @backingInt(client.phase);
    collectRenewals();
    report.error_code = @intFromError(err);
    report.failures +|= 1;
    transport.invalidate();
    @memcpy(@import("std").mem.asBytes(client), @import("std").mem.asBytes(&initial_state.client));
    @memcpy(@import("std").mem.asBytes(decoder), @import("std").mem.asBytes(&initial_state.decoder));
    state_storage.ble = .{};
    state_storage.ble_length = 0;
    nih_c6_reset(0);
    if (now == null or err == error.Clock or pads.clockFailed()) {
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
        client.beginDual(join, clock.counter() orelse return error.Clock, true);
        client.keep_serving = true;
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
    const count = try transport.receive(&rx);
    report.rx +|= @intCast(count);
    for (rx[0..count]) |byte| if (try decoder.push(byte)) |frame| {
        if (frame.interface == 4) state_storage.ble.receiveHosted(frame.packet_type, frame.payload, now);
        try client.receive(frame, clock.counter() orelse return error.Clock);
        collectRenewals();
        if (frame.interface == 1) {
            // DHCP expiry/disconnect is processed before exposing the frame.
            if (client.dhcp_client) |v4| if (v4.lease != null) state_storage.time.receive(frame.payload, now);
        }
    };
    const stamp = clock.counter() orelse return error.Clock;
    const ble = &state_storage.ble;
    if (ble.phase == .off and client.bluetooth_setup_done) ble.begin(if (client.bluetooth_ready) client.peer_capabilities else 0);
    ble.tick(stamp);
    if (stamp < client.started) return error.Clock;
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
    if (client.ipv6_client) |v6| {
        if (v6.slaac_valid and (stamp >= v6.valid_until or stamp >= v6.preferred_until)) return error.AddressExpired;
    }
    const bytes = try client.tx(stamp);
    if (bytes.len != 0) {
        const sent = try transport.send(bytes);
        if (sent != 0 and sent != bytes.len) return error.PartialPacket;
        if (sent != 0) client.sent(clock.counter() orelse return error.Clock);
        report.tx +|= @intCast(sent);
    } else {
        if (try timePoll(stamp)) return;
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
        }
    }
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
    if (client.dhcp_client) |v4| {
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
noinline fn timePoll(now: u64) linksection(".flash.text.time") !bool {
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
    var framed: [144]u8 = @splat(0);
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
pub fn timeSnapshot() hosted.sntp.Report {
    return state_storage.time.snapshot();
}
pub fn takeTime() ?hosted.sntp.Sample {
    const now = clock.counter() orelse return null;
    return state_storage.time.take(now);
}

pub fn releaseDmaForHost() u32 {
    return pads.releaseNormalDma();
}
