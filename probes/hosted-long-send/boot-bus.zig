//! Opt-in CPU0 diagnostic provider. All C6 traffic must use this single owner.
const adapter = @import("hosted_dma_bus");
const cache = @import("hosted_long_cache");
pub var buffer: adapter.Buffer = .{};
const udp = @import("long_udp_probe");
var framed: [udp.ethernet_bytes + 12]u8 = undefined;
var padding: [1536]u8 = undefined;
var rx: [512]u8 = undefined;
// These buffers are used only while arp_pending selects a 42-byte ARP reply.
var arp: [42]u8 = undefined;
var arp_frame: [54]u8 = undefined;
const Credit = struct {
    total: u32 = 0,
    available: u32 = 0,
    counter: u32 = 0,
    pub fn record(self: *@This(), total: u32, available: u32, counter: u32) void {
        self.* = .{ .total = total, .available = available, .counter = counter };
    }
};
pub const Trace = struct { credit: u32 = 0, timing: u32 = 0 };
pub var trace: [18]Trace = @splat(.{});
pub var tail_short_sent: u32 = 0;
pub var tail_short_ms: u32 = 0;
pub var before_17_mask: u32 = 0;
pub var before_17_ms: u32 = 0;
pub var staging_checked: u32 = 0;
pub var staging_matched: u32 = 0;
fn auditStaging(attempt: u8, packet: []const u8) void {
    const bit = @as(u32, 1) << @as(u5, @intCast(attempt - 1));
    staging_checked |= bit;
    if (udp.stagingMatches(packet, &buffer.data)) staging_matched |= bit;
}
fn recordSend(index: usize, credit: Credit, stalls: u8, before: u64, after: u64, origin: u64) !void {
    if (index >= trace.len or after < before or before < origin) return error.Clock;
    if (credit.total > 4095 or credit.counter > 4095 or credit.available == 0 or credit.available > 64) return error.CounterDiscontinuity;
    const elapsed: u32 = @intCast(@min((after - origin) / 1000, 65535));
    const duration: u32 = @intCast(@min(after - before, 65535));
    trace[index] = .{ .credit = credit.total | (credit.counter << 12) | (@as(u32, stalls) << 24), .timing = elapsed | (duration << 16) };
}

