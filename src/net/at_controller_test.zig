const std = @import("std");
const controller = @import("at_controller.zig");
const commands = controller.commands;

fn quiet(owner: *controller.Controller, bytes: []const u8, now: u64) !void {
    for (bytes) |byte| try std.testing.expect(try owner.push(byte, now) == null);
}

fn line(owner: *controller.Controller, bytes: []const u8, now: u64) !controller.Notice {
    var notice: ?controller.Notice = null;
    for (bytes) |byte| {
        if (try owner.push(byte, now)) |item| {
            try std.testing.expect(notice == null);
            notice = item;
        }
    }
    return notice orelse error.MissingNotice;
}

fn drain(owner: *controller.Controller, expected: []const u8, now: u64) !void {
    try std.testing.expectEqualSlices(u8, expected, try owner.tx(now));
    // Exercise a one-byte transport repeatedly, including zero-progress writes.
    try owner.consumeTx(0, now);
    for (expected, 0..) |_, i| {
        try std.testing.expectEqualSlices(u8, expected[i..], try owner.tx(now));
        try owner.consumeTx(1, now);
    }
    try std.testing.expectEqual(@as(usize, 0), (try owner.tx(now)).len);
}

fn boot(owner: *controller.Controller) !void {
    try owner.recover(0, 100);
    for (controller.profile, 0..) |command, i| {
        try std.testing.expect(!owner.ready());
        try drain(owner, command, 1);
        if (i == controller.profile.len - 1) {
            try std.testing.expectEqual(controller.Notice.profile_ready, try line(owner, "\r\nOK\r\n", 2));
        } else try quiet(owner, "\r\nOK\r\n", 2);
    }
    try std.testing.expect(owner.ready());
    try std.testing.expect(owner.takeCompletion() == null);
}

test "profile negotiation gates application commands and handles partial transport writes" {
    var owner: controller.Controller = .{};
    try std.testing.expectError(error.NotReady, owner.submit(.version, 0, 100));
    try boot(&owner);
    const token = try owner.submit(.version, 3, 100);
    try drain(&owner, "AT+GMR\r\n", 4);
    try std.testing.expectEqualStrings("AT version:test", (try line(&owner, "AT version:test\r\n", 5)).line);
    try quiet(&owner, "OK\r\n", 5);
    try std.testing.expectError(error.Busy, owner.submit(.memory, 5, 100));
    const result = owner.takeCompletion().?;
    try std.testing.expectEqual(token, result.token);
    try std.testing.expect(result.failure == null);
    _ = try owner.submit(.memory, 6, 100);
}

test "TCP send waits for OK, prompt, all payload bytes and SEND OK" {
    var owner: controller.Controller = .{};
    try boot(&owner);
    var payload = [_]u8{ 0, '\r', '\n', 'O', 'K', '>' };
    const token = try owner.submit(.{ .socket_send = .{ .link = 2, .bytes = &payload } }, 3, 100);
    @memset(&payload, 0xff); // Submission owns a copy, including embedded NUL.
    try drain(&owner, "AT+CIPSEND=2,6\r\n", 4);
    try quiet(&owner, "\r\nOK\r\n", 5);
    try std.testing.expect(owner.takeCompletion() == null);
    const available = (try line(&owner, "+IPD,1,4\r\n", 5)).available;
    try std.testing.expectEqual(@as(u8, 1), available.link);
    try quiet(&owner, ">", 5);
    try std.testing.expectEqualSlices(u8, "\x00\r\nOK>", try owner.tx(6));
    try owner.consumeTx(2, 6);
    try std.testing.expectEqualSlices(u8, "\nOK>", try owner.tx(6));
    try owner.consumeTx(4, 6);
    try std.testing.expect(owner.takeCompletion() == null);
    try quiet(&owner, " \r\nSEND OK\r\n", 7);
    try std.testing.expectEqual(token, owner.takeCompletion().?.token);
    try std.testing.expect(owner.ready());
}

