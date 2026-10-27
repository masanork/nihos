//! PIN-free diagnostic APDUs, based on civ 54a843e JPKI read/retry paths.
//! Only the exact case-1 VERIFY (four bytes, no Lc/data/Le) is admitted.
const std = @import("std");
pub const select_ap = [_]u8{ 0, 0xa4, 4, 0x0c, 10, 0xd3, 0x92, 0xf0, 0, 0x26, 1, 0, 0, 0, 1 };
pub const select_pin = [_]u8{ 0, 0xa4, 2, 0x0c, 2, 0, 0x18 };
pub const select_cert = [_]u8{ 0, 0xa4, 2, 0x0c, 2, 0, 0x0a };
pub const query_retries = [_]u8{ 0, 0x20, 0, 0x80 };
pub const read_prefix = [_]u8{ 0, 0xb0, 0, 0, 64 };
pub const Error = error{ Denied, Malformed, Status, CounterChanged, Blocked };
pub fn allowed(apdu_bytes: []const u8) bool {
    for ([_][]const u8{ &select_ap, &select_pin, &select_cert, &query_retries, &read_prefix }) |item|
        if (std.mem.eql(u8, apdu_bytes, item)) return true;
    return false;
}
pub fn ccidAllowed(kind: u8, payload: []const u8) bool {
    return switch (kind) {
        0x62, 0x63 => payload.len == 0,
        0x6f => allowed(payload),
        else => false,
    };
}
pub fn status(bytes: []const u8) Error!u16 {
    if (bytes.len < 2) return error.Malformed;
    return (@as(u16, bytes[bytes.len - 2]) << 8) | bytes[bytes.len - 1];
}
pub fn retries(sw: u16) Error!u32 {
    if (sw & 0xfff0 == 0x63c0) return sw & 15;
    if (sw == 0x6983) return 0;
    if (sw == 0x9000) return 255; // already verified, not a retry count
    return error.Status;
}
const Item = struct { body: usize, length: usize };
fn header(bytes: []const u8, offset: usize, tag: u8) Error!Item {
    if (offset >= bytes.len or bytes.len - offset < 2 or bytes[offset] != tag) return error.Malformed;
    const first = bytes[offset + 1];
    if (first < 128) return .{ .body = offset + 2, .length = first };
    const count = first & 127;
    if (count == 0 or count > 2 or bytes.len - offset < 2 + @as(usize, count) or bytes[offset + 2] == 0) return error.Malformed;
    var length: usize = 0;
    for (bytes[offset + 2 ..][0..count]) |byte| length = (length << 8) | byte;
    if (length < 128 or (count == 2 and length < 256)) return error.Malformed;
    return .{ .body = offset + 2 + count, .length = length };
}
pub fn serialPrefix(bytes: []const u8) Error![]const u8 {
    const cert = try header(bytes, 0, 0x30);
    const tbs = try header(bytes, cert.body, 0x30);
    if (tbs.body + tbs.length > cert.body + cert.length) return error.Malformed;
    var offset = tbs.body;
    if (offset < bytes.len and bytes[offset] == 0xa0) {
        const version = try header(bytes, offset, 0xa0);
        if (version.length != 3 or version.body + 3 > bytes.len or bytes[version.body] != 2 or bytes[version.body + 1] != 1 or bytes[version.body + 2] > 2) return error.Malformed;
        offset = version.body + version.length;
    }
    const serial = try header(bytes, offset, 2);
    if (serial.length == 0 or serial.length > 21 or serial.body + serial.length > bytes.len or
        serial.body + serial.length > tbs.body + tbs.length or bytes[serial.body] & 0x80 != 0) return error.Malformed;
    var value = bytes[serial.body..][0..serial.length];
    if (value.len > 1 and value[0] == 0) {
        if (value[1] & 0x80 == 0) return error.Malformed;
        value = value[1..];
    }
    if (value.len > 20) return error.Malformed;
    return value;
}
pub const Report = struct {
    status: u32 = 0,
    stage: u32 = 0,
    error_code: u32 = 0,
    power_status: u32 = 0,
    power_error: u32 = 0,
    atr_bytes: u32 = 0,
    card_state: u32 = 0,
    apdu_count: u32 = 0,
    rejected: u32 = 0,
    pin_data_sent: u32 = 0,
    auth_before: u32 = 0,
    auth_after: u32 = 0,
    last_sw: u32 = 0,
    serial_bytes: u32 = 0,
    poweroff: u32 = 0,
    serial: [20]u8 = @splat(0),
};
fn command(session: anytype, report: *Report, apdu: []const u8, buffer: []u8) ![]const u8 {
    const result = try session.apdu(apdu, buffer);
    report.apdu_count += 1;
    report.last_sw = try status(result);
    if (report.last_sw != 0x9000) return error.Status;
    return result[0 .. result.len - 2];
}
fn query(session: anytype, report: *Report, buffer: []u8) !u32 {
    _ = try command(session, report, &select_pin, buffer);
    const result = try session.apdu(&query_retries, buffer);
    report.apdu_count += 1;
    report.last_sw = try status(result);
    return retries(@intCast(report.last_sw));
}
pub fn probe(session: anytype, report: *Report) !void {
    var buffer: [512]u8 = @splat(0);
    report.stage = 1;
    const powered = try session.exchange(0x62, &.{}, 0x80, &buffer);
    report.power_status = powered.status;
    report.power_error = powered.code;
    report.card_state = powered.state;
    report.atr_bytes = @intCast(powered.payload.len);
    if (powered.status != 0 or powered.state != 0 or powered.payload.len < 2 or powered.payload.len > 33) return error.Status;
    defer {
        if (session.exchange(0x63, &.{}, 0x81, &buffer)) |off| {
            if (off.status == 0) {
                report.poweroff = 1;
            } else {
                report.status = 2;
                report.error_code = 9;
            }
        } else |_| {
            report.status = 2;
            report.error_code = 9;
        }
    }
    report.stage = 2;
    _ = try command(session, report, &select_ap, &buffer);
    report.stage = 3;
    report.auth_before = try query(session, report, &buffer);
    if (report.auth_before == 0) return error.Blocked;
    report.stage = 4;
    _ = try command(session, report, &select_cert, &buffer);
    const prefix = try command(session, report, &read_prefix, &buffer);
    const serial = try serialPrefix(prefix);
    @memcpy(report.serial[0..serial.len], serial);
    report.serial_bytes = @intCast(serial.len);
    report.stage = 5;
    report.auth_after = try query(session, report, &buffer);
    if (report.auth_before != report.auth_after) return error.CounterChanged;
    report.stage = 6;
    report.status = 1;
}

