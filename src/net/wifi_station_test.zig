const std = @import("std");
const control = @import("at_controller.zig");
const wifi = control.wifi;

fn receive(owner: *control.Controller, probe: *wifi.Probe, bytes: []const u8) !void {
    for (bytes) |byte| if (try owner.push(byte, 2)) |notice| switch (notice) {
        .line => |line| try probe.line(line),
        else => {},
    };
}

fn associated(probe: *wifi.Probe) !void {
    try probe.complete();
    try probe.line("+CWDHCP:3");
    try probe.complete();
    try probe.line("WIFI CONNECTED");
    try probe.line("WIFI GOT IP");
    try probe.complete();
    try probe.line("+CWSTATE:2,\"test\"");
    try probe.complete();
}

test "station sequence commits a lease only after complete successful transactions" {
    var owner: control.Controller = .{};
    var probe: wifi.Probe = .{};
    try owner.recover(0, 100);
    for (control.profile) |_| {
        const count = (try owner.tx(1)).len;
        try owner.consumeTx(count, 1);
        try receive(&owner, &probe, "OK\r\n");
    }
    const expected = [_][]const u8{
        "AT+CWDHCP=1,1\r\n", "AT+CWDHCP?\r\n", "AT+CWJAP\r\n", "AT+CWSTATE?\r\n", "AT+CIPSTA?\r\n",
    };
    const replies = [_][]const u8{
        "OK\r\n",                        "+CWDHCP:1\r\nOK\r\n",                                                                                           "WIFI CONNECTED\r\nWIFI GOT IP\r\nOK\r\n",
        "+CWSTATE:2,\"test\"\r\nOK\r\n", "+CIPSTA:ip:\"192.168.7.12\"\r\n+CIPSTA:gateway:\"192.168.7.1\"\r\n+CIPSTA:netmask:\"255.255.255.0\"\r\nOK\r\n",
    };
    for (expected, replies) |command, reply| {
        _ = try owner.submit(try probe.command(.saved), 2, 100);
        try std.testing.expectEqualStrings(command, try owner.tx(2));
        try owner.consumeTx(command.len, 2);
        try receive(&owner, &probe, reply);
        try std.testing.expect(probe.step != .done);
        try std.testing.expect(owner.takeCompletion().?.failure == null);
        try probe.complete();
    }
    try std.testing.expectEqual(wifi.Step.done, probe.step);
    try std.testing.expectEqual(@as(u32, 0xc0a8070c), probe.ip.?);
    try std.testing.expectEqual(@as(u32, 1), probe.got_ip_events);
    // A later disconnect revokes even an already completed lease.
    try std.testing.expectError(error.Disconnected, probe.line("WIFI DISCONNECT"));
    try std.testing.expect(probe.ip == null);
}

test "DHCP and station evidence cannot be missing duplicated or static" {
    var probe: wifi.Probe = .{};
    try probe.complete();
    try std.testing.expectError(error.MissingReply, probe.complete());
    try probe.line("+CWDHCP:0");
    try std.testing.expectError(error.DhcpDisabled, probe.complete());
    try std.testing.expectError(error.InvalidReply, probe.line("+CWDHCP:1"));
    probe = .{};
    try probe.complete();
    try probe.line("+CWDHCP:1");
    try probe.complete();
    try probe.complete();
    try probe.line("+CWSTATE:1,\"test\"");
    try std.testing.expectError(error.NotConnected, probe.complete());
    probe = .{};
    try associated(&probe);
    try std.testing.expectError(error.Disconnected, probe.line("WIFI DISCONNECT"));
    try std.testing.expectError(error.Disconnected, probe.complete());
}

test "reject malformed stale zero multicast and off-subnet lease replies" {
    for ([_][]const u8{
        "\"0.0.0.0\"",     "\"127.0.0.1\"",     "\"224.1.2.3\"", "\"169.254.1.2\"", "\"10.0.0.12\"",
        "\"192.168.7.0\"", "\"192.168.7.255\"",
    }) |ip| {
        var probe: wifi.Probe = .{};
        try associated(&probe);
        var buffer: [64]u8 = undefined;
        try probe.line(try std.fmt.bufPrint(&buffer, "+CIPSTA:ip:{s}", .{ip}));
        try probe.line("+CIPSTA:gateway:\"192.168.7.1\"");
        try probe.line("+CIPSTA:netmask:\"255.255.255.0\"");
        try std.testing.expectError(error.InvalidLease, probe.complete());
    }
    for ([_][]const u8{ "\"1.2.3.256\"", "\"1.2.3\"", "\"1.2.3.4.5\"", "\"+1.2.3.4\"", "1.2.3.4" }) |ip| {
        var probe: wifi.Probe = .{};
        try associated(&probe);
        var buffer: [64]u8 = undefined;
        try std.testing.expectError(error.InvalidReply, probe.line(try std.fmt.bufPrint(&buffer, "+CIPSTA:ip:{s}", .{ip})));
    }
    var probe: wifi.Probe = .{};
    try std.testing.expectError(error.InvalidReply, probe.line("+CIPSTA:ip:\"192.168.7.12\""));
    try associated(&probe);
    try probe.line("+CIPSTA:ip:\"192.168.7.12\"");
    try std.testing.expectError(error.InvalidReply, probe.line("+CIPSTA:ip:\"192.168.7.12\""));
    try std.testing.expectError(error.MissingReply, probe.complete());
}

test "lease lines followed by AT ERROR cannot complete the station check" {
    var owner: control.Controller = .{};
    var probe: wifi.Probe = .{};
    try owner.recover(0, 100);
    for (control.profile) |_| {
        try owner.consumeTx((try owner.tx(1)).len, 1);
        try receive(&owner, &probe, "OK\r\n");
    }
    try associated(&probe);
    _ = try owner.submit(try probe.command(.saved), 2, 100);
    try owner.consumeTx((try owner.tx(2)).len, 2);
    try receive(&owner, &probe, "+CIPSTA:ip:\"192.168.7.12\"\r\n+CIPSTA:gateway:\"192.168.7.1\"\r\n+CIPSTA:netmask:\"255.255.255.0\"\r\nERROR\r\n");
    try std.testing.expectEqual(control.Failure.rejected, owner.takeCompletion().?.failure.?);
    try std.testing.expectEqual(wifi.Step.addresses, probe.step);
}
