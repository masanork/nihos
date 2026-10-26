const std = @import("std");
const card = @import("service.zig");
const input = @import("input_support.zig");
const ui = @import("pin_entry.zig");
const ccid_owner = @import("ccid_owner.zig");
const ccid = @import("ccid");
const testing = std.testing;

fn reply(service: *card.Service, bytes: []const u8) !card.Action {
    const action = (try service.take()).?;
    // The transport must finish using the command before returning a reply.
    try service.complete(action.token, bytes);
    return action;
}
fn ready(service: *card.Service, retries: u8) !void {
    try service.start();
    _ = try reply(service, &.{ 0x3b, 0x80 });
    _ = try reply(service, &.{ 0x90, 0 });
    _ = try reply(service, &.{ 0x90, 0 });
    _ = try reply(service, &.{ 0x63, 0xc0 | retries });
}
fn submitted(service: *card.Service, pin: []const u8) !void {
    try service.submit(service.session, pin);
    const query = (try service.take()).?;
    try testing.expectEqualSlices(u8, &input.query_retries, query.bytes);
    try testing.expect(service.prompt() == null);
    try service.complete(query.token, &.{ 0x63, 0xc3 });
    try zero(&service.pending_pin);
}
fn zero(bytes: []const u8) !void {
    for (bytes) |byte| try testing.expectEqual(@as(u8, 0), byte);
}
fn tap(entry: *ui.Entry, service: *card.Service, key: ui.Key) void {
    const rect = ui.bounds(key);
    entry.touch(service, 1, rect.x + 10, rect.y + 10);
    entry.touch(service, 0, 0, 0);
}

test "job selects only Input Support, awaits explicit PIN, reads attributes and powers off" {
    var service = card.Service{};
    try service.start();
    try testing.expectError(error.Busy, service.start());
    _ = try reply(&service, &.{ 0x3b, 0x80 });
    var action = (try service.take()).?;
    try testing.expectEqualSlices(u8, &input.select_ap, action.bytes);
    try testing.expect((try service.take()) == null);
    try service.complete(action.token, &.{ 0x90, 0 });
    action = (try service.take()).?;
    try testing.expectEqualSlices(u8, &input.select_pin, action.bytes);
    try service.complete(action.token, &.{ 0x90, 0 });
    action = (try service.take()).?;
    try testing.expectEqualSlices(u8, &input.query_retries, action.bytes);
    try service.complete(action.token, &.{ 0x63, 0xc3 });
    try testing.expect((try service.take()) == null);
    try testing.expectError(error.InvalidPin, service.submit(service.session, "123"));
    try testing.expectError(error.InvalidPin, service.submit(service.session, "abcd"));
    try submitted(&service, "1234"); // synthetic fixture, never hardware
    try testing.expectError(error.NotReady, service.submit(service.session, "1234"));
    action = (try service.take()).?;
    try testing.expectEqualSlices(u8, &.{ 0, 0x20, 0, 0x80, 4, '1', '2', '3', '4' }, action.bytes);
    try testing.expect((try service.take()) == null);
    try service.complete(action.token, &.{ 0x90, 0 });
    try zero(&service.command);
    try testing.expect(service.remaining == null);
    action = (try service.take()).?;
    try testing.expectEqualSlices(u8, &input.select_attributes, action.bytes);
    try service.complete(action.token, &.{ 0x90, 0 });
    action = (try service.take()).?;
    try testing.expectEqualSlices(u8, &.{ 0, 0xb0, 0, 0, 0 }, action.bytes);
    try service.complete(action.token, input.fixture ++ "\x90\x00");
    try testing.expect(service.result() == null); // no publication before cleanup
    action = (try service.take()).?;
    try testing.expectEqual(card.Kind.power_off, action.kind);
    try service.complete(action.token, &.{});
    try testing.expectEqualStrings("Test", service.result().?.name);
    try service.dismiss();
    try zero(&service.attributes);
    try zero(&service.command);
}

