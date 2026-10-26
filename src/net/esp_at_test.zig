const std = @import("std");
const at = @import("esp_at.zig");

fn quiet(decoder: *at.Decoder, bytes: []const u8) !void {
    for (bytes) |byte| try std.testing.expect(try decoder.push(byte) == null);
}

fn event(decoder: *at.Decoder, bytes: []const u8) !at.Event {
    var result: ?at.Event = null;
    for (bytes) |byte| {
        if (try decoder.push(byte)) |item| {
            try std.testing.expect(result == null);
            result = item;
        }
    }
    return result orelse error.MissingEvent;
}

test "passive availability and fragmented lines do not complete a command" {
    var decoder: at.Decoder = .{};
    try quiet(&decoder, "\r\n+IPD,4,");
    const available = (try event(&decoder, "5760\r\n")).available;
    try std.testing.expectEqual(@as(u8, 4), available.link);
    try std.testing.expectEqual(@as(u32, 5760), available.count);
    try std.testing.expectEqualStrings("WIFI DISCONNECT", (try event(&decoder, "WIFI DISCONNECT\r\n")).line);
    try quiet(&decoder, "O");
    try std.testing.expectEqualStrings("OK", (try event(&decoder, "K\r\n")).line);
}

test "socket binary is length delimited even when it contains terminal responses" {
    var decoder: at.Decoder = .{};
    const payload = "\x00\r\nOK\r\nERROR\r\n>";
    try decoder.expectSocketRead(3, 64);
    try quiet(&decoder, "+CIPRECVDATA:15,");
    try quiet(&decoder, payload[0..5]);
    const data = (try event(&decoder, payload[5..])).data;
    try std.testing.expectEqual(.socket, data.kind);
    try std.testing.expectEqual(@as(u8, 3), data.link);
    try std.testing.expectEqualSlices(u8, payload, data.bytes);
    try std.testing.expectError(error.Busy, decoder.endCommand());
    try quiet(&decoder, "\r\n");
    try std.testing.expectEqualStrings("OK", (try event(&decoder, "OK\r\n")).line);
    try decoder.endCommand();
}

test "BLE notification may interleave a pending passive socket read" {
    var decoder: at.Decoder = .{};
    try decoder.expectSocketRead(1, 8);
    try quiet(&decoder, "+NOTIFY:2,3,6,7,");
    const notice = (try event(&decoder, "\r\nOK\x00,>")).data;
    try std.testing.expectEqual(.notify, notice.kind);
    try std.testing.expectEqual(@as(u8, 2), notice.link);
    try std.testing.expectEqual(@as(u16, 3), notice.service);
    try std.testing.expectEqual(@as(u16, 6), notice.characteristic);
    try std.testing.expectEqualSlices(u8, "\r\nOK\x00,>", notice.bytes);
    try quiet(&decoder, "\r\n+CIPRECVDATA:3,");
    const socket = (try event(&decoder, "abc")).data;
    try std.testing.expectEqual(.socket, socket.kind);
    try std.testing.expectEqual(@as(u8, 1), socket.link);
    try std.testing.expectEqualSlices(u8, "abc", socket.bytes);
    try quiet(&decoder, "\r\n");
    const empty = (try event(&decoder, "+INDICATE:0,65535,65535,0,")).data;
    try std.testing.expectEqual(.indicate, empty.kind);
    try std.testing.expectEqual(@as(usize, 0), empty.bytes.len);
    try quiet(&decoder, "\r\n");
}

test "send prompt is explicitly armed and does not treat binary greater-than as a prompt" {
    var decoder: at.Decoder = .{};
    try decoder.expectPrompt();
    try std.testing.expectEqualStrings("OK", (try event(&decoder, "\r\nOK\r\n")).line);
    try std.testing.expectEqual(at.Event.prompt, try event(&decoder, ">"));
    try quiet(&decoder, " ");
    try std.testing.expectEqualStrings("SEND OK", (try event(&decoder, "\r\nSEND OK\r\n")).line);
    try decoder.endCommand();
    try std.testing.expectError(error.UnexpectedData, decoder.push('>'));
    try std.testing.expectError(error.Failed, decoder.push('\n'));
}