pub fn probe(stream: anytype, decoder: anytype, client: anytype, mac: [6]u8, ip: u32, comptime Config: type, sta: u8, frame: anytype, frameInPlace: anytype, clock: anytype, report: anytype) !void {
    defer report.long_dma_state = @backingInt(buffer.state);
    errdefer {
        buffer.retire();
        stream.invalidate();
    }
    // Explicit same-subnet peer and MAC avoid implicit gateway/ARP assumptions.
    if ((Config.udp_ip & report.netmask) != (ip & report.netmask)) return error.PeerNotLocal;
    report.long_burst = @intFromBool(Config.udp_burst);
    report.long_settle_ms = Config.udp_settle_ms;
    const ethernet: *[udp.ethernet_bytes]u8 = framed[12..][0..udp.ethernet_bytes];
    const short_packet = udp.sizedPacket(ethernet, mac, ip, Config.udp_mac, Config.udp_ip, Config.udp_port, 64);
    const short_frame = try frameInPlace(&framed, sta, 0x6fff, short_packet.len);
    const short_started = clock.counter() orelse return error.Clock;
    for (0..20_000) |_| {
        const sent = try stream.send(short_frame);
        if (sent != 0) {
            if (sent != short_frame.len) return error.PartialPacket;
            report.short_sent = @intCast(sent);
            report.tx +|= @intCast(sent);
            break;
        }
        const now = clock.counter() orelse return error.Clock;
        if (now < short_started or now - short_started > 2_000_000) return error.Timeout;
        stream.host.io.delay(100);
    } else return error.Timeout;
    const first_attempt: u8 = if (Config.udp_reverse) 16 else 1;
    const packet = udp.packetAttempt(ethernet, mac, ip, Config.udp_mac, Config.udp_ip, Config.udp_port, first_attempt);
    const bytes = try frameInPlace(&framed, sta, 0x7000, packet.len);
    report.long_logical = @intCast(bytes.len);
    report.long_wire = 1536;
    report.long_hash = udp.hash(bytes);
    const started = clock.counter() orelse return error.Clock;
    var stalls: u8 = 0;
    for (0..20_000) |_| {
        var credit: Credit = .{};
        const before = clock.counter() orelse return error.Clock;
        const sent = try stream.sendLongObserved(bytes, &padding, &credit);
        if (sent != 0) {
            if (sent != bytes.len) return error.PartialPacket;
            const after = clock.counter() orelse return error.Clock;
            try recordSend(0, credit, stalls, before, after, short_started);
            if (Config.udp_audit_staging) auditStaging(first_attempt, bytes);
            stalls = 0;
            report.long_sent = @intCast(sent);
            report.long_attempts +|= 1;
            report.tx +|= @intCast(sent);
            break;
        }
        stalls +|= 1;
        const now = clock.counter() orelse return error.Clock;
        if (now < started or now - started > 2_000_000) return error.Timeout;
        stream.host.io.delay(100);
    }
    if (report.long_sent == 0) return error.Timeout;
    const echo_started = clock.counter() orelse return error.Clock;
    const interval: u64 = if (Config.udp_burst) @as(u64, Config.udp_interval_ms) * 1000 else 1_000_000;
    const attempt_limit: u32 = if (Config.udp_burst) Config.udp_burst_count else 5;
    var next_retry = echo_started + interval;
    var last_send = echo_started;
    var tail_done = !Config.udp_tail_short;
    var sent_mask: u32 = @as(u32, 1) << @as(u5, @intCast(first_attempt - 1));
    for (0..200_000) |_| {
        const count = try stream.receive(&rx);
        report.rx +|= @intCast(count);
        for (rx[0..count]) |byte| if (try decoder.push(byte)) |incoming| {
            if (incoming.interface != sta) continue;
            switch (udp.matchEcho(incoming.payload, mac, ip, Config.udp_mac, Config.udp_ip, Config.udp_port)) {
                .short => report.short_echo +|= 1,
                .long => {
                    const attempt = incoming.payload[50];
                    if (attempt >= 1 and attempt <= attempt_limit and sent_mask & (@as(u32, 1) << @as(u5, @intCast(attempt - 1))) != 0) {
                        report.long_echo +|= 1;
                        report.long_echo_mask |= @as(u32, 1) << @as(u5, @intCast(attempt - 1));
                    }
                },
                .none => {},
            }
            if (incoming.payload.len >= 14 and incoming.payload[12] == 8 and incoming.payload[13] == 6)
                try client.dhcp_client.?.receiveAt(incoming.payload, clock.counter() orelse return error.Clock);
        };
        if (client.dhcp_client.?.arp_pending) {
            const reply = try client.dhcp_client.?.packet(&arp);
            const encoded = try frame(&arp_frame, sta, 0x7001, reply);
            const sent = try stream.send(encoded);
            if (sent != 0) {
                if (sent != encoded.len) return error.PartialPacket;
                client.dhcp_client.?.sent(clock.counter() orelse return error.Clock);
                report.echo_arp +|= 1;
            }
        }
        const now = clock.counter() orelse return error.Clock;
        if (report.short_echo != 0 and ((!Config.udp_burst and report.long_echo != 0) or
            (Config.udp_burst and tail_done and report.long_attempts == attempt_limit and now >= last_send and now - last_send >= @as(u64, Config.udp_settle_ms) * 1000)))
        {
            report.long_final_wait_ms = @intCast(@min((now - last_send) / 1000, 0xffffffff));
            return;
        }
        if (now < echo_started or now - echo_started > 20_000_000) return error.Timeout;
        if (!tail_done and report.long_attempts == attempt_limit and now >= last_send and now - last_send >= interval) {
            const marker = udp.sizedPacket(ethernet, mac, ip, Config.udp_mac, Config.udp_ip, Config.udp_port, 65);
            const marker_frame = try frameInPlace(&framed, sta, 0x7012, marker.len);
            const sent = try stream.send(marker_frame);
            if (sent != 0) {
                if (sent != marker_frame.len) return error.PartialPacket;
                const after = clock.counter() orelse return error.Clock;
                if (after < short_started) return error.Clock;
                tail_short_sent = @intCast(sent);
                tail_short_ms = @intCast(@min((after - short_started) / 1000, 0xffffffff));
                report.tx +|= @intCast(sent);
                tail_done = true;
            }
        }
        // Retry only after a fully completed write; never replay an ambiguous DMA failure.
        if (report.short_echo != 0 and (Config.udp_burst or report.long_echo == 0) and report.long_attempts < attempt_limit and now >= next_retry) {
            const attempt: u8 = @intCast(if (Config.udp_reverse) 16 - report.long_attempts else report.long_attempts + 1);
            const retry_packet = udp.packetAttempt(ethernet, mac, ip, Config.udp_mac, Config.udp_ip, Config.udp_port, attempt);
            const retry_frame = try frameInPlace(&framed, sta, 0x7000 + @as(u16, @intCast(report.long_attempts)), retry_packet.len);
            var credit: Credit = .{};
            const before = clock.counter() orelse return error.Clock;
            const sent = try stream.sendLongObserved(retry_frame, &padding, &credit);
            if (sent != 0) {
                if (sent != retry_frame.len) return error.PartialPacket;
                const after = clock.counter() orelse return error.Clock;
                if (Config.udp_pause_after_16 and report.long_attempts == 16) {
                    if (before < short_started) return error.Clock;
                    before_17_mask = report.long_echo_mask;
                    before_17_ms = @intCast(@min((before - short_started) / 1000, 0xffffffff));
                }
                try recordSend(report.long_attempts, credit, stalls, before, after, short_started);
                if (Config.udp_audit_staging) auditStaging(attempt, retry_frame);
                sent_mask |= @as(u32, 1) << @as(u5, @intCast(attempt - 1));
                stalls = 0;
                report.long_attempts += 1;
                report.tx +|= @intCast(sent);
                last_send = after;
            } else stalls +|= 1;
            next_retry = if (Config.udp_pause_after_16 and sent != 0 and report.long_attempts == 16)
                last_send + 2_000_000
            else
                now + interval;
        }
        stream.host.io.delay(100);
    }
    return error.Timeout;
}

pub fn C6Bus(comptime Short: type) type {
    return struct {
        routing: adapter.Bus(Short, cache.Rom) = .{ .short = .{}, .buffer = &buffer, .cache = .{ .ops = .{} } },
        pub fn setClock(self: *@This(), clock: anytype) void {
            self.routing.short.setClock(clock);
        }
        pub fn read(self: *@This(), address: usize) u32 {
            return self.routing.read(address);
        }
        pub fn write(self: *@This(), address: usize, value: u32) void {
            self.routing.write(address, value);
        }
        pub fn delay(self: *@This(), us: u32) void {
            self.routing.delay(us);
        }
        pub fn fourBitPins(self: *@This()) void {
            self.routing.fourBitPins();
        }
        pub fn prepareDma(self: *@This(), writing: bool, source: []const u8, length: usize) ?u32 {
            return self.routing.prepareDma(writing, source, length);
        }
        pub fn finishDma(self: *@This(), writing: bool, destination: []u8) bool {
            return self.routing.finishDma(writing, destination);
        }
    };
}