test "blocked, last attempt and unexpected retry replies never admit a PIN" {
    for ([_]u8{ 0, 1, 4, 15 }) |remaining| {
        var service = card.Service{};
        try ready(&service, remaining);
        try testing.expect(service.prompt() == null);
        try testing.expectError(error.NotReady, service.submit(service.session, "1234"));
        try testing.expectEqual(card.Kind.power_off, (try service.take()).?.kind);
    }
    var service = card.Service{};
    try service.start();
    _ = try reply(&service, &.{ 0x3b, 0x80 });
    _ = try reply(&service, &.{ 0x90, 0 });
    _ = try reply(&service, &.{ 0x90, 0 });
    _ = try reply(&service, &.{ 0x90, 0 }); // unknown/already-verified count
    try testing.expectEqual(card.Fault.status, service.fault);
}

test "one wrong PIN is terminal, count shown, no automatic retransmit" {
    var service = card.Service{};
    try ready(&service, 3);
    try submitted(&service, "1234");
    _ = try reply(&service, &.{ 0x63, 0xc2 });
    try testing.expectEqual(card.Fault.wrong_pin, service.fault);
    try testing.expectEqual(@as(?u8, 2), service.remaining);
    try zero(&service.command);
    try testing.expectError(error.NotReady, service.submit(service.session, "1234"));
    try testing.expectEqual(card.Kind.power_off, (try service.take()).?.kind);
    try testing.expect((try service.take()) == null);
}

test "submit rechecks the count; changed, blocked or unknown counter discards queued PIN" {
    for ([_][]const u8{ &.{ 0x63, 0xc2 }, &.{ 0x63, 0xc1 }, &.{ 0x63, 0xc0 }, &.{ 0x69, 0x83 }, &.{ 0x90, 0 }, &.{} }) |counter| {
        var service = card.Service{};
        try ready(&service, 3);
        try service.submit(service.session, "1234");
        const query = (try service.take()).?;
        try testing.expectEqualSlices(u8, &input.query_retries, query.bytes);
        try service.complete(query.token, counter);
        try zero(&service.pending_pin);
        try zero(&service.command);
        try testing.expect(service.fault != .none);
        try testing.expectEqual(card.Kind.power_off, (try service.take()).?.kind);
    }
    // A queued PIN is also erased when cancelling/failing the non-PIN check.
    for (0..3) |cause| {
        var service = card.Service{};
        try ready(&service, 3);
        try service.submit(service.session, "1234");
        const query = (try service.take()).?;
        switch (cause) {
            0 => {
                service.cancel();
                try service.complete(query.token, &.{ 0x63, 0xc3 });
            },
            1 => try service.failed(query.token),
            2 => service.disconnected(),
            else => unreachable,
        }
        try zero(&service.pending_pin);
        try zero(&service.command);
        try testing.expect(service.prompt() == null);
        try testing.expect(service.fault != .pin_outcome_unknown); // no PIN sent
    }
}

test "lost, malformed or indeterminate VERIFY response is never retried" {
    for (0..4) |failure| {
        var service = card.Service{};
        try ready(&service, 3);
        try submitted(&service, "1234");
        const action = (try service.take()).?;
        switch (failure) {
            0 => try service.failed(action.token),
            1 => try service.complete(action.token, &.{}),
            2 => try service.complete(action.token, &.{ 0x6f, 0 }),
            3 => service.disconnected(),
            else => unreachable,
        }
        try testing.expectEqual(card.Fault.pin_outcome_unknown, service.fault);
        try testing.expect(service.remaining == null);
        try zero(&service.command);
        try testing.expect(service.prompt() == null);
        if (failure != 3) try testing.expectEqual(card.Kind.power_off, (try service.take()).?.kind);
    }
}