test "socket read commits only after OK and survives interleaved BLE payload storage" {
    var owner: controller.Controller = .{};
    try boot(&owner);
    _ = try owner.submit(.{ .socket_read = .{ .link = 1, .limit = 16 } }, 3, 100);
    try drain(&owner, "AT+CIPRECVDATA=1,16\r\n", 4);
    try quiet(&owner, "+CIPRECVDATA:7,\r\nOK\x00,>\r\n", 5);
    try std.testing.expect(owner.takeCompletion() == null);
    const notification = (try line(&owner, "+NOTIFY:0,3,6,3,abc", 5)).data;
    try std.testing.expectEqualSlices(u8, "abc", notification.bytes);
    try quiet(&owner, "\r\nOK\r\n", 6);
    const result = owner.takeCompletion().?;
    try std.testing.expect(result.failure == null);
    try std.testing.expectEqualSlices(u8, "\r\nOK\x00,>", result.bytes);
    // Subsequent unsolicited bytes cannot overwrite the read completion.
    _ = try line(&owner, "+INDICATE:0,3,6,3,xyz", 7);
    try quiet(&owner, "\r\n", 7);
    try std.testing.expectEqualSlices(u8, "\r\nOK\x00,>", result.bytes);
}

test "BLE CCCD write uses a prompt without initial OK and final OK" {
    var owner: controller.Controller = .{};
    try boot(&owner);
    _ = try owner.submit(.{ .ble_write = .{ .link = 0, .service = 3, .characteristic = 6, .descriptor = 1, .bytes = &.{ 1, 0 } } }, 3, 100);
    try drain(&owner, "AT+BLEGATTCWR=0,3,6,1,2\r\n", 4);
    try quiet(&owner, ">", 5);
    try drain(&owner, "\x01\x00", 6);
    try quiet(&owner, "\r\nOK\r\n", 7);
    try std.testing.expect(owner.takeCompletion().?.failure == null);
}

test "rejected read releases expectations and sends no payload" {
    var owner: controller.Controller = .{};
    try boot(&owner);
    _ = try owner.submit(.{ .socket_read = .{ .link = 0, .limit = 8 } }, 3, 100);
    try drain(&owner, "AT+CIPRECVDATA=0,8\r\n", 4);
    try quiet(&owner, "ERROR\r\n", 5);
    try std.testing.expectEqual(controller.Failure.rejected, owner.takeCompletion().?.failure.?);
    _ = try owner.submit(.{ .socket_send = .{ .link = 0, .bytes = "abc" } }, 6, 100);
    try drain(&owner, "AT+CIPSEND=0,3\r\n", 7);
    try quiet(&owner, "ERROR\r\n", 8);
    try std.testing.expectEqual(controller.Failure.rejected, owner.takeCompletion().?.failure.?);
    try std.testing.expectEqual(@as(usize, 0), (try owner.tx(8)).len);
}

test "send failure is terminal but a plain OK after payload is not SEND OK" {
    for ([_][]const u8{ "SEND FAIL\r\n", "ERROR\r\n", "OK\r\n" }) |response| {
        var owner: controller.Controller = .{};
        try boot(&owner);
        _ = try owner.submit(.{ .socket_send = .{ .link = 0, .bytes = "abc" } }, 3, 100);
        try drain(&owner, "AT+CIPSEND=0,3\r\n", 4);
        try quiet(&owner, "OK\r\n>", 5);
        try drain(&owner, "abc", 6);
        if (std.mem.eql(u8, response, "OK\r\n")) {
            try std.testing.expectError(error.Protocol, quiet(&owner, response, 7));
            try std.testing.expectEqual(controller.Failure.protocol, owner.takeCompletion().?.failure.?);
        } else {
            try quiet(&owner, response, 7);
            try std.testing.expectEqual(controller.Failure.rejected, owner.takeCompletion().?.failure.?);
            try std.testing.expect(owner.ready());
        }
    }
}

test "partial unsolicited frames defer submission without consuming a command token" {
    var owner: controller.Controller = .{};
    try boot(&owner);
    const serial = owner.gate.serial;
    try quiet(&owner, "+NOTIFY:0,3,6,3,a", 3);
    try std.testing.expectError(error.Busy, owner.submit(.version, 3, 100));
    try std.testing.expectEqual(serial, owner.gate.serial);
    try std.testing.expectEqualSlices(u8, "abc", (try line(&owner, "bc", 4)).data.bytes);
    try quiet(&owner, "\r\n", 4);
    _ = try owner.submit(.version, 5, 100);
}

