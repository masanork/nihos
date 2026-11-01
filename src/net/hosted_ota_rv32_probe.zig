//! Compile-only freestanding probe. No physical device operations.
const pump = @import("hosted_ota_pump.zig");
const ota = @import("hosted_ota.zig");
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
