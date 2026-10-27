//! Opt-in CPU0 normal-boot integration. Owns both SDMMC slots exclusively.
//! One FIFO chunk/TX per poll; no SD access, IRQ handler, sockets or renewal.
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
const State = struct { client: hosted.Client = .{}, decoder: hosted.wire.Decoder = .{} };
pub const storage_bytes = (@sizeOf(State) + 63) & ~@as(usize, 63);
// SAFETY: begin binds these exclusively reserved CPU0 PSRAM objects before poll.
var client: *hosted.Client = undefined;
// SAFETY: begin binds this with client; neither object is passed to DMA.
var decoder: *hosted.wire.Decoder = undefined;
var rx: [512]u8 = @splat(0);
// SAFETY: begin binds the free-running UI timer before leaving the off phase.
var clock: timers.Timer = undefined;
var next: u64 = 0;
var limit: u64 = 0;
var phase: enum(u32) { off, power_wait, reset_wait, active, retired, failed } = .off;
var report: Report = .{};
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
};

/// CPU0 only, between display initialization and CPU1 release. The shared I2C
/// bus is idle here; its expander bits are preserved. Never reset SDMMC again.
pub fn begin(timer: timers.Timer, join: hosted.Join, backing: *align(64) [storage_bytes]u8) void {
    const state: *State = @ptrCast(backing);
    state.* = .{};
    client = &state.client;
    decoder = &state.decoder;
    clock = timer;
    pads.useClock(clock);
    host = .{ .io = .{ .clock = clock } };
    transport = .{ .host = &host };
    client.* = .{};
    decoder.* = .{};
    report = .{};
    const now = clock.counter() orelse return stop(error.Clock);
    nih_c6_pads_init();
    if (nih_c6_power_enable() != 1 or pads.clockFailed()) return stop(error.PowerEnable);
    client.beginDual(join, now, true);
    client.keep_serving = true;
    phase = .power_wait;
    next = now + 20_000;
    // This first integration intentionally retires after two minutes: DHCP
    // renewal and complete prefix lifetime maintenance are not implemented.
    limit = now + 120_000_000;
}
fn stop(err: anyerror) void {
    report.error_code = @intFromError(err);
    phase = .failed;
    transport.invalidate();
    client.* = .{};
    nih_c6_reset(0);
}
fn step(now: u64) !void {
    if (phase == .power_wait) {
        nih_c6_reset(1);
        phase = .reset_wait;
        next = now + 2_000_000;
        return;
    }
    if (phase == .reset_wait) {
        try host.prepare(true);
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
    const count = try transport.receive(&rx);
    report.rx +|= @intCast(count);
    for (rx[0..count]) |byte| if (try decoder.push(byte)) |frame| {
        try client.receive(frame, clock.counter() orelse return error.Clock);
    };
    const stamp = clock.counter() orelse return error.Clock;
    if (stamp < client.started) return error.Clock;
    // Retire before any advertised address expires; no stale address replies.
    if (client.dhcp_client) |lease_client| if (lease_client.lease) |lease| {
        if (lease.seconds <= 120 and stamp - client.started >= @as(u64, lease.seconds) * 1_000_000) return error.LeaseExpired;
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
    }
}
pub fn poll() void {
    if (phase == .off or phase == .failed or phase == .retired) return;
    const now = clock.counter() orelse return stop(error.Clock);
    if (now >= limit) {
        stop(error.SessionEnded);
        phase = .retired;
        return;
    }
    if (now < next) return;
    next = now + 2_000;
    report.polls +|= 1;
    step(now) catch |err| stop(err);
    const after = clock.counter() orelse return stop(error.Clock);
    if (after < now or pads.clockFailed()) return stop(error.Clock);
    report.max_poll_us = @max(report.max_poll_us, @as(u32, @intCast(@min(after - now, 0xffffffff))));
}
pub fn snapshot() Report {
    var result = report;
    result.phase = @backingInt(phase);
    result.station = @backingInt(client.phase);
    if (client.dhcp_client) |v4| if (v4.lease) |lease| {
        result.ip = lease.ip;
    };
    if (client.ipv6_client) |v6| {
        result.linklocal = @intFromBool(v6.ll_valid);
        result.echo_requests = v6.echo_requests;
    }
    return result;
}