test "terminal ERROR releases unused read and prompt expectations explicitly" {
    var decoder: at.Decoder = .{};
    try decoder.expectSocketRead(0, 1);
    try std.testing.expectEqualStrings("ERROR", (try event(&decoder, "ERROR\r\n")).line);
    try decoder.endCommand();
    try decoder.expectPrompt();
    try std.testing.expectEqualStrings("ERROR", (try event(&decoder, "ERROR\r\n")).line);
    try decoder.endCommand();
    try decoder.expectSocketRead(4, 1);
}

test "oversized and malformed binary headers poison framing before payload parsing" {
    const cases = [_]struct { bytes: []const u8, failure: at.Error }{
        .{ .bytes = "+CIPRECVDATA:1025,", .failure = error.PayloadTooLong },
        .{ .bytes = "+CIPRECVDATA:4294967296,", .failure = error.InvalidHeader },
        .{ .bytes = "+CIPRECVDATA:-1,", .failure = error.InvalidHeader },
        .{ .bytes = "+CIPRECVDATA:1\r\n", .failure = error.InvalidHeader },
        .{ .bytes = "+NOTIFY:0,1,1,513,", .failure = error.PayloadTooLong },
        .{ .bytes = "+NOTIFY:3,1,1,1,", .failure = error.InvalidHeader },
        .{ .bytes = "+INDICATE:0,65536,1,1,", .failure = error.InvalidHeader },
        .{ .bytes = "+INDICATE:0,1,1,\r\n", .failure = error.InvalidHeader },
        .{ .bytes = "+IPD,0,1:", .failure = error.UnsupportedProfile },
        .{ .bytes = "+WRITE:", .failure = error.UnsupportedProfile },
        .{ .bytes = "+BLEGATTCRD:", .failure = error.UnsupportedProfile },
        .{ .bytes = "+IPD,5,1\r\n", .failure = error.InvalidHeader },
    };
    for (cases) |case| {
        var decoder: at.Decoder = .{};
        try decoder.expectSocketRead(0, at.payload_capacity);
        try std.testing.expectError(case.failure, quiet(&decoder, case.bytes));
        try std.testing.expectError(error.Failed, decoder.push('O'));
    }
}

test "unsolicited reads and exceeding the requested read bound are rejected" {
    var decoder: at.Decoder = .{};
    try std.testing.expectError(error.UnexpectedData, quiet(&decoder, "+CIPRECVDATA:1,"));
    decoder = .{};
    try decoder.expectSocketRead(0, 4);
    try std.testing.expectError(error.PayloadTooLong, quiet(&decoder, "+CIPRECVDATA:5,"));
    decoder = .{};
    try std.testing.expectError(error.InvalidHeader, decoder.expectSocketRead(5, 1));
    try std.testing.expectError(error.InvalidHeader, decoder.expectSocketRead(0, 0));
    try std.testing.expectError(error.InvalidHeader, decoder.expectSocketRead(0, at.payload_capacity + 1));
}

test "maximum bounded payload and mandatory trailer survive bytewise delivery" {
    var decoder: at.Decoder = .{};
    try decoder.expectSocketRead(0, at.payload_capacity);
    try quiet(&decoder, "+CIPRECVDATA:1024,");
    for (0..at.payload_capacity - 1) |i| try std.testing.expect(try decoder.push(@truncate(i)) == null);
    const data = (try decoder.push(255)).?.data;
    try std.testing.expectEqual(@as(usize, at.payload_capacity), data.bytes.len);
    for (data.bytes, 0..) |byte, i| try std.testing.expectEqual(@as(u8, @truncate(i)), byte);
    try std.testing.expectError(error.InvalidText, decoder.push('O'));
}

