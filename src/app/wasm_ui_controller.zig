//! Foreground UI ownership and input routing around a scheduled Wasm session.
pub const Phase = enum { idle, opening, cancelling, active };
pub const Key = union(enum) { text: u8, escape, other };
pub const Update = enum { waiting, started, stopped, failed };

pub fn Controller(comptime Backend: type) type {
    return struct {
        const Self = @This();
        phase: Phase = .idle,
        last_error: i32 = 0,

        pub fn reservesDisplay(self: *const Self) bool {
            return self.phase != .idle;
        }
        pub fn start(self: *Self, camera_idle: bool, display_available: bool, presenter: *const fn ([*]const u8, u32) callconv(.c) i32) i32 {
            if (self.reservesDisplay() or !camera_idle or !display_available) return -3;
            const status = Backend.beginAsync(presenter);
            if (status == 0) self.phase = .opening;
            return status;
        }
        pub fn key(self: *Self, input: Key) i32 {
            switch (self.phase) {
                .idle => return -5,
                .cancelling => return -3,
                .opening => {
                    const cancel = switch (input) {
                        .escape => true,
                        .text => |byte| byte == 'q',
                        .other => false,
                    };
                    if (!cancel) return -3;
                    if (!Backend.cancelAsync()) return -5;
                    self.phase = .cancelling;
                    return 0;
                },
                .active => {
                    const status = switch (input) {
                        .escape => Backend.cancel(),
                        .text => |byte| Backend.input(byte),
                        .other => return -1,
                    };
                    if (!Backend.active()) self.phase = .idle;
                    return status;
                },
            }
        }
        pub fn service(self: *Self) Update {
            if (self.phase != .opening and self.phase != .cancelling) return .waiting;
            const status = Backend.pollAsync() orelse return .waiting;
            if (Backend.active()) {
                if (status == 0 and self.phase == .opening) {
                    self.phase = .active;
                    return .started;
                }
                // Never release display ownership while a backend is active,
                // even if it returned an unexpected or stale response.
                self.phase = .active;
                self.last_error = -90;
                return .failed;
            }
            self.phase = .idle;
            self.last_error = if (status == 1) 0 else if (status == 0) -90 else status;
            return if (status == 1) .stopped else .failed;
        }
    };
}

test "opening reserves display until cancellation and rejects stale active response" {
    const testing = @import("std").testing;
    const Fake = struct {
        var live = false;
        var response: ?i32 = null;
        fn present(_: [*]const u8, _: u32) callconv(.c) i32 {
            return 0;
        }
        fn beginAsync(_: *const fn ([*]const u8, u32) callconv(.c) i32) i32 {
            return 0;
        }
        fn cancelAsync() bool {
            return true;
        }
        fn pollAsync() ?i32 {
            return response;
        }
        fn active() bool {
            return live;
        }
        fn cancel() i32 {
            live = false;
            return 0;
        }
        fn input(_: u32) i32 {
            return 0;
        }
    };
    var c: Controller(Fake) = .{};
    try testing.expectEqual(@as(i32, -3), c.start(false, true, &Fake.present));
    try testing.expectEqual(@as(i32, -3), c.start(true, false, &Fake.present));
    try testing.expectEqual(@as(i32, 0), c.start(true, true, &Fake.present));
    try testing.expect(c.reservesDisplay());
    try testing.expectEqual(@as(i32, -3), c.key(.{ .text = '1' }));
    try testing.expectEqual(@as(i32, 0), c.key(.escape));
    try testing.expect(c.reservesDisplay());
    try testing.expectEqual(Update.waiting, c.service());
    Fake.live = true;
    Fake.response = 0;
    try testing.expectEqual(Update.failed, c.service());
    try testing.expect(c.reservesDisplay());
    try testing.expectEqual(@as(i32, 0), c.key(.escape));
    try testing.expect(!c.reservesDisplay());
    Fake.response = 0;
    var empty: Controller(Fake) = .{};
    try testing.expectEqual(@as(i32, 0), empty.start(true, true, &Fake.present));
    try testing.expectEqual(Update.failed, empty.service());
    try testing.expectEqual(@as(i32, -90), empty.last_error);
}
