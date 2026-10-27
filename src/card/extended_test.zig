const std = @import("std");
const t = std.testing;
const core = @import("service.zig");
const license = @import("license.zig");
const policy = @import("wire_policy.zig");
const ccid = @import("ccid");
fn reply(service: anytype, bytes: []const u8) !void {
    const action = (try service.take()).?;
    try service.complete(action.token, bytes);
}
fn ready(service: *core.ExtendedService, bytes: []u8) !void {
    try service.startLicenseWith(license.Parser(null), bytes);
    const replies = [_][]const u8{ &.{ 0x3b, 0x80 }, &.{ 0x90, 0 }, &.{ 0x90, 0 }, &.{ 5, 1, 1, 0x90, 0 }, &.{ 0x90, 0 }, &.{ 0x90, 0 }, &.{ 0x63, 0xc3 }, &.{ 0x90, 0 }, &.{ 0x90, 0 }, &.{ 0x63, 0xc3 }, &.{ 0x90, 0 }, &.{ 0x90, 0 }, &.{ 0x63, 0xc3 } };
    for (replies) |bytes_reply| try reply(service, bytes_reply);
    try t.expectEqual(@as(u8, 1), service.prompt().?.index);
}
fn verify(service: *core.ExtendedService) !void {
    try service.submit(service.session, "1234");
    try reply(service, &.{ 0x63, 0xc3 });
    const action = (try service.take()).?;
    try t.expectEqual(@as(usize, 9), action.bytes.len);
    try t.expect((try service.take()) == null);
    try service.complete(action.token, &.{ 0x90, 0 });
}
fn common(service: *core.ExtendedService) !void {
    try reply(service, &.{ 0x90, 0 });
    try reply(service, &.{ 0x90, 0 });
    var raw: [license.common_bytes]u8 = @splat(255);
    @memcpy(raw[0..license.fixture.len], license.fixture);
    try file(service, &raw);
}
fn file(service: *core.ExtendedService, bytes: []const u8) !void {
    var at: usize = 0;
    while (at < bytes.len) {
        const count = @min(256, bytes.len - at);
        const action = (try service.take()).?;
        try t.expectEqual(@as(u8, @truncate(count)), action.bytes[4]);
        try t.expectEqual(at, @as(usize, action.bytes[2]) << 8 | action.bytes[3]);
        var response: [258]u8 = undefined;
        @memcpy(response[0..count], bytes[at..][0..count]);
        response[count] = 0x90;
        response[count + 1] = 0;
        try service.complete(action.token, response[0 .. count + 2]);
        at += count;
    }
}
test "PIN-free detection is bounded, distinguishes ambiguous AIDs and never exposes a PIN prompt" {
    for (0..4) |bits| {
        var service = core.ExtendedService{};
        try service.startDetection();
        try reply(&service, &.{ 0x3b, 0x80 });
        try reply(&service, if (bits & 1 != 0) &.{ 0x90, 0 } else &.{ 0x6a, 0x82 });
        try reply(&service, if (bits & 2 != 0) &.{ 0x90, 0 } else &.{ 0x6a, 0x82 });
        try t.expect(service.prompt() == null and service.detectedKind() == null);
        try reply(&service, &.{});
        try t.expectEqual(@as(u2, @intCast(bits)), service.detectedKind().?);
    }
}
test "two distinct local PIN sessions read exact licence files and keep all data private until cleanup" {
    var photo: [32768]u8 = undefined;
    var service = core.ExtendedService{};
    try ready(&service, &photo);
    const first = service.session;
    try verify(&service);
    try common(&service);
    try reply(&service, &.{ 0x90, 0 });
    try reply(&service, &.{ 0x90, 0 });
    try reply(&service, &.{ 0x63, 0xc3 });
    try t.expectEqual(@as(u8, 2), service.prompt().?.index);
    try t.expectError(error.Stale, service.submit(first, "1234"));
    try verify(&service);
    try reply(&service, &.{ 0x90, 0 });
    try reply(&service, &.{ 0x90, 0 });
    var raw: [license.photo_bytes]u8 = @splat(255);
    const header = "\x5f\x40\x10\xff\x4f0123456789abcd";
    @memcpy(raw[0..header.len], header);
    try file(&service, &raw);
    try t.expect(service.licenseResult() == null and service.portrait() == null);
    try reply(&service, &.{});
    try t.expectEqual(@as(usize, license.common_bytes), service.licenseResult().?.len);
    try t.expectEqual(@as(usize, 16), service.portrait().?.len);
    try service.dismiss();
    for (photo) |byte| try t.expectEqual(@as(u8, 0), byte);
    for (service.attributes) |byte| try t.expectEqual(@as(u8, 0), byte);
}
test "licence final boundary denies other EFs, wrong context, repeated PINs and noncontiguous reads" {
    var buffer: [512]u8 = undefined;
    var p = policy.ExtendedPolicy{ .profile = .license };
    const pin = [_]u8{ 0, 0x20, 0, 0x80, 4, '1', '2', '3', '4' };
    try t.expect(!p.allow(try ccid.request(&buffer, 0x6f, 0, &pin)));
    try t.expect(p.allow(try ccid.request(&buffer, 0x6f, 0, &license.select_mf)));
    try t.expect(p.allow(try ccid.request(&buffer, 0x6f, 0, &license.select_pin2)));
    try t.expect(!p.allow(try ccid.request(&buffer, 0x6f, 0, &pin)));
    try t.expect(p.allow(try ccid.request(&buffer, 0x6f, 0, &license.select_pin1)));
    try t.expect(p.allow(try ccid.request(&buffer, 0x6f, 0, &pin)));
    try t.expect(!p.allow(try ccid.request(&buffer, 0x6f, 0, &pin)));
    try t.expect(p.allow(try ccid.request(&buffer, 0x6f, 0, &license.select_df1)));
    try t.expect(!p.allow(try ccid.request(&buffer, 0x6f, 0, &license.select_pin2)));
    try t.expect(p.allow(try ccid.request(&buffer, 0x6f, 0, &license.select_pin1)));
    try t.expect(!p.allow(try ccid.request(&buffer, 0x6f, 0, &.{ 0, 0xb0, 1, 0, 0 })));
    try t.expect(p.allow(try ccid.request(&buffer, 0x6f, 0, &.{ 0, 0xb0, 0, 0, 0 })));
    try t.expect(!p.allow(try ccid.request(&buffer, 0x6f, 0, &.{ 0, 0xb0, 0, 0, 0 })));
    var detect = policy.ExtendedPolicy{ .profile = .detection };
    try t.expect(detect.allow(try ccid.request(&buffer, 0x6f, 0, &license.select_df1)));
    try t.expect(!detect.allow(try ccid.request(&buffer, 0x6f, 0, &pin)));
    try t.expect(!detect.allow(try ccid.request(&buffer, 0x6f, 0, &.{ 0, 0x20, 0, 0x80 })));
    try t.expect(!detect.allow(try ccid.request(&buffer, 0x6f, 0, &.{ 0, 0xb0, 0, 0, 0 })));
}

