//! Serialized block owner bridge. The synchronous caller must own/pin its
//! destination until return; the permanent ledger additionally quarantines a
//! failed controller transaction. It never converts a timeout into a fence.
pub const Signal = @import("io_stop.zig").Signal;
pub const CancelRelay = @import("io_stop.zig").CancelRelay;
const io = @import("io_leases.zig");
pub const Error = error{ Busy, Exhausted, Quarantined, ReadFailed, WriteFailed, PublicationUnknown, RecoveryRequired, Cancelled, Removed };
pub const ReadOwner = struct {
    requests: io.IoLeases(1) = .{},
    generation: u64 = 1,
    recovery_required: bool = false,
    pub fn busy(self: *const @This()) bool {
        return self.requests.holdsMount(.{ .slot = 0, .generation = self.generation });
    }
    /// Check before replacing controller state or clearing a removal latch.
    /// Hardware reinitialization and publication of the next generation remain
    /// the serialized owner's responsibility.
    pub fn canRestart(self: *const @This(), ticket_active: bool, session_active: bool, quiescent: bool) bool {
        return !self.busy() and !ticket_active and !session_active and quiescent and self.generation < 0xffff_ffff;
    }
    /// Serialized with reads through the same ledger. Once CMD24 is issued,
    /// any failure or cancellation has unknown publication outcome and the
    /// owner must be rebuilt only after media recovery. A successful transfer
    /// is not by itself a power-loss durability barrier.
    pub inline fn write(self: *@This(), controller: anytype, lba: u32, source: *const [512]u8, buffer_lease: u64, control: anytype) Error!void {
        if (self.busy()) {
            _ = control.finishReason();
            return error.Busy;
        }
        if (self.recovery_required) {
            _ = control.finishReason();
            return error.RecoveryRequired;
        }
        const mount = io.Reference{ .slot = 0, .generation = self.generation };
        const request = self.requests.retain(0, mount, mount, buffer_lease) catch {
            _ = control.finishReason();
            return error.Exhausted;
        };
        self.requests.start(request) catch {
            _ = control.finishReason();
            return error.Quarantined;
        };
        const successful = if (controller.writeSectorControlled(lba, source, control)) |_| true else |_| false;
        const reason = control.finishReason();
        const uncertain = controller.write_issued and (!successful or reason != .none);
        if (uncertain) self.recovery_required = true;
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
        if (uncertain) return error.PublicationUnknown;
        switch (completion.outcome) {
            .completed => {},
            .cancelled => return error.Cancelled,
            .removed => return error.Removed,
            .failed => return error.WriteFailed,
        }
    }
    pub inline fn read(self: *@This(), controller: anytype, lba: u32, destination: *[512]u8, buffer_lease: u64, control: anytype) Error!void {
        if (self.busy()) {
            _ = control.finishReason();
            return error.Busy;
        }
        if (self.recovery_required) {
            _ = control.finishReason();
            return error.RecoveryRequired;
        }
        const mount = io.Reference{ .slot = 0, .generation = self.generation };
        const request = self.requests.retain(0, mount, mount, buffer_lease) catch {
            _ = control.finishReason();
            return error.Exhausted;
        };
        self.requests.start(request) catch {
            _ = control.finishReason();
            return error.Quarantined;
        };
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
