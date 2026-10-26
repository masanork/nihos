//! Bounded ESP-AT receive profile: passive multiplexed sockets, CIPDINFO=0,
//! and BLE client notifications/indications. No transport or OS dependency.
//! Returned slices are borrowed until the next push/reset. One owner only.
const std = @import("std");

pub const line_capacity = 512;
pub const payload_capacity = 1024;
pub const ble_payload_limit = 512;

pub const Data = struct {
    kind: enum { socket, notify, indicate },
    link: u8,
    service: u16 = 0,
    characteristic: u16 = 0,
    bytes: []const u8 = &.{},
};

pub const Event = union(enum) {
    line: []const u8,
    prompt,
    available: struct { link: u8, count: u32 },
    data: Data,
};

pub const Error = error{
    Failed,
    Busy,
    InvalidText,
    InvalidHeader,
    UnsupportedProfile,
    LineTooLong,
    PayloadTooLong,
    UnexpectedData,
};

pub const Decoder = struct {
    const Mode = enum { text, payload, trailer_cr, trailer_lf };
    const Read = struct { link: u8, limit: usize };

    line: [line_capacity]u8 = @splat(0),
    payload: [payload_capacity]u8 = @splat(0),
    line_len: usize = 0,
    payload_len: usize = 0,
    expected_len: usize = 0,
    metadata: Data = .{ .kind = .socket, .link = 0 },
    mode: Mode = .text,
    read: ?Read = null,
    prompt_expected: bool = false,
    after_prompt: bool = false,
    failed: bool = false,

    /// Arm before sending CIPRECVDATA. Responses do not contain the link ID.
    pub fn expectSocketRead(self: *Decoder, link: u8, limit: usize) Error!void {
        if (self.failed) return error.Failed;
        if (self.mode != .text or self.line_len != 0 or self.read != null or self.prompt_expected) return error.Busy;
        if (link > 4 or limit == 0 or limit > payload_capacity) return error.InvalidHeader;
        self.read = .{ .link = link, .limit = limit };
    }

    /// Arm only for a command whose next phase accepts a data prompt.
    pub fn expectPrompt(self: *Decoder) Error!void {
        if (self.failed) return error.Failed;
        if (self.mode != .text or self.line_len != 0 or self.read != null or self.prompt_expected) return error.Busy;
        self.prompt_expected = true;
    }

    /// A timeout or lost byte destroys framing. Recreate only after link recovery.
    pub fn abort(self: *Decoder) void {
        self.failed = true;
    }

    /// Clear unused expectations after a confirmed terminal command response
    /// (e.g. ERROR before a read/prompt). Never use this to recover a timeout.
    pub fn endCommand(self: *Decoder) Error!void {
        if (self.failed) return error.Failed;
        if (self.mode != .text or self.line_len != 0) return error.Busy;
        self.read = null;
        self.prompt_expected = false;
    }

    pub fn push(self: *Decoder, byte: u8) Error!?Event {
        if (self.failed) return error.Failed;
        return self.consume(byte) catch |err| {
            self.failed = true;
            return err;
        };
    }

    fn consume(self: *Decoder, byte: u8) Error!?Event {
        switch (self.mode) {
            .payload => {
                self.payload[self.payload_len] = byte;
                self.payload_len += 1;
                if (self.payload_len == self.expected_len) return self.finishData();
                return null;
            },
            .trailer_cr => {
                if (byte != '\r') return error.InvalidText;
                self.mode = .trailer_lf;
                return null;
            },
            .trailer_lf => {
                if (byte != '\n') return error.InvalidText;
                self.mode = .text;
                return null;
            },
            .text => {},
        }
        if (self.after_prompt) {
            self.after_prompt = false;
            if (byte == ' ') return null;
        }
        if (byte == '>' and self.line_len == 0) {
            if (!self.prompt_expected) return error.UnexpectedData;
            self.prompt_expected = false;
            self.after_prompt = true;
            return .prompt;
        }
        if (byte == '\n') {
            if (self.line_len == 0 or self.line[self.line_len - 1] != '\r') return error.InvalidText;
            const text = self.line[0 .. self.line_len - 1];
            self.line_len = 0;
            if (text.len == 0) return null;
            if (std.mem.startsWith(u8, text, "+IPD,")) {
                var fields = std.mem.splitScalar(u8, text[5..], ',');
                const link = try number(fields.next() orelse return error.InvalidHeader);
                const count = try number(fields.next() orelse return error.InvalidHeader);
                if (fields.next() != null or link > 4) return error.InvalidHeader;
                return .{ .available = .{ .link = @intCast(link), .count = count } };
            }
            for ([_][]const u8{ "+CIPRECVDATA:", "+NOTIFY:", "+INDICATE:" }) |prefix| {
                if (std.mem.startsWith(u8, text, prefix)) return error.InvalidHeader;
            }
            return .{ .line = text };
        }
        if (self.line_len > 0 and self.line[self.line_len - 1] == '\r') return error.InvalidText;
        if (byte != '\r' and (byte < 0x20 or byte == 0x7f)) return error.InvalidText;
        if (self.line_len == self.line.len) return error.LineTooLong;
        self.line[self.line_len] = byte;
        self.line_len += 1;
        const text = self.line[0..self.line_len];
        if (byte == ':') {
            // These forms can contain binary, but are outside this receive profile.
            for ([_][]const u8{ "+IPD,", "+READ:", "+WRITE:", "+BLEGATTCRD:", "+BLUFIDATA:" }) |prefix| {
                if (std.mem.startsWith(u8, text, prefix)) return error.UnsupportedProfile;
            }
        }
        if (byte != ',') return null;
        if (std.mem.startsWith(u8, text, "+CIPRECVDATA:")) {
            const pending = self.read orelse return error.UnexpectedData;
            const length = try number(text[13 .. text.len - 1]);
            if (length > pending.limit) return error.PayloadTooLong;
            self.read = null;
            return self.beginData(.{ .kind = .socket, .link = pending.link }, length);
        }
        const notification = std.mem.startsWith(u8, text, "+NOTIFY:");
        const indication = std.mem.startsWith(u8, text, "+INDICATE:");
        if (!notification and !indication) return null;
        const prefix_len: usize = if (notification) 8 else 10;
        const header = text[prefix_len..];
        if (std.mem.count(u8, header, ",") != 4) return null;
        var fields = std.mem.splitScalar(u8, header[0 .. header.len - 1], ',');
        const link = try number(fields.next() orelse return error.InvalidHeader);
        const service = try number(fields.next() orelse return error.InvalidHeader);
        const characteristic = try number(fields.next() orelse return error.InvalidHeader);
        const length = try number(fields.next() orelse return error.InvalidHeader);
        if (fields.next() != null or link > 2 or service > 65535 or characteristic > 65535) return error.InvalidHeader;
        if (length > ble_payload_limit) return error.PayloadTooLong;
        return self.beginData(.{
            .kind = if (notification) .notify else .indicate,
            .link = @intCast(link),
            .service = @intCast(service),
            .characteristic = @intCast(characteristic),
        }, length);
    }

    fn beginData(self: *Decoder, metadata: Data, length: usize) ?Event {
        self.metadata = metadata;
        self.expected_len = length;
        self.payload_len = 0;
        self.line_len = 0;
        self.mode = .payload;
        if (length == 0) return self.finishData();
        return null;
    }

    fn finishData(self: *Decoder) Event {
        self.metadata.bytes = self.payload[0..self.payload_len];
        self.mode = .trailer_cr;
        return .{ .data = self.metadata };
    }
};

