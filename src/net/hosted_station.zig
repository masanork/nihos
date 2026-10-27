//! Single-flight factory-Hosted station boot experiment. Keeps credentials
//! volatile, correlates RPC UID + ID, and requires an actual DHCP ACK.
const std = @import("std");
pub const wire = @import("hosted.zig");
pub const dhcp = @import("dhcp.zig");
pub const ipv6 = @import("ipv6.zig");
pub const Join = union(enum) { saved, network: struct { ssid: []const u8, password: []const u8 } };
pub const Phase = enum { handshake, version, init_wifi, storage, mode, start, ps, mac, config, connect, link, lease, done, failed };
pub const Error = wire.Error || dhcp.Error || ipv6.Error || error{ Timeout, Disconnected, InvalidArgument };
pub const Client = struct {
    join: Join = .saved,
    phase: Phase = .handshake,
    capabilities_pending: bool = false,
    active_id: ?u32 = null,
    uid: u32 = 0,
    sequence: u16 = 0,
    output: [512]u8 = @splat(0),
    output_len: usize = 0,
    transmitted: bool = false,
    started: u64 = 0,
    deadline: u64 = 0,
    connected: bool = false,
    disconnect_reason: u32 = 0,
    version: [3]u32 = @splat(0),
    version_known: bool = false,
    ignored_rpcs: u32 = 0,
    rpc_status: u32 = 0,
    last_response: u32 = 0,
    frames: u32 = 0,
    malformed_network: u32 = 0,
    mac_address: [6]u8 = @splat(0),
    dhcp_client: ?dhcp.Client = null,
    priv_events: u32 = 0,
    peer_chip: u32 = 0,
    peer_mode: u32 = 255,
    peer_version: u32 = 0,
    ipv6_enabled: bool = false,
    ipv6_client: ?ipv6.Client = null,
    tx_ipv6: bool = false,
    /// Opt-in integration path; owner must bound session/address lifetime.
    keep_serving: bool = false,

    pub fn begin(self: *Client, join: Join, now: u64) void {
        self.beginDual(join, now, false);
    }
    pub fn beginDual(self: *Client, join: Join, now: u64, enable_ipv6: bool) void {
        self.* = .{ .join = join, .started = now, .deadline = now + 5_000_000, .ipv6_enabled = enable_ipv6 };
    }
    pub fn receive(self: *Client, frame: wire.Frame, now: u64) Error!void {
        self.frames +|= 1;
        if (frame.interface >> 4 != 0) return;
        switch (frame.interface & 15) {
            5 => {
                if (frame.payload.len < 2 or frame.payload[0] != 0x22) return;
                if (frame.payload[1] != frame.payload.len - 2) return error.Malformed;
                var pos: usize = 2;
                var chip_seen = false;
                while (pos < frame.payload.len) {
                    if (frame.payload.len - pos < 2) return error.Malformed;
                    const tag = frame.payload[pos];
                    const length = frame.payload[pos + 1];
                    pos += 2;
                    if (length > frame.payload.len - pos) return error.Malformed;
                    const value = frame.payload[pos..][0..length];
                    pos += length;
                    switch (tag) {
                        0x12 => {
                            if (length != 1 or chip_seen or value[0] != 13) return error.Malformed;
                            self.peer_chip = value[0];
                            chip_seen = true;
                        },
                        0x17 => {
                            if (length != 4) return error.Malformed;
                            self.peer_version = std.mem.readInt(u32, value[0..4], .little);
                        },
                        0x18 => {
                            if (length != 1 or value[0] != 1) return error.Malformed;
                            self.peer_mode = value[0];
                        },
                        else => {},
                    }
                }
                if (!chip_seen) return error.Malformed;
                self.priv_events +|= 1;
                if (self.phase != .handshake or self.capabilities_pending) return error.Malformed;
                self.capabilities_pending = true;
            },
            3 => {
                const response = try wire.rpc(frame.payload);
                if (response.kind == 3) {
                    if (response.id == 775) self.connected = true;
                    if (response.id == 776) {
                        self.connected = false;
                        const details = (try wire.data(response.body, 2)) orelse return error.Malformed;
                        self.disconnect_reason = try wire.integer(details, 4);
                        if (@backingInt(self.phase) >= @backingInt(Phase.connect)) {
                            self.dhcp_client = null;
                            self.ipv6_client = null;
                            self.phase = .failed;
                            return error.Disconnected;
                        }
                    }
                    return;
                }
                if (!self.transmitted or self.active_id == null or response.uid != self.uid or response.id != self.active_id.? + 256) {
                    self.ignored_rpcs +|= 1;
                    return;
                }
                self.rpc_status = try wire.integer(response.body, if (self.phase == .mac) 2 else 1);
                self.last_response = response.id;
                if (self.rpc_status != 0 and self.phase != .version) {
                    self.phase = .failed;
                    return error.Rejected;
                }
                switch (self.phase) {
                    .version => {
                        if (self.rpc_status == 0) {
                            for (&self.version, 2..) |*value, field| value.* = try wire.integer(response.body, @intCast(field));
                            self.version_known = true;
                        }
                        self.advance(.init_wifi, now);
                    },
                    .init_wifi => self.advance(.storage, now),
                    .storage => self.advance(.mode, now),
                    .mode => self.advance(.start, now),
                    .start => self.advance(.ps, now),
                    .ps => self.advance(.mac, now),
                    .mac => {
                        const mac = (try wire.data(response.body, 1)) orelse return error.Malformed;
                        if (mac.len != 6 or mac[0] & 1 != 0 or std.mem.allEqual(u8, mac, 0)) return error.Malformed;
                        @memcpy(&self.mac_address, mac);
                        self.advance(if (self.join == .saved) .connect else .config, now);
                    },
                    .config => self.advance(.connect, now),
                    .connect => self.advance(.link, now),
                    else => return error.Malformed,
                }
            },
            1 => if (self.phase == .lease or (self.phase == .done and self.keep_serving)) {
                if (self.phase == .lease) self.dhcp_client.?.receive(frame.payload) catch |err| {
                    if (err == error.Rejected) {
                        self.phase = .failed;
                        return err;
                    }
                    self.malformed_network +|= 1;
                    return;
                };
                if (self.ipv6_client) |*client| client.receive(frame.payload, now) catch |err| {
                    if (err == error.Duplicate or err == error.Clock) {
                        self.phase = .failed;
                        return err;
                    }
                    client.dropped +|= 1;
                };
                self.finishIfReady();
            },
            else => {},
        }
    }
    fn advance(self: *Client, phase: Phase, now: u64) void {
        self.phase = phase;
        self.active_id = null;
        self.output_len = 0;
        self.transmitted = false;
        self.deadline = now + if (phase == .link) @as(u64, 30_000_000) else 5_000_000;
    }
    pub fn tx(self: *Client, now: u64) Error![]const u8 {
        if (now < self.started) return error.Timeout;
        if (self.phase == .done) {
            if (!self.keep_serving) return &.{};
            if (self.output_len != 0) return self.output[0..self.output_len];
            if (self.ipv6_client) |*client| {
                const packet = try client.tx(now);
                if (packet.len != 0) {
                    self.tx_ipv6 = true;
                    return self.encodeFrame(1, packet);
                }
            }
            return &.{};
        }
        if (self.phase == .failed) return error.Rejected;
        if (now >= self.deadline) {
            // Old factory versions may not implement the version request. Its
            // late reply has a distinct UID and cannot complete another request.
            if (self.phase == .version) self.advance(.init_wifi, now) else {
                self.phase = .failed;
                return error.Timeout;
            }
        }
        if (self.phase == .link and self.connected) {
            self.advance(.lease, now);
            self.deadline = now + 45_000_000;
            self.dhcp_client = .{ .mac = self.mac_address, .xid = @as(u32, @truncate(now)) ^ 0x4e49484f };
            if (self.ipv6_enabled) self.ipv6_client = ipv6.Client.init(self.mac_address, now);
        }
        if (self.transmitted) return &.{};
        if (self.output_len != 0) return self.output[0..self.output_len];
        if (self.phase == .handshake) {
            if (!self.capabilities_pending) return &.{};
            return self.encodeFrame(5, &wire.capabilities);
        }
        if (self.phase == .link) return &.{};
        if (self.phase == .lease) {
            if (self.ipv6_client) |*client| {
                const packet = try client.tx(now);
                if (packet.len != 0) {
                    self.tx_ipv6 = true;
                    return self.encodeFrame(1, packet);
                }
                self.finishIfReady();
                if (self.phase == .done) return &.{};
            }
            if (!self.dhcp_client.?.due(now)) return &.{};
            var buffer: [342]u8 = undefined;
            self.tx_ipv6 = false;
            return self.encodeFrame(1, try self.dhcp_client.?.packet(&buffer));
        }
        var body_buffer: [320]u8 = undefined;
        var body = wire.Writer{ .out = &body_buffer };
        const id: u32 = switch (self.phase) {
            .version => 350,
            .init_wifi => blk: {
                var config_buffer: [128]u8 = undefined;
                var config = wire.Writer{ .out = &config_buffer };
                const values = [_]u64{ 10, 32, 1, 0, 32, 0, 0, 1, 1, 0, 1, 0, 6, 0, 752, 32, 1, 0, 7, 0x1f2f3f4f };
                for (values, 1..) |value, field| try config.uint(@intCast(field), value);
                try body.data(1, config.slice());
                break :blk 278;
            },
            .storage => blk: {
                try body.uint(1, 1);
                break :blk 313;
            }, // WIFI_STORAGE_RAM
            .mode => blk: {
                try body.uint(1, 1);
                break :blk 260;
            },
            .start => 280,
            .ps => blk: {
                try body.uint(1, 0);
                break :blk 270;
            },
            .mac => blk: {
                try body.uint(1, 0);
                break :blk 257;
            },
            .config => blk: {
                const network = self.join.network;
                if (network.ssid.len == 0 or network.ssid.len > 32 or network.password.len > 63) return error.InvalidArgument;
                var sta_buffer: [192]u8 = undefined;
                var sta = wire.Writer{ .out = &sta_buffer };
                try sta.data(1, network.ssid);
                try sta.data(2, network.password);
                try sta.uint(3, 1);
                var threshold_buf: [24]u8 = undefined;
                var threshold = wire.Writer{ .out = &threshold_buf };
                try threshold.uint(1, @bitCast(@as(i64, -127)));
                try threshold.uint(2, 0);
                try sta.data(9, threshold.slice());
                // Both submessages must be present even for legacy C6 handlers.
                try sta.data(10, &.{ 8, 1, 16, 0 });
                try sta.uint(14, 0x1e);
                var cfg_buffer: [224]u8 = undefined;
                var cfg = wire.Writer{ .out = &cfg_buffer };
                try cfg.data(2, sta.slice());
                try body.uint(1, 0);
                try body.data(2, cfg.slice());
                break :blk 284;
            },
            .connect => 282,
            else => return error.Malformed,
        };
        if (self.uid == std.math.maxInt(u32)) return error.Stale;
        self.uid += 1;
        self.active_id = id;
        var payload: [384]u8 = undefined;
        return self.encodeFrame(3, try wire.request(&payload, id, self.uid, body.slice()));
    }
    fn encodeFrame(self: *Client, interface: u8, payload: []const u8) Error![]const u8 {
        const result = try wire.frame(&self.output, interface, self.sequence, payload);
        self.sequence +%= 1;
        self.output_len = result.len;
        return result;
    }
    pub fn sent(self: *Client, now: u64) void {
        @memset(self.output[0..self.output_len], 0);
        self.output_len = 0;
        if (self.phase == .handshake) self.advance(.version, now) else if (self.phase == .lease or (self.phase == .done and self.keep_serving)) {
            if (self.tx_ipv6) self.ipv6_client.?.sent(now) else self.dhcp_client.?.sent(now);
        } else {
            self.transmitted = true;
            self.deadline = now + 5_000_000;
        }
    }
    fn finishIfReady(self: *Client) void {
        const v4 = self.dhcp_client != null and self.dhcp_client.?.phase == .bound;
        if (self.ipv6_client) |client| {
            if (client.finished() and (v4 or client.complete())) self.phase = .done;
        } else if (v4) self.phase = .done;
    }
};
