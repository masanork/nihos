//! Serialized block owner bridge. The synchronous caller must own/pin its
//! destination until return; the permanent ledger additionally quarantines a
//! failed controller transaction. It never converts a timeout into a fence.
pub const Signal = @import("io_stop.zig").Signal;
const io = @import("io_leases.zig");
pub const Error = error{ Busy, Exhausted, Quarantined, ReadFailed, Cancelled, Removed };
pub const ReadOwner = struct {
    requests: io.IoLeases(1) = .{},
    generation: u64 = 1,
    pub fn busy(self: *const @This()) bool {
        return self.requests.holdsMount(.{ .slot = 0, .generation = self.generation });
    }
    /// Check before replacing controller state or clearing a removal latch.
    /// Hardware reinitialization and publication of the next generation remain
    /// the serialized owner's responsibility.
    pub fn canRestart(self: *const @This(), ticket_active: bool, session_active: bool, quiescent: bool) bool {
        return !self.busy() and !ticket_active and !session_active and quiescent and self.generation < 0xffff_ffff;
    }
    pub inline fn read(self: *@This(), controller: anytype, lba: u32, destination: *[512]u8, buffer_lease: u64, control: anytype) Error!void {
        if (self.busy()) return error.Busy;
        const mount = io.Reference{ .slot = 0, .generation = self.generation };
        const request = self.requests.retain(0, mount, mount, buffer_lease) catch return error.Exhausted;
        self.requests.start(request) catch return error.Quarantined;
        const successful = if (controller.readSectorControlled(lba, destination, control)) |_| true else |_| false;
        // Atomically close the notification window before publishing completion.
        const reason = control.finishReason();
        switch (reason) {
            .none => {},
            .cancelled => self.requests.cancel(0, request) catch return error.Quarantined,
            .removed => self.requests.removeMount(mount),
        }
        const fence = controller.quiescence;
        self.requests.finish(request, successful, .{
            .device_idle = fence.device_idle,
            .descriptors_released = fence.descriptors_released,
            .cache_handed_back = fence.cache_handed_back,
        }) catch return error.Quarantined;
        const completion = self.requests.take(0, request) catch return error.Quarantined;
        switch (completion.outcome) {
            .completed => {},
            .cancelled => return error.Cancelled,
            .removed => return error.Removed,
            .failed => return error.ReadFailed,
        }
    }
};