test "timeout after partial TX retains one failure and forces a new epoch and profile" {
    var owner: controller.Controller = .{};
    try boot(&owner);
    const old = try owner.submit(.version, 3, 10);
    try owner.consumeTx(1, 4);
    try std.testing.expectError(error.TimedOut, owner.push('O', 10));
    try std.testing.expectError(error.NotReady, owner.submit(.version, 11, 100));
    try std.testing.expectError(error.Busy, owner.recover(11, 100));
    const result = owner.takeCompletion().?;
    try std.testing.expectEqual(old, result.token);
    try std.testing.expectEqual(controller.Failure.timeout, result.failure.?);
    try std.testing.expect(owner.takeCompletion() == null);
    try boot(&owner); // The adapter supplies a fresh physical stream before boot.
    const current = try owner.submit(.version, 3, 100);
    try std.testing.expect(current.epoch != old.epoch);
}

test "reset during a binary read discards provisional bytes and invalidates the request" {
    var owner: controller.Controller = .{};
    try boot(&owner);
    _ = try owner.submit(.{ .socket_read = .{ .link = 0, .limit = 3 } }, 3, 100);
    try drain(&owner, "AT+CIPRECVDATA=0,3\r\n", 4);
    try quiet(&owner, "+CIPRECVDATA:3,abc\r\n", 5);
    try std.testing.expectError(error.LinkReset, quiet(&owner, "ready\r\n", 6));
    const result = owner.takeCompletion().?;
    try std.testing.expectEqual(controller.Failure.reset, result.failure.?);
    try std.testing.expectEqual(@as(usize, 0), result.bytes.len);
    try std.testing.expect(!owner.ready());
}

test "impossible response phases fail closed instead of releasing the command slot" {
    const cases = [_]struct { response: []const u8, failure: controller.Error }{
        .{ .response = ">", .failure = error.Protocol },
        .{ .response = "SEND OK\r\n", .failure = error.Protocol },
        .{ .response = "OK\r\nOK\r\n", .failure = error.Protocol },
        .{ .response = "busy p...\r\n", .failure = error.Protocol },
    };
    for (cases) |case| {
        var owner: controller.Controller = .{};
        try boot(&owner);
        _ = try owner.submit(.{ .socket_send = .{ .link = 0, .bytes = "abc" } }, 3, 100);
        try drain(&owner, "AT+CIPSEND=0,3\r\n", 4);
        try std.testing.expectError(case.failure, quiet(&owner, case.response, 5));
        try std.testing.expectEqual(controller.Failure.protocol, owner.takeCompletion().?.failure.?);
    }
}

test "terminal response cannot overtake partial command or payload TX" {
    var owner: controller.Controller = .{};
    try boot(&owner);
    _ = try owner.submit(.version, 3, 100);
    try owner.consumeTx(1, 4);
    try std.testing.expectError(error.Protocol, quiet(&owner, "OK\r\n", 5));
    _ = owner.takeCompletion();
    try boot(&owner);
    _ = try owner.submit(.{ .socket_send = .{ .link = 0, .bytes = "abc" } }, 3, 100);
    try drain(&owner, "AT+CIPSEND=0,3\r\n", 4);
    try quiet(&owner, "OK\r\n>", 5);
    try owner.consumeTx(1, 6);
    try std.testing.expectError(error.Protocol, quiet(&owner, "SEND OK\r\n", 7));
}

test "lost input, invalid TX count and cancellation invalidate active commands" {
    var owner: controller.Controller = .{};
    try boot(&owner);
    _ = try owner.submit(.version, 3, 100);
    try std.testing.expectError(error.InvalidTransfer, owner.consumeTx(999, 4));
    try std.testing.expectEqual(controller.Failure.transport, owner.takeCompletion().?.failure.?);
    try boot(&owner);
    _ = try owner.submit(.version, 3, 100);
    owner.transportFailed();
    try std.testing.expectEqual(controller.Failure.transport, owner.takeCompletion().?.failure.?);
    try boot(&owner);
    _ = try owner.submit(.version, 3, 100);
    owner.cancel();
    try std.testing.expectEqual(controller.Failure.cancelled, owner.takeCompletion().?.failure.?);
}

