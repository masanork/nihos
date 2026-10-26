//! Single-owner, allocation-free card job. No timer or automatic retry path.
//! The transport lends one Action until complete/failed, then must release it.
const std = @import("std");
const input = @import("input_support.zig");
const surface = @import("surface.zig");
pub const State = enum { idle, power_on, select_ap, select_pin, retries, pin, confirm_retries, verify, select_attributes, read, power_off, done, select_number, read_number, select_surface, select_surface_pin, surface_retries, confirm_surface_retries, surface_verify, select_photo, read_photo };
pub const Fault = enum { none, cancelled, disconnected, transport, pin_outcome_unknown, wrong_pin, blocked, last_attempt, counter_changed, status, malformed, too_large };
pub const Error = error{ Busy, Stale, InvalidPin, NotReady, Exhausted };
pub const Kind = enum { power_on, apdu, power_off };
pub const Action = struct { token: u32, kind: Kind, bytes: []const u8 };
pub const Prompt = struct { session: u32, remaining: u8 };

pub const Service = struct {
    state: State = .idle,
    fault: Fault = .none,
    cleanup_failed: bool = false,
    fault_state: State = .idle,
    attributes_ready: bool = false,
    remaining: ?u8 = null,
    last_sw: u16 = 0,
    session: u32 = 0,
    serial: u32 = 0,
    outstanding: ?u32 = null,
    cancelling: bool = false,
    pending_pin: [4]u8 = @splat(0),
    command: [17]u8 = @splat(0),
    command_length: usize = 0,
    attributes: [input.capacity]u8 = @splat(0),
    length: usize = 0,
    photo_buffer: ?[]u8 = null,
    photo_length: usize = 0,
    number_reader: ?*const fn ([]const u8) surface.Error![]const u8 = null,
    photo_reader: ?*const fn ([]const u8) surface.Error![]const u8 = null,
    surface_remaining: ?u8 = null,
    surface_probe: bool = false,
    number: [12]u8 = @splat(0),

    fn wipe(bytes: []u8) void {
        std.crypto.secureZero(u8, bytes);
    }
    fn ticket(self: *Service) Error!u32 {
        if (self.serial == std.math.maxInt(u32)) return error.Exhausted;
        self.serial += 1;
        return self.serial;
    }
    /// A new job requires a separate caller action after dismissing a result.
    pub fn start(self: *Service) Error!void {
        if (self.state != .idle) return error.Busy;
        self.session = try self.ticket();
        self.state = .power_on;
    }
    pub fn startSurfaceProbe(self: *Service) Error!void {
        try self.start();
        self.surface_probe = true;
    }
    pub fn startPortrait(self: *Service, buffer: []u8) Error!void {
        return self.startPortraitWith(surface.Parser(null), buffer);
    }
    pub fn startPortraitWith(self: *Service, comptime Read: type, buffer: []u8) Error!void {
        if (buffer.len != surface.capacity) return error.NotReady;
        try self.start();
        self.photo_buffer = buffer;
        self.number_reader = &Read.number;
        self.photo_reader = &Read.portrait;
        wipe(buffer);
    }
    fn wipePhoto(self: *Service) void {
        wipe(&self.number);
        if (self.photo_buffer) |buffer| wipe(buffer);
        self.photo_length = 0;
    }
    pub fn prompt(self: *const Service) ?Prompt {
        if (self.state != .pin or self.cancelling) return null;
        return .{ .session = self.session, .remaining = self.remaining.? };
    }
    /// Called only by an explicit local submit event. Rechecks the counter
    /// before constructing VERIFY; caller wipes its input immediately.
    pub fn submit(self: *Service, session: u32, pin: []const u8) Error!void {
        if (session != self.session) return error.Stale;
        if (self.prompt() == null) return error.NotReady;
        if (pin.len != 4) return error.InvalidPin;
        for (pin) |digit| if (digit < '0' or digit > '9') return error.InvalidPin;
        @memcpy(&self.pending_pin, pin);
        self.state = .confirm_retries;
    }
    noinline fn stop(self: *Service, fault: Fault) void {
        self.fault = fault;
        self.fault_state = self.state;
        if (fault == .pin_outcome_unknown) {
            self.remaining = null;
            self.surface_remaining = null;
        }
        wipe(&self.pending_pin);
        if (self.photo_buffer == null or !self.attributes_ready or fault == .cancelled) {
            wipe(&self.attributes);
            self.length = 0;
            self.attributes_ready = false;
        }
        self.wipePhoto();
        self.state = .power_off;
    }
    /// If DMA is in flight, its borrowed command stays valid until completion.
    /// Cancellation cannot promise to retract an already dispatched VERIFY.
    pub fn cancel(self: *Service) void {
        self.attributes_ready = false;
        if (self.state == .idle or self.state == .done) {
            wipe(&self.attributes);
            self.wipePhoto();
            self.length = 0;
            return;
        }
        self.cancelling = true;
        wipe(&self.pending_pin);
        if (self.state == .power_off and self.fault == .none) self.fault = .cancelled;
        wipe(&self.attributes);
        self.wipePhoto();
        self.length = 0;
        if (self.outstanding == null) {
            wipe(&self.command);
            self.stop(.cancelled);
        }
    }
    /// Transport must first halt DMA / release the Action on disconnect.
    pub fn disconnected(self: *Service) void {
        self.attributes_ready = false;
        self.fault_state = self.state;
        wipe(&self.command);
        wipe(&self.pending_pin);
        wipe(&self.attributes);
        self.wipePhoto();
        self.command_length = 0;
        self.length = 0;
        const verify_sent = (self.state == .verify or self.state == .surface_verify) and self.outstanding != null;
        self.outstanding = null;
        self.fault = if (verify_sent) .pin_outcome_unknown else .disconnected;
        self.remaining = null;
        self.state = .done;
    }
    fn setCommand(self: *Service, bytes: []const u8) void {
        @memcpy(self.command[0..bytes.len], bytes);
        self.command_length = bytes.len;
    }
    /// Owner dispatches at most once; polling again never repeats an action.
    pub fn take(self: *Service) Error!?Action {
        if (self.outstanding != null) return null;
        const kind: Kind = switch (self.state) {
            .idle, .pin, .done => return null,
            .power_on => .power_on,
            .power_off => .power_off,
            else => .apdu,
        };
        const token = try self.ticket();
        switch (self.state) {
            .select_ap => self.setCommand(&input.select_ap),
            .select_pin => self.setCommand(&input.select_pin),
            .retries, .confirm_retries => self.setCommand(&input.query_retries),
            .select_attributes => self.setCommand(&input.select_attributes),
            .read => self.setCommand(&.{ 0, 0xb0, @intCast(self.length >> 8), @truncate(self.length), 0 }),
            .power_on, .power_off => self.command_length = 0,
            .select_number => self.setCommand(&surface.select_number),
            .read_number => self.setCommand(&.{ 0, 0xb0, 0, 0, 0 }),
            .select_surface => self.setCommand(&surface.select_ap),
            .select_surface_pin => self.setCommand(&surface.select_pin),
            .surface_retries, .confirm_surface_retries => self.setCommand(&input.query_retries),
            .select_photo => self.setCommand(&surface.select_photo),
            .read_photo => self.setCommand(&.{ 0, 0xb0, @intCast(self.photo_length >> 8), @truncate(self.photo_length), 0 }),
            .verify, .surface_verify => {},
            else => unreachable,
        }
        self.outstanding = token;
        return .{ .token = token, .kind = kind, .bytes = self.command[0..self.command_length] };
    }
    fn release(self: *Service, token: u32) Error!void {
        if (self.outstanding == null or self.outstanding.? != token) return error.Stale;
        self.outstanding = null;
        wipe(&self.command);
        self.command_length = 0;
    }
    /// Call only after the transport has stopped accessing command bytes.
    /// Failure after VERIFY dispatch is terminal and explicitly uncertain.
    pub noinline fn failed(self: *Service, token: u32) Error!void {
        try self.release(token);
        if (self.state == .power_off) {
            self.cleanup_failed = true;
            self.attributes_ready = false;
            wipe(&self.attributes);
            self.wipePhoto();
            self.length = 0;
            self.state = .done;
        } else self.stop(if (self.state == .verify or self.state == .surface_verify) .pin_outcome_unknown else .transport);
    }
    /// For power actions reply is the ATR / empty power-off payload; transport
    /// validates CCID slot, sequence, status, card state and time extensions.
    pub inline fn complete(self: *Service, token: u32, reply: []const u8) Error!void {
        try self.release(token);
        if (self.state == .power_off) {
            self.state = .done;
            return;
        }
        if (self.cancelling) {
            // Record a known VERIFY failure even when the UI was cancelled.
            if (self.state == .verify or self.state == .surface_verify) self.observeVerify(reply);
            self.stop(if (self.fault == .none) .cancelled else self.fault);
            return;
        }
        if (self.state == .power_on) {
            if (reply.len < 2 or reply.len > 33) return self.stop(.malformed);
            self.state = if (self.surface_probe) .select_surface else .select_ap;
            return;
        }
        if (reply.len < 2) return self.stop(if (self.state == .verify or self.state == .surface_verify) .pin_outcome_unknown else .malformed);
        const body = reply[0 .. reply.len - 2];
        const sw = (@as(u16, reply[reply.len - 2]) << 8) | reply[reply.len - 1];
        self.last_sw = sw;
        switch (self.state) {
            .retries, .confirm_retries => {
                if (body.len != 0) return self.stop(.malformed);
                if (sw == 0x6983 or sw == 0x63c0) {
                    self.remaining = 0;
                    return self.stop(.blocked);
                }
                if (sw < 0x63c1 or sw > 0x63c3) return self.stop(.status);
                const previous = self.remaining;
                self.remaining = @intCast(sw & 15);
                if (self.remaining.? == 1) return self.stop(.last_attempt);
                if (self.state == .confirm_retries) {
                    if (previous != self.remaining) return self.stop(.counter_changed);
                    self.setCommand(&.{ 0, 0x20, 0, 0x80, 4 });
                    @memcpy(self.command[5..9], &self.pending_pin);
                    self.command_length = 9;
                    wipe(&self.pending_pin);
                    self.state = .verify;
                } else self.state = .pin;
            },
            .verify => {
                self.observeVerify(reply);
                if (self.fault != .none) return self.stop(self.fault);
                self.state = .select_attributes;
            },
            .read => {
                if (sw != 0x9000 and sw != 0x6282 and !(sw == 0x6b00 and self.length > 0 and body.len == 0)) return self.stop(.status);
                if (body.len > 256) return self.stop(.malformed);
                if (body.len > self.attributes.len - self.length) return self.stop(.too_large);
                @memcpy(self.attributes[self.length..][0..body.len], body);
                self.length += body.len;
                if (sw != 0x9000 or body.len < 256) {
                    _ = input.parse(self.attributes[0..self.length]) catch return self.stop(.malformed);
                    self.attributes_ready = true;
                    self.state = if (self.photo_buffer != null) .select_number else .power_off;
                }
            },
            .read_number => {
                if (sw != 0x9000 and sw != 0x6282) return self.stop(.status);
                const selected = (self.number_reader orelse return self.stop(.malformed))(body) catch return self.stop(.malformed);
                if (selected.len != 12) return self.stop(.malformed);
                @memcpy(&self.number, selected);
                self.state = .select_surface;
            },
            .surface_retries, .confirm_surface_retries => {
                if (body.len != 0) return self.stop(.malformed);
                if (sw == 0x6983 or sw == 0x63c0) return self.stop(.blocked);
                if (sw == 0x9000) {
                    if (self.state == .confirm_surface_retries) return self.stop(.counter_changed);
                    self.surface_remaining = null;
                    self.state = if (self.surface_probe) .power_off else .select_photo;
                    return;
                }
                if (sw < 0x63c2 or sw > 0x63cf) return self.stop(if (sw == 0x63c1) .last_attempt else .status);
                const remaining: u8 = @intCast(sw & 15);
                if (self.surface_probe) {
                    self.surface_remaining = remaining;
                    self.state = .power_off;
                    return;
                }
                if (self.state == .surface_retries) {
                    self.surface_remaining = remaining;
                    self.state = .confirm_surface_retries;
                } else {
                    if (self.surface_remaining != remaining) return self.stop(.counter_changed);
                    self.setCommand(&.{ 0, 0x20, 0, 0x80, 12 });
                    @memcpy(self.command[5..17], &self.number);
                    self.command_length = 17;
                    wipe(&self.number);
                    self.state = .surface_verify;
                }
            },
            .surface_verify => {
                if (reply.len != 2) return self.stop(.pin_outcome_unknown);
                if (sw != 0x9000) return self.stop(if (sw & 0xfff0 == 0x63c0) .wrong_pin else .pin_outcome_unknown);
                self.surface_remaining = null;
                self.state = .select_photo;
            },
            .read_photo => {
                if (sw != 0x9000 and sw != 0x6282 and !(sw == 0x6b00 and body.len == 0 and self.photo_length > 0)) return self.stop(.status);
                const buffer = self.photo_buffer orelse return self.stop(.malformed);
                if (body.len > 256 or self.photo_length > buffer.len or body.len > buffer.len - self.photo_length) return self.stop(.too_large);
                @memcpy(buffer[self.photo_length..][0..body.len], body);
                self.photo_length += body.len;
                if (sw != 0x9000 or body.len < 256) {
                    _ = (self.photo_reader orelse return self.stop(.malformed))(buffer[0..self.photo_length]) catch return self.stop(.malformed);
                    self.state = .power_off;
                } else if (self.photo_length == buffer.len) return self.stop(.too_large);
            },
            .select_number, .select_surface, .select_surface_pin, .select_photo => {
                if (sw != 0x9000 or body.len != 0) return self.stop(.status);
                self.state = switch (self.state) {
                    .select_number => .read_number,
                    .select_surface => .select_surface_pin,
                    .select_surface_pin => .surface_retries,
                    .select_photo => .read_photo,
                    else => unreachable,
                };
            },
            .select_ap, .select_pin, .select_attributes => {
                if (sw != 0x9000) return self.stop(.status);
                if (body.len != 0) return self.stop(.malformed);
                self.state = switch (self.state) {
                    .select_ap => .select_pin,
                    .select_pin => .retries,
                    .select_attributes => .read,
                    else => unreachable,
                };
            },
            else => unreachable,
        }
    }
    inline fn observeVerify(self: *Service, reply: []const u8) void {
        if (self.state == .surface_verify) {
            if (reply.len != 2) {
                self.surface_remaining = null;
                self.fault = .pin_outcome_unknown;
                return;
            }
            const status = (@as(u16, reply[0]) << 8) | reply[1];
            self.last_sw = status;
            if (status == 0x9000) self.surface_remaining = null else if (status & 0xfff0 == 0x63c0) {
                self.surface_remaining = @intCast(status & 15);
                self.fault = if (status == 0x63c0) .blocked else .wrong_pin;
            } else {
                self.surface_remaining = null;
                self.fault = .pin_outcome_unknown;
            }
            return;
        }

        if (reply.len != 2) {
            self.fault = .pin_outcome_unknown;
            return;
        }
        const sw = (@as(u16, reply[0]) << 8) | reply[1];
        self.last_sw = sw;
        if (sw == 0x9000) {
            self.remaining = null; // verified; not an observed remaining count
        } else if (sw >= 0x63c0 and sw <= 0x63c3) {
            self.remaining = @intCast(sw & 15);
            self.fault = if (sw == 0x63c0) .blocked else .wrong_pin;
        } else if (sw == 0x6983) {
            self.remaining = 0;
            self.fault = .blocked;
        } else self.fault = .pin_outcome_unknown;
    }
    pub fn result(self: *const Service) ?input.Attributes {
        if (self.fault != .none) return null;
        return self.attributesResult();
    }
    /// Independently validated four fields survive a later photo-AP failure,
    /// but never failed cleanup, disconnect, cancellation or an incomplete read.
    pub fn attributesResult(self: *const Service) ?input.Attributes {
        if (self.state != .done or !self.attributes_ready or self.cleanup_failed) return null;
        return input.parse(self.attributes[0..self.length]) catch null;
    }
    pub fn portrait(self: *const Service) ?[]const u8 {
        if (self.result() == null or self.photo_buffer == null) return null;
        return (self.photo_reader orelse return null)(self.photo_buffer.?[0..self.photo_length]) catch null;
    }
    /// Result slices expire here. No in-flight job may be silently reused.
    pub fn dismiss(self: *Service) Error!void {
        if (self.state != .done) return error.Busy;
        const serial = self.serial;
        wipe(&self.command);
        wipe(&self.pending_pin);
        wipe(&self.attributes);
        self.wipePhoto();
        self.* = .{ .serial = serial };
    }
};