test "line bounds, invalid terminators and truncated transfer abort fail closed" {
    var decoder: at.Decoder = .{};
    for (0..at.line_capacity) |_| try std.testing.expect(try decoder.push('a') == null);
    try std.testing.expectError(error.LineTooLong, decoder.push('b'));
    decoder = .{};
    try std.testing.expectError(error.InvalidText, decoder.push('\n'));
    decoder = .{};
    try quiet(&decoder, "OK\r");
    try std.testing.expectError(error.InvalidText, decoder.push('X'));
    decoder = .{};
    try decoder.expectSocketRead(0, 8);
    try quiet(&decoder, "+CIPRECVDATA:8,abc");
    decoder.abort();
    try std.testing.expectError(error.Failed, decoder.push('d'));
    try std.testing.expectError(error.Failed, decoder.expectPrompt());
}

test "control lines preserve UTF-8 and BLE records accept the full bounded size" {
    var decoder: at.Decoder = .{};
    const line = "+CWJAP:\"教室\"";
    try std.testing.expectEqualStrings(line, (try event(&decoder, line ++ "\r\n")).line);
    try quiet(&decoder, "+NOTIFY:0,1,1,512,");
    for (0..511) |_| try std.testing.expect(try decoder.push(0) == null);
    const data = (try decoder.push(0)).?.data;
    try std.testing.expectEqual(@as(usize, 512), data.bytes.len);
    try quiet(&decoder, "\r\n");
}

test "command timeout prevents a delayed OK completing a newer request" {
    var gate: at.CommandGate = .{};
    try std.testing.expectError(error.NotSynchronized, gate.begin(0, 100));
    try gate.establish();
    const first = try gate.begin(0, 100);
    try std.testing.expectError(error.Busy, gate.begin(0, 100));
    try std.testing.expect(gate.expire(99) == null);
    try std.testing.expectEqual(first, gate.expire(100).?);
    try std.testing.expectError(error.NotSynchronized, gate.begin(100, 200));
    try std.testing.expectError(error.Stale, gate.complete(first, 101));
    try gate.establish();
    const second = try gate.begin(101, 200);
    try std.testing.expect(first.epoch != second.epoch);
    try std.testing.expectError(error.Stale, gate.complete(first, 102));
    try std.testing.expectEqual(second, gate.pending.?.token);
    try gate.complete(second, 199);
    try std.testing.expectError(error.Stale, gate.complete(second, 199));
    const third = try gate.begin(199, 300);
    try std.testing.expect(third.serial != second.serial);
    try std.testing.expectError(error.Stale, gate.complete(second, 199));
    try std.testing.expectEqual(third, gate.pending.?.token);
}

test "deadline is checked at completion even when expiration has not been polled" {
    var gate: at.CommandGate = .{};
    try gate.establish();
    try std.testing.expectError(error.InvalidDeadline, gate.begin(10, 10));
    try std.testing.expectError(error.InvalidDeadline, gate.begin(10, 9));
    const token = try gate.begin(10, 20);
    try std.testing.expectError(error.NotSynchronized, gate.complete(token, 20));
    try std.testing.expect(!gate.synchronized);
    try std.testing.expect(gate.pending == null);
}

test "reset invalidates active commands and identifier exhaustion never wraps" {
    var gate: at.CommandGate = .{};
    try gate.establish();
    try std.testing.expectError(error.Busy, gate.establish());
    const token = try gate.begin(0, 1);
    gate.invalidate();
    try std.testing.expectError(error.Stale, gate.complete(token, 0));
    try gate.establish();
    gate.serial = std.math.maxInt(u64);
    try std.testing.expectError(error.Exhausted, gate.begin(0, 1));
    gate.invalidate();
    gate.epoch = std.math.maxInt(u64);
    try std.testing.expectError(error.Exhausted, gate.establish());
    try std.testing.expect(!gate.synchronized);
}