test "cancel before dispatch wipes PIN; cancel in flight waits for transport release" {
    for ([_]bool{ false, true }) |in_flight| {
        var service = card.Service{};
        try ready(&service, 3);
        try submitted(&service, "1234");
        const action = if (in_flight) (try service.take()).? else null;
        service.cancel();
        if (action) |sent| {
            try testing.expectEqual(@as(u8, '1'), sent.bytes[5]);
            try testing.expect((try service.take()) == null);
            try service.complete(sent.token, &.{ 0x90, 0 });
        }
        try zero(&service.command);
        try testing.expectEqual(card.Fault.cancelled, service.fault);
        try testing.expectEqual(card.Kind.power_off, (try service.take()).?.kind);
    }
}

test "late completions and old UI submissions cannot affect a later session" {
    var service = card.Service{};
    try ready(&service, 3);
    const old_session = service.session;
    service.cancel();
    const old_action = (try service.take()).?;
    try service.complete(old_action.token, &.{});
    try service.dismiss();
    try ready(&service, 3);
    try testing.expectError(error.Stale, service.submit(old_session, "1234"));
    try submitted(&service, "5678");
    const current = (try service.take()).?;
    try testing.expectError(error.Stale, service.complete(old_action.token, &.{ 0x90, 0 }));
    try testing.expectEqualSlices(u8, "5678", current.bytes[5..9]);
    try service.failed(current.token);
    const off = (try service.take()).?;
    try service.failed(off.token);
    try testing.expect(service.cleanup_failed);
    try testing.expect(service.result() == null);
}

test "transport failure at every stage produces bounded cleanup with no resends" {
    const responses = [_][]const u8{ &.{ 0x3b, 0x80 }, &.{ 0x90, 0 }, &.{ 0x90, 0 }, &.{ 0x63, 0xc3 }, &.{ 0x63, 0xc3 }, &.{ 0x90, 0 }, &.{ 0x90, 0 }, input.fixture ++ "\x90\x00", &.{} };
    for (0..responses.len) |fail_at| {
        var service = card.Service{};
        try service.start();
        for (responses[0..fail_at]) |response| {
            if (service.prompt() != null) try service.submit(service.session, "1234");
            _ = try reply(&service, response);
        }
        if (service.prompt() != null) try service.submit(service.session, "1234");
        const action = (try service.take()).?;
        try service.failed(action.token);
        try zero(&service.command);
        if (service.state != .done) {
            const off = (try service.take()).?;
            try testing.expectEqual(card.Kind.power_off, off.kind);
            try service.complete(off.token, &.{});
        }
        try testing.expectEqual(card.State.done, service.state);
        try testing.expect(service.result() == null);
    }
}

fn reading(service: *card.Service) !void {
    try ready(service, 3);
    try submitted(service, "1234");
    _ = try reply(service, &.{ 0x90, 0 });
    _ = try reply(service, &.{ 0x90, 0 });
}
test "multi-page EF handles EOF and rejects overflow, malformed TLV and error statuses" {
    for (0..3) |ending| {
        var service = card.Service{};
        try reading(&service);
        var page: [258]u8 = @splat(0); // valid TLV plus padding to exactly 256
        @memcpy(page[0..input.fixture.len], input.fixture);
        page[256] = 0x90;
        _ = try reply(&service, &page);
        const action = (try service.take()).?;
        try testing.expectEqualSlices(u8, &.{ 0, 0xb0, 1, 0, 0 }, action.bytes);
        try service.complete(action.token, switch (ending) {
            0 => &.{ 0x6b, 0 },
            1 => &.{ 0x62, 0x82 },
            else => &.{ 0x90, 0 },
        });
        _ = try reply(&service, &.{});
        try testing.expectEqualStrings("Test", service.result().?.name);
    }
    var overflow = card.Service{};
    try reading(&overflow);
    var page: [258]u8 = @splat(0);
    page[256] = 0x90;
    for (0..8) |_| _ = try reply(&overflow, &page);
    _ = try reply(&overflow, &page);
    try testing.expectEqual(card.Fault.too_large, overflow.fault);
    try zero(&overflow.attributes);
    for ([_][]const u8{ "\xdf\x22\x7fX\x90\x00", &.{ 0x69, 0x82 }, &.{ 0x6b, 0 } }) |bad| {
        var service = card.Service{};
        try reading(&service);
        _ = try reply(&service, bad);
        try testing.expect(service.fault != .none);
        try zero(&service.attributes);
    }
}

