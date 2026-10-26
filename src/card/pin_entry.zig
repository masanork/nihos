//! Device-local PIN entry model. Single pointer, release-to-activate keys.
//! Display adapters see only masked length; no logging/storage/serial input.
const std = @import("std");
const card = @import("service.zig");
pub const Key = enum { one, two, three, four, five, six, seven, eight, nine, cancel, zero, erase, submit };
pub const Rect = struct {
    x: u16,
    y: u16,
    width: u16,
    height: u16,
    pub fn contains(self: Rect, x: u16, y: u16) bool {
        return x >= self.x and x - self.x < self.width and y >= self.y and y - self.y < self.height;
    }
};
/// Logical portrait 720x1280 coordinates; board adapter owns rotation/scaling.
pub fn bounds(key: Key) Rect {
    if (key == .submit) return .{ .x = 84, .y = 1100, .width = 552, .height = 112 };
    const index: u16 = switch (key) {
        .one => 0,
        .two => 1,
        .three => 2,
        .four => 3,
        .five => 4,
        .six => 5,
        .seven => 6,
        .eight => 7,
        .nine => 8,
        .cancel => 9,
        .zero => 10,
        .erase => 11,
        .submit => unreachable,
    };
    return .{ .x = 84 + index % 3 * 192, .y = 520 + index / 3 * 140, .width = 168, .height = 112 };
}
pub fn hit(x: u16, y: u16) ?Key {
    for (std.enums.values(Key)) |key| if (bounds(key).contains(x, y)) return key;
    return null;
}
/// Full-width rows used by the sparse native keypad demonstration.
pub fn demoBounds(key: Key) Rect {
    var rect = bounds(key);
    if (key == .submit) {
        rect.x = 0;
        rect.width = 720;
    } else {
        rect.x = (rect.x - 84) / 192 * 240;
        rect.width = 240;
    }
    return rect;
}
pub fn demoHit(x: u16, y: u16) ?Key {
    for (std.enums.values(Key)) |key| if (demoBounds(key).contains(x, y)) return key;
    return null;
}
pub const Contact = struct {
    held: bool = false,
    armed: ?Key = null,
    pub fn disarm(self: *Contact) void {
        self.armed = null;
    }
    pub fn sample(self: *Contact, enabled: bool, contacts: u8, x: u16, y: u16, comptime locate: fn (u16, u16) ?Key) ?Key {
        if (contacts == 0) {
            const selected = if (self.held and enabled) self.armed else null;
            self.held = false;
            self.armed = null;
            return selected;
        }
        const selected = if (contacts == 1 and enabled) locate(x, y) else null;
        if (!self.held) {
            self.held = true;
            self.armed = selected;
        } else if (self.armed != selected) self.armed = null;
        return null;
    }
};
pub const View = struct { active: bool, masked_digits: u8, remaining: ?u8, can_submit: bool };
pub const Entry = struct {
    session: ?u32 = null,
    pin: [4]u8 = @splat(0),
    length: u8 = 0,
    contact: Contact = .{},

    pub fn clear(self: *Entry) void {
        std.crypto.secureZero(u8, &self.pin);
        self.length = 0;
        self.contact.disarm();
        // held remains latched until release: a new screen must not consume
        // a contact which began on the previous screen.
    }
    pub fn sync(self: *Entry, service: *const card.Service) void {
        const session = if (service.prompt()) |prompt| prompt.session else null;
        if (self.session != session) {
            self.clear();
            self.session = session;
        }
    }
    pub fn view(self: *Entry, service: *const card.Service) View {
        self.sync(service);
        return .{ .active = self.session != null, .masked_digits = self.length, .remaining = service.remaining, .can_submit = self.session != null and self.length == 4 };
    }
    fn activate(self: *Entry, service: *card.Service, key: Key) void {
        switch (key) {
            .cancel => {
                self.clear();
                service.cancel();
            },
            .erase => if (self.length > 0) {
                self.length -= 1;
                std.crypto.secureZero(u8, self.pin[self.length..][0..1]);
            },
            .submit => {
                if (self.length != 4) return;
                defer self.clear();
                service.submit(self.session orelse return, &self.pin) catch return;
                self.sync(service);
            },
            else => {
                if (self.length == 4) return;
                self.pin[self.length] = switch (key) {
                    .zero => '0',
                    .one => '1',
                    .two => '2',
                    .three => '3',
                    .four => '4',
                    .five => '5',
                    .six => '6',
                    .seven => '7',
                    .eight => '8',
                    .nine => '9',
                    else => unreachable,
                };
                self.length += 1;
            },
        }
    }
    /// Every sample, including zero-contact releases, must be delivered.
    /// Multiple contacts, movement off a key, and screen changes disarm it.
    pub fn touch(self: *Entry, service: *card.Service, contacts: u8, x: u16, y: u16) void {
        self.sync(service);
        if (self.contact.sample(self.session != null, contacts, x, y, hit)) |key| self.activate(service, key);
    }
};
