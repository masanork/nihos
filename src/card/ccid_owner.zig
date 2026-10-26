//! Bounded synchronous dispatch, called only by the card's owner task.
//! UI talks to Service between dispatches; it never sends arbitrary APDUs.
const std = @import("std");
const ccid = @import("ccid");
const card = @import("service.zig");

pub const Owner = struct {
    sequence: u8 = 0,

    /// Link contract: send/receive are bounded and return only after DMA no
    /// longer borrows their argument. scrub() must quiesce hardware and erase
    /// every retained DMA copy, including on error. A poisoned link must fail
    /// subsequent calls until the board owner explicitly reinitializes it.
    /// This call may block; run it on the card owner, never the UI/IRQ path.
    pub fn step(self: *Owner, service: *card.Service, link: anytype) !bool {
        return self.dispatch(service, link, false);
    }
    /// Explicit board contract: powerCut must confirm VBUS-off, physical USB
    /// disconnect, and DMA retirement/erasure. A CCID acknowledgement alone
    /// never satisfies this fallback. Ordinary step keeps its strict policy.
    pub inline fn stepWithPowerCut(self: *Owner, service: *card.Service, link: anytype) !bool {
        return self.dispatch(service, link, true);
    }
    inline fn dispatch(self: *Owner, service: *card.Service, link: anytype, comptime cut: bool) !bool {
        const action = (try service.take()) orelse return false;
        var send: [512]u8 = @splat(0);
        var receive: [512]u8 = @splat(0);
        defer std.crypto.secureZero(u8, &send);
        defer std.crypto.secureZero(u8, &receive);
        const sequence = self.sequence;
        self.sequence +%= 1;
        const kind: u8 = switch (action.kind) {
            .power_on => 0x62,
            .apdu => 0x6f,
            .power_off => 0x63,
        };
        const frame = ccid.request(&send, kind, sequence, action.bytes) catch {
            try failAndScrub(service, action.token, link);
            return true;
        };
        const payload = exchange(link, frame, &receive, if (action.kind == .power_off) 0x81 else 0x80, sequence, action.kind) catch fallback: {
            if (cut and action.kind == .power_off) {
                link.powerCut() catch {
                    try failAndScrub(service, action.token, link);
                    return true;
                };
                break :fallback &.{};
            }
            try failAndScrub(service, action.token, link);
            return true;
        };
        link.scrub() catch |err| {
            try service.failed(action.token);
            return err;
        };
        try service.complete(action.token, payload);
        return true;
    }
};

fn failAndScrub(service: *card.Service, token: u32, link: anytype) !void {
    link.scrub() catch |err| {
        try service.failed(token);
        return err;
    };
    try service.failed(token);
}

inline fn exchange(link: anytype, send: []const u8, receive: []u8, expected: u8, sequence: u8, kind: card.Kind) ![]const u8 {
    if (try link.send(send) != send.len) return error.Transfer;
    // Time extensions cause receive-only polls. Never retransmit an APDU.
    for (0..4) |_| {
        const length = try link.receive(receive);
        if (length > receive.len) return error.Transfer;
        const response = try ccid.response(receive[0..length], expected, sequence);
        if (response.status == 2) continue;
        if (response.status != 0 or response.code != 0) return error.Card;
        if (kind == .power_off) {
            if (response.state != 1 or response.payload.len != 0) return error.Card;
        } else if (response.state != 0) return error.Card;
        return response.payload;
    }
    return error.ExtensionLimit;
}
