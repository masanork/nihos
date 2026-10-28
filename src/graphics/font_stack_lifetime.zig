//! Serialized safety gate for one fixed stack bank, not a page allocator.
//! Platform owns synchronization and proves ACK/exit/cleanup/reap independently.
const std = @import("std");
pub const Use = enum(u32) { scratch, font };
pub const Lease = struct { instance: usize, generation: u32, use: Use };
pub const Proof = struct {
    acknowledged: bool,
    exited: bool,
    cleaned: bool,
    reaped: bool,
};
pub const Error = error{ Busy, Stale, Quiescence, Closed, Exhausted, Moved };
pub const Gate = struct {
    home: usize = 0,
    generation: u32 = 0,
    active: ?Use = null,
    font_used: bool = false,

    pub fn claim(self: *Gate, use: Use) Error!Lease {
        const home = @intFromPtr(self);
        if (self.home != 0 and self.home != home) return error.Moved;
        if (self.active != null) return error.Busy;
        if (use == .font and self.font_used) return error.Closed;
        if (self.generation == std.math.maxInt(u32)) return error.Exhausted;
        self.home = home;
        self.generation += 1;
        self.active = use;
        if (use == .font) self.font_used = true;
        return .{ .instance = home, .generation = self.generation, .use = use };
    }
    pub fn check(self: *const Gate, lease: Lease) Error!void {
        if (self.home != @intFromPtr(self) or lease.instance != self.home or lease.generation == 0 or
            lease.generation != self.generation or self.active != lease.use) return error.Stale;
    }
    pub fn release(self: *Gate, lease: Lease, proof: Proof) Error!void {
        try self.check(lease);
        if (lease.use == .font and !(proof.acknowledged and proof.exited and proof.cleaned and proof.reaped)) return error.Quiescence;
        self.active = null;
    }
};

test "font stack waits for every quiescence fact and refuses old leases" {
    var gate = Gate{};
    const none = Proof{ .acknowledged = false, .exited = false, .cleaned = false, .reaped = false };
    const done = Proof{ .acknowledged = true, .exited = true, .cleaned = true, .reaped = true };
    const before = try gate.claim(.scratch);
    try std.testing.expectError(error.Busy, gate.claim(.font));
    try gate.release(before, none);
    const font = try gate.claim(.font);
    try std.testing.expectError(error.Busy, gate.claim(.scratch));
    inline for (.{ "acknowledged", "exited", "cleaned", "reaped" }) |missing| {
        var proof = done;
        @field(proof, missing) = false;
        try std.testing.expectError(error.Quiescence, gate.release(font, proof));
        try gate.check(font);
    }
    try gate.release(font, done);
    const after = try gate.claim(.scratch);
    try std.testing.expectError(error.Stale, gate.release(before, none));
    var wrong = after;
    wrong.use = .font;
    try std.testing.expectError(error.Stale, gate.check(wrong));
    try gate.check(after);
    try gate.release(after, none);
    try std.testing.expectError(error.Closed, gate.claim(.font));
}
test "stack gate tickets are instance bound and never wrap" {
    var a = Gate{};
    var b = Gate{};
    const one = try a.claim(.scratch);
    const two = try b.claim(.scratch);
    try std.testing.expectError(error.Stale, b.check(one));
    var copy = a;
    try std.testing.expectError(error.Moved, copy.claim(.scratch));
    try std.testing.expectError(error.Stale, copy.check(one));
    try a.release(one, .{ .acknowledged = false, .exited = false, .cleaned = false, .reaped = false });
    a.generation = std.math.maxInt(u32);
    try std.testing.expectError(error.Exhausted, a.claim(.scratch));
    try b.check(two);
}
