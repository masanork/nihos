//! Single CPU0 borrow for reserved SSH backing. Revocation clears a live
//! session but retains the borrow until the original caller releases it.
const std = @import("std");
pub const Error = error{ StorageUnavailable, StorageBusy, InvalidArgument };
pub const Slot = struct {
    bound: bool = false,
    owned: bool = false,
    live: bool = false,
    pub fn bind(self: *Slot) Error!void {
        if (self.bound) return error.StorageBusy;
        self.bound = true;
    }
    pub fn checkAvailable(self: *const Slot) Error!void {
        if (!self.bound) return error.StorageUnavailable;
        if (self.owned) return error.StorageBusy;
    }
    /// Call only after session initialization succeeded.
    pub fn claim(self: *Slot) void {
        std.debug.assert(self.bound and !self.owned);
        self.owned = true;
        self.live = true;
    }
    /// Returns true exactly once per live session; caller must wipe the owner.
    pub fn revoke(self: *Slot) bool {
        if (!self.live) return false;
        self.live = false;
        return true;
    }
    pub fn release(self: *Slot) Error!void {
        if (!self.bound or !self.owned or self.live) return error.InvalidArgument;
        self.owned = false;
    }
};

test "revocation retains the borrow until release" {
    var slot: Slot = .{};
    try std.testing.expectError(error.StorageUnavailable, slot.checkAvailable());
    try slot.bind();
    try std.testing.expectError(error.StorageBusy, slot.bind());
    try slot.checkAvailable();
    slot.claim();
    try std.testing.expectError(error.StorageBusy, slot.checkAvailable());
    try std.testing.expectError(error.InvalidArgument, slot.release());
    try std.testing.expect(slot.revoke());
    try std.testing.expect(!slot.revoke());
    try std.testing.expectError(error.StorageBusy, slot.checkAvailable());
    try slot.release();
    try std.testing.expectError(error.InvalidArgument, slot.release());
    try slot.checkAvailable();
}