test "device keypad ignores holds, drags, multitouch and stale contacts, and clears secrets" {
    var service = card.Service{};
    try ready(&service, 3);
    var entry = ui.Entry{};
    const one = ui.bounds(.one);
    for (0..10) |_| entry.touch(&service, 1, one.x + 1, one.y + 1);
    try testing.expectEqual(@as(u8, 0), entry.view(&service).masked_digits);
    entry.touch(&service, 0, 0, 0);
    try testing.expectEqual(@as(u8, 1), entry.view(&service).masked_digits);
    entry.touch(&service, 1, one.x + 1, one.y + 1);
    entry.touch(&service, 1, 0, 0); // drag out disarms until release
    entry.touch(&service, 1, one.x + 1, one.y + 1);
    entry.touch(&service, 0, 0, 0);
    entry.touch(&service, 2, one.x + 1, one.y + 1);
    entry.touch(&service, 1, one.x + 1, one.y + 1);
    entry.touch(&service, 0, 0, 0);
    try testing.expectEqual(@as(u8, 1), entry.length);
    tap(&entry, &service, .two);
    tap(&entry, &service, .three);
    tap(&entry, &service, .four);
    tap(&entry, &service, .five); // full: no extra digit
    try testing.expect(entry.view(&service).can_submit);
    tap(&entry, &service, .erase);
    try testing.expectEqual(@as(u8, 0), entry.pin[3]);
    tap(&entry, &service, .four);
    tap(&entry, &service, .submit);
    try testing.expectEqual(card.State.confirm_retries, service.state);
    try zero(&entry.pin);
    tap(&entry, &service, .submit); // double tap cannot dispatch again
    _ = try reply(&service, &.{ 0x63, 0xc3 });
    const action = (try service.take()).?;
    try testing.expectEqualSlices(u8, "1234", action.bytes[5..9]);
    try service.complete(action.token, &.{ 0x63, 0xc2 });
    _ = entry.view(&service);
    try zero(&entry.pin);
    try testing.expect(!entry.view(&service).active);
}

test "keypad cancellation, removal, and screen transition clear typed PIN" {
    for (0..3) |cause| {
        var service = card.Service{};
        try ready(&service, 3);
        var entry = ui.Entry{};
        tap(&entry, &service, .one);
        switch (cause) {
            0 => tap(&entry, &service, .cancel),
            1 => service.disconnected(),
            else => service.cancel(),
        }
        entry.sync(&service);
        try zero(&entry.pin);
        try testing.expect(!entry.view(&service).can_submit);
    }
}

