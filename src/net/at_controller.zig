//! Single-owner, allocation-free ESP-AT transaction controller. The adapter
//! supplies monotonic time, partial TX acknowledgements and lossless RX bytes.
const std = @import("std");
pub const wire = @import("esp_at.zig");
const at = wire;
pub const commands = @import("at_commands.zig");

pub const profile = [_][]const u8{
    "AT\r\n",                 "ATE0\r\n",         "AT+GMR\r\n",      "AT+SYSSTORE=0\r\n",
    "AT+CWMODE=1\r\n",        "AT+CIPMODE=0\r\n", "AT+CIPMUX=1\r\n", "AT+CIPDINFO=0\r\n",
    "AT+CIPRECVTYPE=5,1\r\n", "AT+BLEINIT=1\r\n",
};

pub const Failure = enum { rejected, timeout, reset, protocol, transport, cancelled };
pub const Completion = struct {
    token: at.CommandGate.Token,
    failure: ?Failure,
    // For read only; borrowed until the next submit/recover, not the next RX byte.
    bytes: []const u8,
};
pub const Notice = union(enum) {
    line: []const u8,
    available: struct { link: u8, count: u32 },
    data: at.Data,
    profile_ready,
};
pub const Error = at.Error || at.CommandGate.GateError || commands.Error || error{
    NotReady,
    TimedOut,
    LinkReset,
    Protocol,
    Rejected,
    InvalidTransfer,
};

