//! Compile-only freestanding probe. No physical device operations.
const pump = @import("hosted_ota_pump.zig");
const ota = @import("hosted_ota.zig");
const session = @import("hosted_ota_session.zig");
const guard = @import("hosted_ota_guard.zig");
const Stream = struct {
    pub fn send(_: *@This(), _: []const u8) error{Transport}!usize {
        return 0;
    }
    pub fn receive(_: *@This(), _: []u8) error{Transport}!usize {
        return 0;
    }
};
var driver: ?pump.Pump = null;
var stream: Stream = .{};
export fn nih_ota_probe_init(bytes: [*]const u8, length: usize, hash: *const [32]u8) bool {
    const client = ota.Client.init(bytes[0..length], hash.*, 0, 0) catch return false;
    driver = pump.Pump.init(client, 0, 100) catch return false;
    return true;
}
export fn nih_ota_probe_step(now: u64) bool {
    if (driver) |*d| {
        d.step(&stream, now) catch return false;
        return true;
    }
    return false;
}

var session_driver: ?session.Session = null;
export fn nih_ota_session_probe_init(bytes: [*]const u8, length: usize, hash: *const [32]u8) bool {
    session_driver = session.Session.init(bytes[0..length], hash.*, 0, 100) catch return false;
    return true;
}
export fn nih_ota_session_probe_step(now: u64) bool {
    if (session_driver) |*d| {
        d.step(&stream, now) catch return false;
        return true;
    }
    return false;
}

// SAFETY: the probe caller must initialize the guard before step or feed.
var guarded_driver: guard.Guard = undefined;
export fn nih_ota_guard_probe_init(bytes: [*]const u8, length: usize, hash: *const [32]u8) bool {
    guarded_driver.initInPlace(bytes[0..length], hash.*, 0, 100) catch return false;
    return true;
}
export fn nih_ota_guard_probe_step(now: u64) bool {
    guarded_driver.step(&stream, now) catch return false;
    return true;
}
export fn nih_ota_guard_probe_feed(byte: u8, now: u64) bool {
    return guarded_driver.feed(byte, now) catch false;
}
