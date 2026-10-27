const std = @import("std");
const t = std.testing;
const job = @import("license_session.zig");
const base = @import("license.zig");
const records = @import("license_record.zig");
const wire = @import("wire_policy.zig");
const ccid = @import("ccid");
const S = job.Session(null);
test "pinned synthetic signatures bind the full fixed files including padding and domicile" {
    const crypto = @import("license_crypto.zig");
    const trust = @import("license_trust.zig");
    const fixture = @embedFile("fixtures/license-verification.bin");
    var pins: [293]u8 = @splat(0);
    pins[0] = 32;
    @memcpy(pins[1..33], fixture[256..288]);
    @memcpy(pins[33..289], fixture[0..256]);
    std.mem.writeInt(u32, pins[289..293], 65537, .big);
    for ([_]bool{ false, true }) |myna| {
        var workspace: [32768]u8 = @splat(0);
        if (myna) {
            @memcpy(workspace[0..5845], fixture[3833..9678]);
            @memcpy(workspace[5845..6429], fixture[9678..10262]);
        } else {
            @memcpy(workspace[0..2967], fixture[288..3255]);
            @memcpy(workspace[4270..4848], fixture[3255..3833]);
        }
        const signed = try records.Parser(null).envelope(&workspace, myna);
        const key = trust.lookup(&pins, signed.signature.key_id).?;
        var request = crypto.Request{ .modulus = key.modulus, .exponent = key.exponent, .signature = signed.signature.value, .data = signed.data.ptr, .length = signed.data.len };
        try crypto.verify(&request);
        for ([_]usize{ 0, 880, 962, if (myna) 5844 else 2966 }) |offset| {
            workspace[offset] ^= 1;
            try t.expectError(error.InvalidSignature, crypto.verify(&request));
            workspace[offset] ^= 1;
        }
        if (!myna) {
            workspace[2967] = 0x50;
            try crypto.verify(&request);
        } // Change EF04 is outside the signed scope.
        try t.expect(trust.Store(null).find(signed.signature.key_id) == null); // Never add test keys to firmware pins.
    }
}
fn reply(service: *S, bytes: []const u8) !void {
    const action = (try service.take()).?;
    try service.complete(action.token, bytes);
}
fn ready(service: *S, profile: job.Profile, buffer: []u8) !void {
    try service.start(profile, buffer);
    for (0..24) |_| {
        if (service.prompt() != null) return;
        const state = service.state;
        try reply(service, if (state == .power_on) &.{ 0x3b, 0x80 } else if (state == .settings_read) (if (profile == .myna) &.{ 0xc1, 1, 1, 0x90, 0 } else &.{ 5, 1, 1, 0x90, 0 }) else if (state == .counter) (if (profile == .myna) &.{ 0x63, 0xca } else &.{ 0x63, 0xc3 }) else &.{ 0x90, 0 });
    }
    return error.NotReady;
}
pub fn mynaFixture(out: []u8, literal: bool) void {
    @memset(out, 255);
    const initial = "\xc5\x07" ++ "5120101" ++ "\xe7\x0c000000000000\xed\x01\x01";
    @memcpy(out[0..initial.len], initial);
    @memcpy(out[initial.len..][0..3], &[_]u8{ if (literal) @as(u8, 1) else 255, 7, 16 });
    @memcpy(out[initial.len + 3 ..][0..16], "\xff\x4f0123456789abcd");
}
fn source(profile: job.Profile, index: u8, out: []u8) []const u8 {
    @memset(out, 255);
    if (profile == .myna) {
        if (index == 0) {
            mynaFixture(out[0..5845], false);
            return out[0..5845];
        }
        return out[0..584];
    }
    const r = job.classic_files[index];
    if (index == 0) @memcpy(out[0..base.fixture.len], base.fixture);
    if (index == 7) @memcpy(out[0..19], "\x5f\x40\x10\xff\x4f0123456789abcd");
    return out[0..r.length];
}
test "both licence profiles preserve separate local PIN sessions and exact final-wire reads" {
    for ([_]job.Profile{ .classic, .myna }) |profile| {
        var buffer: [32768]u8 = undefined;
        var service = S{};
        try ready(&service, profile, &buffer);
        const first = service.session;
        var prompts: usize = 0;
        var files: [8]bool = @splat(false);
        var policy = wire.ExtendedPolicy{ .profile = if (profile == .classic) .license else .myna_license };
        // The readiness helper consumed SELECTs/counter reads, no credentials.
        var frame: [512]u8 = undefined;
        if (profile == .classic) {
            try t.expect(policy.allow(try ccid.request(&frame, 0x6f, 0, &base.select_mf)));
            try t.expect(policy.allow(try ccid.request(&frame, 0x6f, 0, &base.select_pin1)));
        } else {
            try t.expect(policy.allow(try ccid.request(&frame, 0x6f, 0, &job.myna_aid)));
            try t.expect(policy.allow(try ccid.request(&frame, 0x6f, 0, &.{ 0, 0xa4, 2, 0x0c, 2, 0, 6 })));
        }
        for (0..160) |_| {
            if (service.state == .done) break;
            if (service.prompt()) |prompt| {
                prompts += 1;
                if (prompts == 2) {
                    try t.expect(prompt.session != first);
                    try t.expectError(error.Stale, service.submit(first, "1234"));
                }
                try service.submit(prompt.session, "1234");
                continue;
            }
            const state = service.state;
            const index = service.file_index;
            const offset = service.file_offset;
            const action = (try service.take()).?;
            try t.expect(policy.allow(try ccid.request(&frame, if (action.kind == .power_off) 0x63 else 0x6f, 0, action.bytes)));
            try t.expect((try service.take()) == null);
            if (state == .read) {
                var raw: [5845]u8 = undefined;
                const file = source(profile, index, &raw);
                var response: [258]u8 = undefined;
                const count = @min(256, file.len - offset);
                @memcpy(response[0..count], file[offset..][0..count]);
                response[count] = 0x90;
                response[count + 1] = 0;
                try t.expectEqual(@as(u8, @truncate(count)), action.bytes[4]);
                try service.complete(action.token, response[0 .. count + 2]);
                files[index] = true;
            } else try service.complete(action.token, if (state == .power_off) &.{} else if (state == .confirm or state == .counter) (if (profile == .myna) &.{ 0x63, 0xca } else &.{ 0x63, 0xc3 }) else &.{ 0x90, 0 });
            if (service.state != .done) try t.expect(service.result() == null);
        }
        try t.expectEqual(@as(usize, if (profile == .myna) 1 else 2), prompts);
        try t.expectEqual(@as(u32, 1), policy.verifies);
        try t.expectEqual(@as(u32, if (profile == .myna) 0 else 1), policy.surface_verifies);
        try t.expect(service.result() != null and service.portrait() != null);
        for (files[0..if (profile == .myna) @as(usize, 2) else 8]) |read| try t.expect(read);
        try service.dismiss();
        for (buffer) |b| try t.expectEqual(@as(u8, 0), b);
    }
}
test "myna ten-attempt counter is rechecked and last/changed/unknown outcomes never retry" {
    for ([_][]const u8{ &.{ 0x63, 0xc9 }, &.{ 0x63, 0xc1 }, &.{ 0x69, 0x83 }, &.{ 0x90, 0 } }) |response| {
        var buffer: [32768]u8 = undefined;
        var service = S{};
        try ready(&service, .myna, &buffer);
        try t.expectEqual(@as(u8, 10), service.prompt().?.remaining);
        try t.expectEqual(@as(u8, 3), service.prompt().?.index);
        try service.submit(service.session, "1234");
        try reply(&service, response);
        try t.expectEqual(job.State.power_off, service.state);
        try reply(&service, &.{});
        try t.expect(service.result() == null and service.prompt() == null and (try service.take()) == null);
    }
    var buffer: [32768]u8 = undefined;
    var service = S{};
    try ready(&service, .myna, &buffer);
    try service.submit(service.session, "1234");
    try reply(&service, &.{ 0x63, 0xca });
    const credential = (try service.take()).?;
    try service.failed(credential.token);
    try t.expectEqual(@import("service.zig").Fault.pin_outcome_unknown, service.fault);
    try reply(&service, &.{});
    try t.expect(service.result() == null and (try service.take()) == null);
}
test "change records update name/address and preserve dated history without signing it" {
    var common: [880]u8 = @splat(255);
    @memcpy(common[0..base.fixture.len], base.fixture);
    var change: [640]u8 = @splat(255);
    const text = "\x50\x01\x11\x60\x1b\x83\x23\x35\x23\x30\x23\x32\x23\x30\x23\x31\x23\x30\x23\x31\x3b\x33" ++ "\x45\x44\x45\x44\x45\x44\x45\x44\x45\x44";
    @memcpy(change[0..text.len], text);
    var list: [32]records.History = undefined;
    const P = records.Parser(null);
    const history = try P.history(&change, &list);
    try t.expectEqual(@as(usize, 1), history.len);
    try t.expectEqualStrings("20200101", &history[0].date);
    var output: [512]u8 = undefined;
    const current = try P.current(&common, &change, &output);
    try t.expectEqualStrings("山", current.name);
    change[2] = 0;
    try t.expectError(error.Malformed, P.history(&change, &list));
}
test "myna extended tag encodings reject duplicate, mixed, truncated and history-only records" {
    for ([_]bool{ false, true }) |literal| {
        var raw: [5845]u8 = undefined;
        mynaFixture(&raw, literal);
        const P = records.Parser(null);
        const info = try P.myna(&raw);
        try t.expectEqual(@as(u16, 2), info.types);
        raw[0] = 0xe8;
        try t.expectError(error.Malformed, P.myna(&raw));
    }
    var iterator = records.ExtendedIterator{ .bytes = &.{ 1, 0, 0, 255, 1, 0 } };
    _ = try iterator.next();
    try t.expectError(error.Malformed, iterator.next());
}