pub const Controller = struct {
    const Phase = enum { disconnected, idle, command_tx, response, prompt, payload_tx, final, failed };
    const Active = struct { token: at.CommandGate.Token, kind: commands.Kind, link: u8 };

    decoder: at.Decoder = .{},
    gate: at.CommandGate = .{},
    phase: Phase = .disconnected,
    active: ?Active = null,
    completion: ?Completion = null,
    last_failure: ?Failure = null,
    booting: bool = false,
    boot_index: usize = 0,
    boot_timeout: u64 = 0,
    header: [512]u8 = @splat(0),
    header_len: usize = 0,
    payload: [at.payload_capacity]u8 = @splat(0),
    payload_len: usize = 0,
    tx_offset: usize = 0,
    received: [at.payload_capacity]u8 = @splat(0),
    received_len: usize = 0,
    have_read: bool = false,
    send_ack: bool = false,

    /// Adapter must first reset/recover SDIO, drain old bytes, and wait for boot
    /// to settle. This call starts profile negotiation, not application readiness.
    pub fn recover(self: *Controller, now: u64, command_timeout: u64) Error!void {
        if ((self.phase != .disconnected and self.phase != .failed) or self.completion != null) return error.Busy;
        _ = try deadline(now, command_timeout);
        try self.gate.establish();
        self.decoder = .{};
        self.last_failure = null;
        self.booting = true;
        self.boot_index = 0;
        self.boot_timeout = command_timeout;
        try self.beginProfile(now);
    }

    pub fn ready(self: *const Controller) bool {
        return self.phase == .idle and !self.booting and self.gate.synchronized;
    }

    /// Accepted TX/payload bytes are copied. The caller may release its input.
    /// Deadline is absolute, in the same monotonic units as now.
    pub fn submit(self: *Controller, command: commands.Command, now: u64, until: u64) Error!at.CommandGate.Token {
        if (!self.ready()) return error.NotReady;
        if (self.completion != null) return error.Busy;
        // Do not put a command in the middle of a partially received URC.
        try self.decoder.endCommand();
        const encoded = try commands.encode(&self.header, command);
        const token = try self.gate.begin(now, until);
        self.arm(encoded) catch |err| {
            // Nothing has been transmitted; the reserved slot can be cancelled.
            try self.gate.complete(token, now);
            return err;
        };
        self.header_len = encoded.bytes.len;
        self.payload_len = encoded.payload.len;
        @memcpy(self.payload[0..self.payload_len], encoded.payload);
        self.tx_offset = 0;
        self.received_len = 0;
        self.have_read = false;
        self.send_ack = false;
        self.active = .{ .token = token, .kind = encoded.kind, .link = encoded.link };
        self.phase = .command_tx;
        return token;
    }

    /// Borrow until consumeTx or another mutating call. RX must still be drained
    /// while this is empty or a command is waiting for a response.
    pub fn tx(self: *Controller, now: u64) Error![]const u8 {
        if (self.expire(now)) return error.TimedOut;
        if (self.phase == .failed or self.phase == .disconnected) return error.NotReady;
        return switch (self.phase) {
            .command_tx => self.header[self.tx_offset..self.header_len],
            .payload_tx => self.payload[self.tx_offset..self.payload_len],
            else => &.{},
        };
    }

    /// Acknowledge only the count actually written by the transport, before
    /// feeding responses to those bytes. Zero progress leaves the deadline intact.
    pub fn consumeTx(self: *Controller, count: usize, now: u64) Error!void {
        const pending = try self.tx(now);
        if (count > pending.len or (pending.len == 0 and count != 0)) {
            self.fail(.transport);
            return error.InvalidTransfer;
        }
        if (count == 0) return;
        const payload_phase = self.phase == .payload_tx;
        if (payload_phase) {
            @memset(self.payload[self.tx_offset..][0..count], 0);
        } else {
            @memset(self.header[self.tx_offset..][0..count], 0);
        }
        self.tx_offset += count;
        if (count != pending.len) return;
        self.tx_offset = 0;
        if (payload_phase) {
            self.phase = .final;
        } else {
            const kind = self.active.?.kind;
            self.phase = if (kind == .socket_send or kind == .ble_write) .prompt else .response;
        }
    }

    pub fn push(self: *Controller, byte: u8, now: u64) Error!?Notice {
        if (self.expire(now)) return error.TimedOut;
        if (self.phase == .failed or self.phase == .disconnected) return error.NotReady;
        const decoded = self.decoder.push(byte) catch |err| {
            self.fail(.protocol);
            return err;
        };
        const item = decoded orelse return null;
        switch (item) {
            .line => |line| return self.onLine(line, now),
            .available => |available| return .{ .available = .{ .link = available.link, .count = available.count } },
            .prompt => {
                if (self.phase != .prompt or self.active == null) return self.protocolFault();
                if (self.active.?.kind == .socket_send and !self.send_ack) return self.protocolFault();
                self.phase = .payload_tx;
                self.tx_offset = 0;
                return null;
            },
            .data => |data| {
                if (data.kind != .socket) return .{ .data = data };
                const active = self.active orelse return self.protocolFault();
                if (active.kind != .read or self.phase != .response or self.have_read or active.link != data.link) return self.protocolFault();
                @memcpy(self.received[0..data.bytes.len], data.bytes);
                self.received_len = data.bytes.len;
                self.have_read = true;
                return null;
            },
        }
    }

    pub fn takeCompletion(self: *Controller) ?Completion {
        const result = self.completion;
        self.completion = null;
        return result;
    }

    pub fn expire(self: *Controller, now: u64) bool {
        if (self.gate.expire(now) == null) return false;
        self.fail(.timeout);
        return true;
    }

    /// RX loss, TX ambiguity and cancellation all require full link recovery.
    pub fn transportFailed(self: *Controller) void {
        self.fail(.transport);
    }

    pub fn cancel(self: *Controller) void {
        self.fail(.cancelled);
    }

    fn arm(self: *Controller, encoded: commands.Encoded) Error!void {
        switch (encoded.kind) {
            .simple => {},
            .read => try self.decoder.expectSocketRead(encoded.link, encoded.read_limit),
            .socket_send, .ble_write => try self.decoder.expectPrompt(),
        }
    }

    fn beginProfile(self: *Controller, now: u64) Error!void {
        const until = deadline(now, self.boot_timeout) catch |err| {
            self.fail(.protocol);
            return err;
        };
        const token = self.gate.begin(now, until) catch |err| {
            self.fail(.protocol);
            return err;
        };
        const command = profile[self.boot_index];
        @memcpy(self.header[0..command.len], command);
        self.header_len = command.len;
        self.payload_len = 0;
        self.tx_offset = 0;
        self.active = .{ .token = token, .kind = .simple, .link = 0 };
        self.phase = .command_tx;
    }

    fn onLine(self: *Controller, line: []const u8, now: u64) Error!?Notice {
        if (std.mem.eql(u8, line, "ready")) {
            self.fail(.reset);
            return error.LinkReset;
        }
        if (std.mem.startsWith(u8, line, "busy ")) return self.protocolFault();
        const ok = std.mem.eql(u8, line, "OK");
        const send_ok = std.mem.eql(u8, line, "SEND OK");
        const rejected = std.mem.eql(u8, line, "ERROR") or std.mem.eql(u8, line, "FAIL");
        const send_failed = std.mem.eql(u8, line, "SEND FAIL");
        if (!ok and !send_ok and !rejected and !send_failed) return .{ .line = line };
        const active = self.active orelse return self.protocolFault();
        if (self.phase == .command_tx or self.phase == .payload_tx) return self.protocolFault();
        if (send_ok or send_failed) {
            if (active.kind != .socket_send or self.phase != .final) return self.protocolFault();
            return self.finish(if (send_failed) .rejected else null, now);
        }
        if (rejected) return self.finish(.rejected, now);
        if (self.phase == .prompt) {
            if (active.kind != .socket_send or self.send_ack) return self.protocolFault();
            self.send_ack = true;
            return null;
        }
        if (self.phase == .final and active.kind != .ble_write) return self.protocolFault();
        if (active.kind == .read and !self.have_read) return self.protocolFault();
        return self.finish(null, now);
    }

    fn finish(self: *Controller, failure: ?Failure, now: u64) Error!?Notice {
        const active = self.active.?;
        self.gate.complete(active.token, now) catch |err| {
            self.fail(.timeout);
            return err;
        };
        self.decoder.endCommand() catch |err| {
            self.fail(.protocol);
            return err;
        };
        if (self.booting) {
            if (failure != null) {
                self.fail(.rejected);
                return error.Rejected;
            }
            self.boot_index += 1;
            if (self.boot_index < profile.len) {
                try self.beginProfile(now);
                return null;
            }
            self.active = null;
            self.booting = false;
            self.phase = .idle;
            return .profile_ready;
        }
        self.completion = .{
            .token = active.token,
            .failure = failure,
            .bytes = if (failure == null and active.kind == .read) self.received[0..self.received_len] else &.{},
        };
        self.active = null;
        self.phase = .idle;
        return null;
    }

    fn fail(self: *Controller, reason: Failure) void {
        if (self.active) |active| {
            if (!self.booting) self.completion = .{ .token = active.token, .failure = reason, .bytes = &.{} };
        }
        self.active = null;
        self.gate.invalidate();
        self.decoder.abort();
        self.phase = .failed;
        self.last_failure = reason;
        @memset(&self.header, 0);
        @memset(&self.payload, 0);
    }

    fn protocolFault(self: *Controller) Error {
        self.fail(.protocol);
        return error.Protocol;
    }
};

fn deadline(now: u64, duration: u64) Error!u64 {
    const result = @addWithOverflow(now, duration);
    if (duration == 0 or result[1] != 0) return error.InvalidDeadline;
    return result[0];
}