test "unset licence PIN settings stop before any prompt or credential" {
    var buffer: [32768]u8 = undefined;
    var service = core.ExtendedService{};
    try service.startLicenseWith(license.Parser(null), &buffer);
    try reply(&service, &.{ 0x3b, 0x80 });
    try reply(&service, &.{ 0x90, 0 });
    try reply(&service, &.{ 0x90, 0 });
    try reply(&service, &.{ 5, 1, 0, 0x90, 0 });
    try t.expectEqual(core.State.power_off, service.state);
    try t.expect(service.prompt() == null);
    try t.expectEqual(@as(u8, 0), service.license_pin_config);
}

test "changed, last, blocked and malformed licence counters never construct a credential" {
    const cases = [_]struct { response: []const u8, fault: core.Fault }{
        .{ .response = &.{ 0x63, 0xc2 }, .fault = .counter_changed },
        .{ .response = &.{ 0x63, 0xc1 }, .fault = .last_attempt },
        .{ .response = &.{ 0x69, 0x84 }, .fault = .blocked },
        .{ .response = &.{ 0x90, 0 }, .fault = .status },
        .{ .response = &.{ 1, 0x63, 0xc3 }, .fault = .malformed },
    };
    for (cases) |case| {
        var buffer: [32768]u8 = undefined;
        var service = core.ExtendedService{};
        try ready(&service, &buffer);
        try service.submit(service.session, "1234");
        const query = (try service.take()).?;
        try t.expectEqualSlices(u8, &.{ 0, 0x20, 0, 0x80 }, query.bytes);
        try service.complete(query.token, case.response);
        try t.expectEqual(case.fault, service.fault);
        try t.expect(service.prompt() == null);
        for (service.pending_pin) |byte| try t.expectEqual(@as(u8, 0), byte);
        const cleanup = (try service.take()).?;
        try t.expectEqual(core.Kind.power_off, cleanup.kind);
        try service.complete(cleanup.token, &.{});
        try t.expect((try service.take()) == null);
        try t.expectError(error.Busy, service.startLicenseWith(license.Parser(null), &buffer));
    }
}