const Wire = struct {
    sent: [512]u8 = @splat(0),
    send_length: usize = 0,
    sends: u32 = 0,
    receives: u32 = 0,
    scrubs: u32 = 0,
    extensions: u32 = 0,
    bad_sequence: bool = false,
    truncated: bool = false,
    short_send: bool = false,
    fail_receive: bool = false,
    fail_scrub: bool = false,
    absent: bool = false,
    active_poweroff: bool = false,
    fail_cut: bool = false,
    cuts: u32 = 0,
    payload: []const u8 = &.{ 0x90, 0 },
    pub fn send(self: *Wire, bytes: []const u8) !usize {
        @memcpy(self.sent[0..bytes.len], bytes);
        self.send_length = bytes.len;
        self.sends += 1;
        return bytes.len - @as(usize, @intFromBool(self.short_send));
    }
    pub fn receive(self: *Wire, bytes: []u8) !usize {
        self.receives += 1;
        if (self.fail_receive) return error.Transfer;
        const extending = self.receives <= self.extensions;
        const sequence = self.sent[6] +% @as(u8, @intFromBool(self.bad_sequence));
        const frame = try ccid.request(bytes, if (self.sent[0] == 0x63) 0x81 else 0x80, sequence, if (extending) &.{} else self.payload);
        bytes[7] = if (extending) 0x80 else if (self.absent) 2 else if (self.sent[0] == 0x63 and !self.active_poweroff) 1 else 0;
        return frame.len - @as(usize, @intFromBool(self.truncated));
    }
    pub fn powerCut(self: *Wire) !void {
        self.cuts += 1;
        if (self.fail_cut) return error.Cut;
    }
    pub fn scrub(self: *Wire) !void {
        std.crypto.secureZero(u8, &self.sent);
        self.scrubs += 1;
        if (self.fail_scrub) return error.Scrub;
    }
};
test "CCID extensions only poll IN, with exactly one PIN send and DMA scrubbing" {
    var service = card.Service{};
    try ready(&service, 3);
    try submitted(&service, "1234");
    var owner = ccid_owner.Owner{};
    var wire = Wire{ .extensions = 3 };
    try testing.expect(try owner.step(&service, &wire));
    try testing.expectEqual(@as(u32, 1), wire.sends);
    try testing.expectEqual(@as(u32, 4), wire.receives);
    try testing.expectEqual(@as(u32, 1), wire.scrubs);
    try testing.expectEqual(card.State.select_attributes, service.state);
    try zero(&wire.sent);
    try zero(&service.command);
}
test "DMA-copy cleanup failure cannot publish a successful VERIFY result" {
    var service = card.Service{};
    try ready(&service, 3);
    try submitted(&service, "1234");
    var owner = ccid_owner.Owner{};
    var wire = Wire{ .fail_scrub = true };
    try testing.expectError(error.Scrub, owner.step(&service, &wire));
    try testing.expectEqual(card.State.power_off, service.state);
    try testing.expectEqual(card.Fault.pin_outcome_unknown, service.fault);
    try testing.expect(service.remaining == null);
    try zero(&service.command);
    try testing.expectEqual(@as(u32, 1), wire.sends);
}

test "CCID frame and transport faults cannot resend a dispatched VERIFY" {
    for (0..6) |fault| {
        var service = card.Service{};
        try ready(&service, 3);
        try submitted(&service, "1234");
        var owner = ccid_owner.Owner{};
        var wire = Wire{};
        switch (fault) {
            0 => wire.extensions = 4,
            1 => wire.bad_sequence = true,
            2 => wire.truncated = true,
            3 => wire.short_send = true,
            4 => wire.fail_receive = true,
            5 => wire.absent = true,
            else => unreachable,
        }
        try testing.expect(try owner.step(&service, &wire));
        try testing.expectEqual(@as(u32, 1), wire.sends);
        try testing.expectEqual(card.Fault.pin_outcome_unknown, service.fault);
        try testing.expectEqual(card.State.power_off, service.state);
        try testing.expectEqual(@as(u32, 1), wire.scrubs);
        try zero(&wire.sent);
        try zero(&service.command);
    }
}

test "CCID owner powers on, completes the job and requires inactive power-off state" {
    for ([_]bool{ false, true }) |bad_off| {
        var service = card.Service{};
        var owner = ccid_owner.Owner{};
        var wire = Wire{};
        try service.start();
        const replies = [_][]const u8{ &.{ 0x3b, 0x80 }, &.{ 0x90, 0 }, &.{ 0x90, 0 }, &.{ 0x63, 0xc3 }, &.{ 0x63, 0xc3 }, &.{ 0x90, 0 }, &.{ 0x90, 0 }, input.fixture ++ "\x90\x00", &.{} };
        for (replies, 0..) |payload, index| {
            if (service.prompt() != null) try service.submit(service.session, "1234");
            wire.payload = payload;
            wire.absent = bad_off and index == replies.len - 1;
            try testing.expect(try owner.step(&service, &wire));
            try zero(&wire.sent);
        }
        try testing.expectEqual(@as(u32, 9), wire.sends);
        try testing.expectEqual(@as(u32, 9), wire.scrubs);
        try testing.expect(!(try owner.step(&service, &wire)));
        if (bad_off) {
            try testing.expect(service.cleanup_failed);
            try testing.expect(service.result() == null);
            try zero(&service.attributes);
        } else try testing.expectEqualStrings("Test", service.result().?.name);
    }
}