fn number(bytes: []const u8) Error!u32 {
    if (bytes.len == 0) return error.InvalidHeader;
    var value: u32 = 0;
    for (bytes) |byte| {
        if (byte < '0' or byte > '9') return error.InvalidHeader;
        const digit: u32 = byte - '0';
        if (value > (std.math.maxInt(u32) - digit) / 10) return error.InvalidHeader;
        value = value * 10 + digit;
    }
    return value;
}

/// AT has no request IDs. Never reuse the command slot after an ambiguous
/// timeout: reset/recover the transport and reapply the profile first.
pub const CommandGate = struct {
    pub const Token = struct { epoch: u64, serial: u64 };
    pub const Pending = struct { token: Token, deadline: u64 };
    pub const GateError = error{ NotSynchronized, Busy, InvalidDeadline, Exhausted, Stale };

    epoch: u64 = 0,
    serial: u64 = 0,
    synchronized: bool = false,
    pending: ?Pending = null,

    /// Only after a fresh link and successful profile negotiation, never merely
    /// because a delayed OK or a ready banner arrived. Also recreate Decoder.
    pub fn establish(self: *CommandGate) GateError!void {
        if (self.synchronized or self.pending != null) return error.Busy;
        if (self.epoch == std.math.maxInt(u64)) return error.Exhausted;
        self.epoch += 1;
        self.serial = 0;
        self.synchronized = true;
    }

    pub fn begin(self: *CommandGate, now: u64, deadline: u64) GateError!Token {
        if (!self.synchronized) return error.NotSynchronized;
        if (self.pending != null) return error.Busy;
        if (deadline <= now) return error.InvalidDeadline;
        if (self.serial == std.math.maxInt(u64)) return error.Exhausted;
        self.serial += 1;
        const token = Token{ .epoch = self.epoch, .serial = self.serial };
        self.pending = .{ .token = token, .deadline = deadline };
        return token;
    }

    /// Call only for the terminal response for this command phase; URCs and
    /// CIPSEND's intermediate OK must not complete a send transaction.
    pub fn complete(self: *CommandGate, token: Token, now: u64) GateError!void {
        const pending = self.pending orelse return error.Stale;
        if (!self.synchronized or token.epoch != pending.token.epoch or token.serial != pending.token.serial) return error.Stale;
        if (now >= pending.deadline) {
            self.invalidate();
            return error.NotSynchronized;
        }
        self.pending = null;
    }

    pub fn expire(self: *CommandGate, now: u64) ?Token {
        const pending = self.pending orelse return null;
        if (now < pending.deadline) return null;
        self.invalidate();
        return pending.token;
    }

    pub fn invalidate(self: *CommandGate) void {
        self.synchronized = false;
        self.pending = null;
    }
};