test "only exact non-PIN APDUs pass and every PIN-bearing VERIFY is rejected" {
    try std.testing.expect(allowed(&query_retries));
    try std.testing.expect(!allowed(&.{ 0, 0x20, 0, 0x80, 0 }));
    for (0..256) |pin_byte| {
        const command_bytes = [_]u8{ 0, 0x20, 0, 0x80, 1, @intCast(pin_byte) };
        try std.testing.expect(!allowed(&command_bytes));
    }
    try std.testing.expect(!allowed(&.{ 0, 0x24, 0, 0x80 }));
    try std.testing.expect(ccidAllowed(0x6f, &query_retries));
    try std.testing.expect(!ccidAllowed(0x6f, &.{ 0, 0x20, 0, 0x80, 4, 0x31, 0x32, 0x33, 0x34 }));
    try std.testing.expect(!ccidAllowed(0x69, &.{})); // no secure PIN operation
    try std.testing.expect(!ccidAllowed(0x6b, &.{ 0xff, 0x50 })); // no escape bypass
    try std.testing.expect(!ccidAllowed(0x62, &query_retries));
    try std.testing.expectEqual(@as(u32, 3), try retries(0x63c3));
    try std.testing.expectEqual(@as(u32, 0), try retries(0x6983));
    try std.testing.expectEqual(@as(u32, 255), try retries(0x9000));
}
test "extract serial from bounded certificate prefix without reading whole certificate" {
    const prefix = [_]u8{ 0x30, 0x82, 4, 0, 0x30, 0x82, 3, 0, 0xa0, 3, 2, 1, 2, 2, 3, 0, 0x81, 0x23 };
    try std.testing.expectEqualSlices(u8, &.{ 0x81, 0x23 }, try serialPrefix(&prefix));
    for (0..prefix.len) |length| try std.testing.expectError(error.Malformed, serialPrefix(prefix[0..length]));
}

const Model = struct {
    calls: u32 = 0,
    queries: u32 = 0,
    changed: bool = false,
    absent: bool = false,
    const Reply = struct { payload: []const u8, status: u2 = 0, state: u2 = 0, code: u8 = 0 };
    pub fn exchange(self: *@This(), kind: u8, _: []const u8, _: u8, _: []u8) !Reply {
        if (kind == 0x63) return .{ .payload = &.{}, .state = 1 };
        return .{ .payload = if (self.absent) &.{} else &.{ 0x3b, 0x80 }, .state = if (self.absent) 2 else 0 };
    }
    pub fn apdu(self: *@This(), bytes: []const u8, _: []u8) ![]const u8 {
        if (!allowed(bytes)) return error.Denied;
        const order = [_][]const u8{ &select_ap, &select_pin, &query_retries, &select_cert, &read_prefix, &select_pin, &query_retries };
        if (self.calls >= order.len or !std.mem.eql(u8, order[self.calls], bytes)) return error.Denied;
        self.calls += 1;
        if (std.mem.eql(u8, bytes, &query_retries)) {
            self.queries += 1;
            return if (self.changed and self.queries == 2) &.{ 0x63, 0xc2 } else &.{ 0x63, 0xc3 };
        }
        if (std.mem.eql(u8, bytes, &read_prefix)) return &.{ 0x30, 0x82, 4, 0, 0x30, 0x82, 3, 0, 0xa0, 3, 2, 1, 2, 2, 3, 0, 0x81, 0x23, 0x90, 0 };
        return &.{ 0x90, 0 };
    }
};
test "PIN-free sequence compares retry counters and powers off on completion or failure" {
    var model = Model{};
    var report = Report{};
    try probe(&model, &report);
    try std.testing.expectEqual(@as(u32, 7), model.calls);
    try std.testing.expectEqual(@as(u32, 3), report.auth_before);
    try std.testing.expectEqual(@as(u32, 3), report.auth_after);
    try std.testing.expectEqual(@as(u32, 2), report.serial_bytes);
    try std.testing.expectEqual(@as(u32, 1), report.poweroff);
    try std.testing.expectEqual(@as(u32, 0), report.pin_data_sent);
    var changed = Model{ .changed = true };
    var failed = Report{};
    try std.testing.expectError(error.CounterChanged, probe(&changed, &failed));
    try std.testing.expectEqual(@as(u32, 1), failed.poweroff);
    try std.testing.expectEqual(@as(u32, 0), failed.status);
    var absent = Model{ .absent = true };
    var missing = Report{};
    try std.testing.expectError(error.Status, probe(&absent, &missing));
    try std.testing.expectEqual(@as(u32, 0), absent.calls);
}