test "active PowerOff cannot publish attributes without explicit successful board power cut" {
    for (0..3) |policy| {
        var service = card.Service{};
        try ready(&service, 3);
        try submitted(&service, "1234");
        _ = try reply(&service, &.{ 0x90, 0 });
        _ = try reply(&service, &.{ 0x90, 0 });
        _ = try reply(&service, input.fixture ++ "\x90\x00");
        try testing.expect(service.result() == null);
        var owner = ccid_owner.Owner{};
        var wire = Wire{ .active_poweroff = true, .payload = &.{}, .fail_cut = policy == 2 };
        if (policy == 0) _ = try owner.step(&service, &wire) else _ = try owner.stepWithPowerCut(&service, &wire);
        try testing.expectEqual(@as(u32, if (policy == 0) 0 else 1), wire.cuts);
        try testing.expectEqual(policy == 1, service.result() != null);
        try testing.expectEqual(policy != 1, service.cleanup_failed);
        if (policy != 1) try zero(&service.attributes);
    }
}

test "wide native touch routes one release to real PIN entry and cancel wipes it" {
    const pin = @import("pin_entry.zig");
    var service = card.Service{};
    try ready(&service, 3);
    var entry = pin.Entry{};
    entry.touchWide(&service, 1, 10, 540);
    try testing.expectEqual(@as(u8, 0), entry.length);
    entry.touchWide(&service, 0, 0, 0);
    try testing.expectEqual(@as(u8, 1), entry.length);
    entry.touchWide(&service, 0, 0, 0);
    try testing.expectEqual(@as(u8, 1), entry.length);
    entry.touchWide(&service, 1, 10, 960);
    entry.touchWide(&service, 0, 0, 0);
    try zero(&entry.pin);
    try testing.expect(service.prompt() == null);
}