test "boot failure, deadline overflow and an unsolicited terminal response require recovery" {
    var owner: controller.Controller = .{};
    try std.testing.expectError(error.InvalidDeadline, owner.recover(0, 0));
    try std.testing.expectError(error.InvalidDeadline, owner.recover(std.math.maxInt(u64), 1));
    try owner.recover(0, 100);
    try drain(&owner, "AT\r\n", 1);
    try std.testing.expectError(error.Rejected, quiet(&owner, "ERROR\r\n", 2));
    try std.testing.expectEqual(controller.Failure.rejected, owner.last_failure.?);
    try std.testing.expect(owner.takeCompletion() == null);
    try boot(&owner);
    try std.testing.expectError(error.Protocol, quiet(&owner, "OK\r\n", 3));
}

test "command quoting prevents injection and failed validation leaves the owner usable" {
    var buffer: [512]u8 = @splat(0);
    const encoded = try commands.encode(&buffer, .{ .wifi_join = .{ .ssid = "教室,\"\\", .password = "" } });
    try std.testing.expectEqualStrings("AT+CWJAP=\"教室\\,\\\"\\\\\",\"\"\r\n", encoded.bytes);
    try std.testing.expectError(error.InvalidArgument, commands.encode(&buffer, .{ .wifi_join = .{ .ssid = "a\r\nAT+RST", .password = "b" } }));
    try std.testing.expectError(error.InvalidArgument, commands.encode(&buffer, .{ .tcp_connect = .{ .link = 0, .host = "a\x00b", .port = 80 } }));
    var tiny: [1]u8 = @splat(0);
    try std.testing.expectError(error.CommandTooLong, commands.encode(&tiny, .version));
    var owner: controller.Controller = .{};
    try boot(&owner);
    try std.testing.expectError(error.InvalidArgument, owner.submit(.{ .socket_read = .{ .link = 5, .limit = 1 } }, 3, 100));
    try std.testing.expectError(error.InvalidDeadline, owner.submit(.version, 3, 3));
    _ = try owner.submit(.version, 3, 100);
}

test "typed TCP and BLE commands encode bounded profile operations" {
    var buffer: [512]u8 = @splat(0);
    const cases = [_]struct { command: commands.Command, text: []const u8 }{
        .{ .command = .memory, .text = "AT+SYSRAM?\r\n" },
        .{ .command = .{ .tcp_connect = .{ .link = 4, .host = "echo.local", .port = 8080 } }, .text = "AT+CIPSTART=4,\"TCP\",\"echo.local\",8080\r\n" },
        .{ .command = .{ .socket_close = 4 }, .text = "AT+CIPCLOSE=4\r\n" },
        .{ .command = .{ .ble_scan = 3 }, .text = "AT+BLESCAN=1,3\r\n" },
        .{ .command = .{ .ble_scan = null }, .text = "AT+BLESCAN=0\r\n" },
        .{ .command = .{ .ble_connect = .{ .link = 2, .address = "01:23:45:67:89:ab" } }, .text = "AT+BLECONN=2,\"01:23:45:67:89:ab\"\r\n" },
        .{ .command = .{ .ble_disconnect = 2 }, .text = "AT+BLEDISCONN=2\r\n" },
        .{ .command = .{ .ble_services = 1 }, .text = "AT+BLEGATTCPRIMSRV=1\r\n" },
        .{ .command = .{ .ble_characteristics = .{ .link = 1, .service = 3 } }, .text = "AT+BLEGATTCCHAR=1,3\r\n" },
        .{ .command = .{ .ble_write = .{ .link = 1, .service = 3, .characteristic = 6, .bytes = "a" } }, .text = "AT+BLEGATTCWR=1,3,6,,1\r\n" },
    };
    for (cases) |case| try std.testing.expectEqualStrings(case.text, (try commands.encode(&buffer, case.command)).bytes);
    const invalid = [_]commands.Command{
        .{ .ble_scan = 0 },                                       .{ .ble_scan = 61 },                                                                                .{ .socket_send = .{ .link = 0, .bytes = "" } },
        .{ .socket_read = .{ .link = 0, .limit = 1025 } },        .{ .ble_connect = .{ .link = 0, .address = "bad" } },                                               .{ .ble_connect = .{ .link = 0, .address = "zz:23:45:67:89:ab" } },
        .{ .ble_characteristics = .{ .link = 0, .service = 0 } }, .{ .ble_write = .{ .link = 0, .service = 1, .characteristic = 1, .descriptor = 0, .bytes = "x" } },
    };
    for (invalid) |command| try std.testing.expectError(error.InvalidArgument, commands.encode(&buffer, command));
}
