//! Bounded read-only licence job, independent of My Number PIN namespaces.
const std = @import("std");
const core = @import("service.zig");
const base = @import("license.zig");
const record = @import("license_record.zig");
pub const Profile = enum { classic, myna };
pub const State = enum { idle, power_on, select_ap, settings_select, settings_read, mf, pin_select, counter, pin, confirm, verify, df, file, read, power_off, done };
pub const myna_aid = [_]u8{ 0, 0xa4, 4, 0x0c, 16, 0xa0, 0, 0, 2, 0x31, 6, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
pub const Region = struct { offset: usize, length: usize, fid: u8, df: u8 };
pub const classic_files = [_]Region{
    .{ .offset = 0, .length = 880, .fid = 1, .df = 1 },
    .{ .offset = 2967, .length = 640, .fid = 4, .df = 1 },
    .{ .offset = 3607, .length = 663, .fid = 5, .df = 1 },
    .{ .offset = 4270, .length = 578, .fid = 7, .df = 1 },
    .{ .offset = 880, .length = 82, .fid = 2, .df = 1 },
    .{ .offset = 4848, .length = 256, .fid = 6, .df = 1 },
    .{ .offset = 5104, .length = 264, .fid = 3, .df = 1 },
    .{ .offset = 962, .length = 2005, .fid = 1, .df = 2 },
};
pub const myna_files = [_]Region{ .{ .offset = 0, .length = 5845, .fid = 0x1b, .df = 0 }, .{ .offset = 5845, .length = 584, .fid = 0x1c, .df = 0 } };
fn placement(comptime section: ?[]const u8) []const u8 {
    return section orelse if (@import("builtin").os.tag == .macos) "__TEXT,__text" else ".text";
}
pub fn Session(comptime section: ?[]const u8) type {
    return struct {
        const Self = @This();
        const P = record.Parser(section);
        state: State = .idle,
        fault: core.Fault = .none,
        fault_state: State = .idle,
        last_sw: u16 = 0,
        cleanup_failed: bool = false,
        profile: Profile = .classic,
        buffer: ?[]u8 = null,
        basic_ready: bool = false,
        serial: u32 = 0,
        session: u32 = 0,
        outstanding: ?u32 = null,
        cancelling: bool = false,
        pin_index: u8 = 1,
        remaining: ?u8 = null,
        counts: [2]u8 = .{ 255, 255 },
        phase: u8 = 0,
        file_index: u8 = 0,
        file_offset: usize = 0,
        command: [21]u8 = @splat(0),
        command_length: usize = 0,
        pending_pin: [4]u8 = @splat(0),
        fn ticket(self: *Self) linksection(placement(section)) core.Error!u32 {
            if (self.serial == 0xffffffff) return error.Exhausted;
            self.serial += 1;
            return self.serial;
        }
        fn wipe(bytes: []u8) void {
            std.crypto.secureZero(u8, bytes);
        }
        pub fn start(self: *Self, profile: Profile, buffer: []u8) linksection(placement(section)) core.Error!void {
            if (self.state != .idle) return error.Busy;
            if (buffer.len != 32768) return error.NotReady;
            self.session = try self.ticket();
            self.profile = profile;
            self.buffer = buffer;
            wipe(buffer);
            self.state = .power_on;
        }
        pub fn prompt(self: *const Self) linksection(placement(section)) ?core.Prompt {
            if (self.state != .pin or self.cancelling) return null;
            return .{ .session = self.session, .remaining = self.remaining.?, .index = if (self.profile == .myna) 3 else self.pin_index };
        }
        pub fn submit(self: *Self, session: u32, pin: []const u8) linksection(placement(section)) core.Error!void {
            if (session != self.session) return error.Stale;
            if (self.prompt() == null) return error.NotReady;
            if (pin.len != 4) return error.InvalidPin;
            for (pin) |b| if (b < '0' or b > '9') return error.InvalidPin;
            @memcpy(&self.pending_pin, pin);
            self.state = .confirm;
        }
        fn region(self: *const Self) linksection(placement(section)) Region {
            return if (self.profile == .classic) classic_files[self.file_index] else myna_files[self.file_index];
        }
        fn set(self: *Self, bytes: []const u8) linksection(placement(section)) void {
            @memcpy(self.command[0..bytes.len], bytes);
            self.command_length = bytes.len;
        }
        pub noinline fn take(self: *Self) linksection(placement(section)) core.Error!?core.Action {
            if (self.outstanding != null or self.state == .idle or self.state == .pin or self.state == .done) return null;
            const token = try self.ticket();
            const kind: core.Kind = if (self.state == .power_on) .power_on else if (self.state == .power_off) .power_off else .apdu;
            switch (self.state) {
                .power_on, .power_off => self.command_length = 0,
                .select_ap => self.set(if (self.profile == .myna) &myna_aid else &base.select_mf),
                .settings_select => self.set(if (self.profile == .myna) &.{ 0, 0xa4, 2, 0x0c, 2, 0, 0x1a } else &base.select_pin_setting),
                .settings_read => self.set(&.{ 0, 0xb0, 0, 0, 3 }),
                .mf => self.set(&base.select_mf),
                .pin_select => self.set(if (self.profile == .myna) &.{ 0, 0xa4, 2, 0x0c, 2, 0, 6 } else if (self.pin_index == 1) &base.select_pin1 else &base.select_pin2),
                .counter, .confirm => self.set(&.{ 0, 0x20, 0, if (self.profile == .myna) 0x82 else 0x80 }),
                .verify => {},
                .df => self.set(if (self.region().df == 2) &base.select_df2 else &base.select_df1),
                .file => self.set(&.{ 0, 0xa4, 2, 0x0c, 2, 0, self.region().fid }),
                .read => self.set(&.{ 0, 0xb0, @intCast(self.file_offset >> 8), @truncate(self.file_offset), @truncate(@min(256, self.region().length - self.file_offset)) }),
                else => unreachable,
            }
            self.outstanding = token;
            return .{ .token = token, .kind = kind, .bytes = self.command[0..self.command_length] };
        }
        fn release(self: *Self, token: u32) linksection(placement(section)) core.Error!void {
            if (self.outstanding != token) return error.Stale;
            self.outstanding = null;
            wipe(&self.command);
            self.command_length = 0;
        }
        fn stop(self: *Self, fault: core.Fault) linksection(placement(section)) void {
            self.fault = fault;
            self.fault_state = self.state;
            wipe(&self.pending_pin);
            if (fault == .pin_outcome_unknown) self.remaining = null;
            if (self.buffer) |b| {
                if (self.profile == .classic and self.basic_ready and fault != .cancelled) {
                    wipe(b[880..2967]);
                    wipe(b[3607..]);
                } else {
                    wipe(b);
                    self.basic_ready = false;
                }
            }
            self.state = .power_off;
        }
        pub fn cancel(self: *Self) linksection(placement(section)) void {
            self.cancelling = true;
            self.basic_ready = false;
            wipe(&self.pending_pin);
            if (self.buffer) |b| wipe(b);
            if (self.outstanding == null and self.state != .done and self.state != .idle) self.stop(.cancelled);
        }
        pub fn disconnected(self: *Self) linksection(placement(section)) void {
            const sent = self.state == .verify and self.outstanding != null;
            self.stop(if (sent) .pin_outcome_unknown else .disconnected);
            self.basic_ready = false;
            if (self.buffer) |b| wipe(b);
            wipe(&self.command);
            self.outstanding = null;
            self.state = .done;
        }
        pub fn failed(self: *Self, token: u32) linksection(placement(section)) core.Error!void {
            try self.release(token);
            if (self.state == .power_off) {
                self.cleanup_failed = true;
                self.basic_ready = false;
                if (self.buffer) |b| wipe(b);
                self.state = .done;
                return;
            }
            self.stop(if (self.state == .verify) .pin_outcome_unknown else .transport);
        }
        pub noinline fn complete(self: *Self, token: u32, reply: []const u8) linksection(placement(section)) core.Error!void {
            try self.release(token);
            if (self.state == .power_off) {
                self.state = .done;
                return;
            }
            if (self.cancelling) {
                self.stop(.cancelled);
                return;
            }
            if (self.state == .power_on) {
                if (reply.len < 2 or reply.len > 33) return self.stop(.malformed);
                self.state = .select_ap;
                return;
            }
            if (reply.len < 2) return self.stop(if (self.state == .verify) .pin_outcome_unknown else .malformed);
            const body = reply[0 .. reply.len - 2];
            const sw = std.mem.readInt(u16, reply[reply.len - 2 ..][0..2], .big);
            self.last_sw = sw;
            if (self.state == .verify) {
                if (body.len != 0) return self.stop(.pin_outcome_unknown);
                if (sw != 0x9000) {
                    if (sw & 0xfff0 == 0x63c0) {
                        self.remaining = @intCast(sw & 15);
                        self.stop(if (sw == 0x63c0) .blocked else .wrong_pin);
                    } else self.stop(if (sw == 0x6983 or sw == 0x6984) .blocked else .pin_outcome_unknown);
                    return;
                }
                self.remaining = null;
                self.state = if (self.profile == .myna) .file else .df;
                return;
            }
            if (self.state == .counter or self.state == .confirm) {
                if (body.len != 0) return self.stop(.malformed);
                const maximum: u16 = if (self.profile == .myna) 10 else 3;
                if (sw != 0x6983 and sw != 0x6984 and (sw < 0x63c0 or sw > 0x63c0 + maximum)) return self.stop(.status);
                const count: u8 = if (sw == 0x6983 or sw == 0x6984) 0 else @intCast(sw & 15);
                if (self.state == .confirm) {
                    if (count < 2) return self.stop(if (count == 0) .blocked else .last_attempt);
                    if (self.remaining != count) return self.stop(.counter_changed);
                    self.set(&.{ 0, 0x20, 0, if (self.profile == .myna) 0x82 else 0x80, 4 });
                    @memcpy(self.command[5..9], &self.pending_pin);
                    self.command_length = 9;
                    wipe(&self.pending_pin);
                    self.state = .verify;
                    return;
                }
                if (self.profile == .classic and self.phase == 1) {
                    self.counts[1] = count;
                    self.phase = 2;
                    self.pin_index = 1;
                    self.state = .mf;
                    return;
                }
                if (count < 2) return self.stop(if (count == 0) .blocked else .last_attempt);
                if (self.profile == .classic and self.phase == 0) {
                    self.counts[0] = count;
                    self.phase = 1;
                    self.pin_index = 2;
                    self.state = .mf;
                    return;
                }
                if (self.profile == .classic and count != self.counts[self.pin_index - 1]) return self.stop(.counter_changed);
                self.remaining = count;
                self.state = .pin;
                return;
            }
            if (self.state == .read) {
                if (sw != 0x9000 and sw != 0x6282) return self.stop(.status);
                const r = self.region();
                const wanted = @min(256, r.length - self.file_offset);
                if (body.len != wanted or (sw == 0x6282 and self.file_offset + wanted != r.length)) return self.stop(.malformed);
                @memcpy(self.buffer.?[r.offset + self.file_offset ..][0..wanted], body);
                self.file_offset += wanted;
                if (self.file_offset != r.length) return;
                if (self.profile == .classic) {
                    if (self.file_index == 0) {
                        var out: [512]u8 = undefined;
                        defer wipe(&out);
                        _ = base.Parser(section).decode(self.buffer.?[0..880], &out) catch return self.stop(.malformed);
                    }
                    if (self.file_index == 1 or self.file_index == 5) {
                        var list: [32]record.History = undefined;
                        defer wipe(std.mem.asBytes(&list));
                        _ = P.history(self.buffer.?[r.offset..][0..r.length], &list) catch return self.stop(.malformed);
                        if (self.file_index == 1) self.basic_ready = true;
                    }
                } else if (self.file_index == 0) {
                    _ = P.myna(self.buffer.?[0..5845]) catch return self.stop(.malformed);
                    self.basic_ready = true;
                }
                self.file_index += 1;
                self.file_offset = 0;
                if (self.file_index == (if (self.profile == .classic) @as(u8, 8) else 2)) {
                    self.state = .power_off;
                    return;
                }
                if (self.profile == .classic and self.file_index == 4) {
                    self.pin_index = 2;
                    self.phase = 3;
                    self.session = self.ticket() catch return self.stop(.transport);
                    self.state = .mf;
                    return;
                }
                self.state = if (self.profile == .classic and self.file_index == 7) .df else .file;
                return;
            }
            if (sw != 0x9000) return self.stop(.status);
            if (self.state == .settings_read) {
                if (body.len != 3 or body[0] != (if (self.profile == .myna) @as(u8, 0xc1) else 5) or body[1] != 1 or body[2] > 1) return self.stop(.malformed);
                if (body[2] == 0) return self.stop(.status);
                self.state = if (self.profile == .myna) .pin_select else .mf;
                return;
            }
            if (body.len != 0) return self.stop(.malformed);
            self.state = switch (self.state) {
                .select_ap => .settings_select,
                .settings_select => .settings_read,
                .mf => .pin_select,
                .pin_select => .counter,
                .df => .file,
                .file => .read,
                else => {
                    self.stop(.status);
                    return;
                },
            };
        }
        pub fn result(self: *const Self) linksection(placement(section)) ?[]const u8 {
            if (self.state != .done or self.cleanup_failed or !self.basic_ready) return null;
            return self.buffer;
        }
        pub fn portrait(self: *const Self) linksection(placement(section)) ?[]const u8 {
            if (self.result() == null or self.fault != .none) return null;
            if (self.profile == .myna) return (P.myna(self.buffer.?[0..5845]) catch return null).portrait;
            return base.Parser(section).portrait(self.buffer.?[962..2967]) catch null;
        }
        pub fn dismiss(self: *Self) linksection(placement(section)) core.Error!void {
            if (self.state != .done) return error.Busy;
            if (self.buffer) |b| wipe(b);
            wipe(&self.command);
            wipe(&self.pending_pin);
            const serial = self.serial;
            self.* = .{ .serial = serial };
        }
    };
}