fn photoReady(service: *card.Service, output: []u8) !void {
    try service.startPortrait(output);
    _ = try reply(service, &.{ 0x3b, 0x80 });
    _ = try reply(service, &.{ 0x90, 0 });
    _ = try reply(service, &.{ 0x90, 0 });
    _ = try reply(service, &.{ 0x63, 0xc3 });
    try submitted(service, "1234");
    _ = try reply(service, &.{ 0x90, 0 });
    _ = try reply(service, &.{ 0x90, 0 });
    _ = try reply(service, input.fixture ++ "\x90\x00");
    _ = try reply(service, &.{ 0x90, 0 });
    _ = try reply(service, "\xff\x10\x0c123456789018\xff\xff\x90\x00");
    _ = try reply(service, &.{ 0x90, 0 });
    _ = try reply(service, &.{ 0x90, 0 });
}
test "photo is opt-in, uses one rechecked surface credential and remains private until cleanup" {
    var buffer: [32768]u8 = undefined;
    var service = card.Service{};
    try photoReady(&service, &buffer);
    try testing.expectEqual(card.State.surface_retries, service.state);
    _ = try reply(&service, &.{ 0x63, 0xc3 });
    _ = try reply(&service, &.{ 0x63, 0xc3 });
    try zero(&service.number);
    const verify = (try service.take()).?;
    try testing.expectEqualSlices(u8, "123456789018", verify.bytes[5..]);
    try service.complete(verify.token, &.{ 0x90, 0 });
    _ = try reply(&service, &.{ 0x90, 0 });
    _ = try reply(&service, "\xff\x20\x13\xdf\x27\x10\xff\x4f0123456789abcd\x90\x00");
    try testing.expect(service.result() == null and service.portrait() == null);
    _ = try reply(&service, &.{});
    try testing.expectEqual(@as(usize, 16), service.portrait().?.len);
    try service.dismiss();
    try zero(&buffer);
    try zero(&service.number);
    try zero(&service.command);
}
test "surface last attempt, changed counter and failed VERIFY never repeat or publish attributes" {
    for ([_][]const u8{ &.{ 0x63, 0xc1 }, &.{ 0x63, 0xc0 }, &.{ 0x63, 0xc2 }, &.{ 0x90, 0 } }) |second| {
        var buffer: [32768]u8 = undefined;
        var service = card.Service{};
        try photoReady(&service, &buffer);
        _ = try reply(&service, &.{ 0x63, 0xc3 });
        _ = try reply(&service, second);
        try testing.expectEqual(card.State.power_off, service.state);
        try testing.expect(service.result() == null and service.portrait() == null);
        try zero(&buffer);
        try zero(&service.number);
        try zero(&service.command);
    }
}
test "surface probe uses no credentials and uncertain photo VERIFY erases all borrowed buffers" {
    var probe = card.Service{};
    try probe.startSurfaceProbe();
    for ([_][]const u8{ &.{ 0x3b, 0x80 }, &.{ 0x90, 0 }, &.{ 0x90, 0 }, &.{ 0x63, 0xc3 } }) |response| {
        const action = (try probe.take()).?;
        try testing.expect(action.bytes.len != 9 and action.bytes.len != 17);
        try probe.complete(action.token, response);
    }
    try testing.expectEqual(card.State.power_off, probe.state);
    try testing.expect(probe.prompt() == null and probe.result() == null);
    for (0..3) |failure| {
        var buffer: [32768]u8 = undefined;
        var service = card.Service{};
        try photoReady(&service, &buffer);
        _ = try reply(&service, &.{ 0x63, 0xc3 });
        _ = try reply(&service, &.{ 0x63, 0xc3 });
        const action = (try service.take()).?;
        try testing.expectEqual(@as(usize, 17), action.bytes.len);
        if (failure == 0) service.disconnected() else if (failure == 1) {
            service.cancel();
            // The transport still owns the borrowed command until retirement.
            try testing.expectEqualStrings("123456789018", action.bytes[5..]);
            try service.failed(action.token);
        } else try service.complete(action.token, &.{ 0x6f, 0 });
        try testing.expect(service.result() == null and service.portrait() == null);
        try zero(&service.number);
        try zero(&service.command);
        try zero(&buffer);
    }
}

test "photo parsing failure preserves only validated attributes after proved cleanup" {
    for (0..3) |ending| {
        var buffer: [32768]u8 = undefined;
        var service = card.Service{};
        try photoReady(&service, &buffer);
        _ = try reply(&service, &.{ 0x63, 0xc3 });
        _ = try reply(&service, &.{ 0x63, 0xc3 });
        _ = try reply(&service, &.{ 0x90, 0 });
        _ = try reply(&service, &.{ 0x90, 0 });
        _ = try reply(&service, "invalid-photo\x90\x00");
        try testing.expectEqual(card.State.read_photo, service.fault_state);
        try testing.expect(service.attributesResult() == null);
        try zero(&buffer);
        if (ending == 0) _ = try reply(&service, &.{}) else if (ending == 1) {
            const action = (try service.take()).?;
            try service.failed(action.token);
        } else service.disconnected();
        try testing.expect(service.result() == null and service.portrait() == null);
        if (ending == 0) {
            try testing.expectEqualStrings("Test", service.attributesResult().?.name);
            service.cancel();
            try testing.expect(service.attributesResult() == null);
        } else {
            try testing.expect(service.attributesResult() == null);
        }
        try service.dismiss();
        try zero(&service.attributes);
    }
}