test "licence PIN outcome is terminal and partial fields require successful cleanup" {
    for (0..5) |scenario| {
        var buffer: [32768]u8 = undefined;
        var service = core.ExtendedService{};
        try ready(&service, &buffer);
        try verify(&service);
        try common(&service);
        try reply(&service, &.{ 0x90, 0 });
        try reply(&service, &.{ 0x90, 0 });
        try reply(&service, &.{ 0x63, 0xc3 });
        try service.submit(service.session, "1234");
        try reply(&service, &.{ 0x63, 0xc3 });
        const credential = (try service.take()).?;
        try t.expectEqual(@as(usize, 9), credential.bytes.len);
        try t.expect((try service.take()) == null);
        switch (scenario) {
            0, 1 => try service.failed(credential.token),
            2 => try service.complete(credential.token, &.{ 0x63, 0xc2 }),
            3 => {
                service.cancel();
                try service.complete(credential.token, &.{ 0x90, 0 });
            },
            4 => service.disconnected(),
            else => unreachable,
        }
        try t.expect(service.prompt() == null and service.licenseResult() == null);
        if (scenario != 4) {
            const cleanup = (try service.take()).?;
            try t.expectEqual(core.Kind.power_off, cleanup.kind);
            if (scenario == 1) try service.failed(cleanup.token) else try service.complete(cleanup.token, &.{});
        }
        try t.expectEqual(scenario == 0 or scenario == 2, service.licenseResult() != null);
        try t.expect(service.portrait() == null and (try service.take()) == null);
        try service.dismiss();
        for (buffer) |byte| try t.expectEqual(@as(u8, 0), byte);
        for (service.attributes) |byte| try t.expectEqual(@as(u8, 0), byte);
    }
}

test "licence public settings require MF context and probe rejects every credential" {
    var buffer: [512]u8 = undefined;
    var p = policy.ExtendedPolicy{ .profile = .license, .probe_only = true };
    const read = [_]u8{ 0, 0xb0, 0, 0, 3 };
    try t.expect(!p.allow(try ccid.request(&buffer, 0x6f, 0, &license.select_pin_setting)));
    try t.expect(p.allow(try ccid.request(&buffer, 0x6f, 0, &license.select_mf)));
    try t.expect(!p.allow(try ccid.request(&buffer, 0x6f, 0, &read)));
    try t.expect(p.allow(try ccid.request(&buffer, 0x6f, 0, &license.select_pin_setting)));
    try t.expect(p.allow(try ccid.request(&buffer, 0x6f, 0, &read)));
    try t.expect(!p.allow(try ccid.request(&buffer, 0x6f, 0, &read)));
    try t.expect(p.allow(try ccid.request(&buffer, 0x6f, 0, &license.select_pin1)));
    for ([_][]const u8{ "1234", "****" }) |value| {
        var command = [_]u8{ 0, 0x20, 0, 0x80, 4, 0, 0, 0, 0 };
        @memcpy(command[5..], value);
        try t.expect(!p.allow(try ccid.request(&buffer, 0x6f, 0, &command)));
    }
    try t.expectEqual(@as(u32, 0), p.verifies);
    try t.expectEqual(@as(u32, 0), p.surface_verifies);
}

test "slot status is metadata-only and requires the extended transport policy" {
    var buffer: [512]u8 = undefined;
    var legacy = policy.Policy{};
    var extended = policy.ExtendedPolicy{ .profile = .detection, .probe_only = true };
    const status = try ccid.request(&buffer, 0x65, 7, &.{});
    try t.expect(!legacy.allow(status));
    try t.expect(extended.allow(status));
    try t.expect(!extended.allow(try ccid.request(&buffer, 0x65, 8, &.{1})));
    try t.expectEqual(@as(u32, 0), extended.verifies);
    try t.expectEqual(@as(u32, 0), extended.surface_verifies);
}
