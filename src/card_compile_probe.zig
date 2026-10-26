//! Compile-only exercise of every service/UI entry point on RV32.
//! No board transport, PIN source, firmware installation or hardware evidence.
const card = @import("card/service.zig");
const ui = @import("card/pin_entry.zig");
const ccid = @import("card/ccid_owner.zig");
var service = card.Service{};
var entry = ui.Entry{};
var owner = ccid.Owner{};
extern fn card_probe_send([*]const u8, usize) usize;
extern fn card_probe_receive([*]u8, usize) usize;
extern fn card_probe_scrub() void;
const Link = struct {
    pub fn send(_: Link, bytes: []const u8) !usize {
        return card_probe_send(bytes.ptr, bytes.len);
    }
    pub fn receive(_: Link, bytes: []u8) !usize {
        return card_probe_receive(bytes.ptr, bytes.len);
    }
    pub fn scrub(_: Link) void {
        card_probe_scrub();
    }
};

export fn card_compile_probe(event: u32, token: u32, bytes: [*]const u8, length: usize) usize {
    switch (event) {
        0 => service.start() catch return 0,
        1 => if (service.take() catch return 0) |action| {
            return action.token +% action.bytes.len +% @backingInt(action.kind);
        },
        2 => service.complete(token, bytes[0..length]) catch return 0,
        3 => service.failed(token) catch return 0,
        4 => service.cancel(),
        5 => service.disconnected(),
        6 => service.dismiss() catch return 0,
        7 => service.submit(token, bytes[0..length]) catch return 0,
        8 => entry.touch(&service, @truncate(token), @truncate(length), @truncate(length >> 16)),
        9 => {
            const view = entry.view(&service);
            return view.masked_digits + @as(usize, @intFromBool(view.can_submit));
        },
        10 => if (service.result()) |result| {
            return result.name.len + result.address.len + result.birth_date.len + result.gender.len;
        },
        11 => entry.clear(),
        12 => return @intFromBool(owner.step(&service, Link{}) catch return 0),
        else => {},
    }
    return @backingInt(service.state);
}
