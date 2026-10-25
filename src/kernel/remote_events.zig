//! One remote producer submits events; only the owner CPU mutates policy.
//! Post always publishes before ringing. The owner acknowledges the hardware
//! before draining, so posts concurrent with drain remain pending in hardware.
pub const Notification = struct { slot: u16, generation: u16, bits: u32 };
pub const PostResult = enum { queued, full, invalid };
pub const DrainReport = struct { delivered: u32 = 0, rejected: u32 = 0, woken: u32 = 0 };

pub fn Inbox(comptime Ring: type) type {
    if (Ring.Item != Notification) @compileError("event inbox needs Notification values");
    return struct {
        const Self = @This();
        ring: Ring = Ring.init(),

        pub fn post(self: *Self, notification: Notification, doorbell: anytype) PostResult {
            if (notification.generation == 0 or notification.bits == 0) return .invalid;
            if (!self.ring.tryPush(notification)) return .full;
            doorbell.raise();
            return .queued;
        }

        /// Owner-only, serialized with local waits/notifies. A stale or dead
        /// target consumes its queue record without affecting other records.
        /// A fixed budget bounds the interrupt tail even under producer load.
        pub fn drain(self: *Self, policy: anytype, comptime budget: usize, doorbell: anytype) DrainReport {
            if (budget == 0) @compileError("event inbox drain budget must be nonzero");
            var result = DrainReport{};
            for (0..budget) |_| {
                const notification = self.ring.tryPop() orelse break;
                if (policy.notify(.{ .slot = notification.slot, .generation = notification.generation }, notification.bits)) |woken| {
                    result.delivered += 1;
                    result.woken += @intFromBool(woken);
                } else result.rejected += 1;
            }
            // A short budget can leave records whose original doorbell was
            // acknowledged already. Reassert rather than waiting for a new
            // producer post. Only this owner changes the read counter, so
            // countApprox's read-counter stability check completes here.
            if (self.ring.countApprox() != 0) doorbell.raise();
            return result;
        }
    };
}
