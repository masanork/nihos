//! Boot-lifetime reservation for one experimental long Hosted DMA buffer.
//! This owns no SDMMC lease and does not start, stop, or prove quiescence of
//! DMA. The pool must map its opaque lease to exclusively owned, aligned,
//! DMA-capable storage and retain it until reboot. There is no release API.
const std = @import("std");
const dma = @import("hosted_long_dma.zig");
pub const Buffer = dma.Buffer;

pub const owner_id: u32 = 3;
pub const bytes: usize = std.mem.alignForward(usize, @sizeOf(dma.Buffer), 64);
pub const State = enum { empty, held, quarantined };
pub const Error = error{ AlreadyReserved, NoStorage, InvalidLease, Quarantined };

/// Pool provides Lease, take(owner, bytes) and resolve(Lease). A successful
/// take is permanent, including when resolve reports a malformed lease. The
/// owner is CPU0-only and must outlive every pointer returned by buffer().
pub fn Owner(comptime Pool: type) type {
    return struct {
        state: State = .empty,
        lease: ?Pool.Lease = null,
        backing: ?*dma.Buffer = null,

        pub fn reserve(self: *@This(), pool: *Pool) Error!void {
            if (self.state == .quarantined) return error.Quarantined;
            if (self.state != .empty) return error.AlreadyReserved;
            const lease = pool.take(owner_id, bytes) orelse return error.NoStorage;
            // Publish the lease before resolving; invalid allocations remain
            // reserved and fail closed instead of being returned to the pool.
            self.lease = lease;
            self.state = .quarantined;
            const backing = pool.resolve(lease) orelse return error.InvalidLease;
            if (@intFromPtr(backing) & 63 != 0) return error.InvalidLease;
            // Fresh allocator storage has never been used for DMA. Zeroing it
            // in place avoids a large stack temporary and initializes idle=0.
            comptime std.debug.assert(@backingInt(dma.State.idle) == 0);
            @memset(std.mem.asBytes(backing), 0);
            self.backing = backing;
            self.state = .held;
        }

        pub fn buffer(self: *@This()) ?*dma.Buffer {
            if (self.state != .held) return null;
            const backing = self.backing orelse return null;
            switch (backing.state) {
                .idle => return backing,
                .prepared => return null,
                .retired => {
                    self.state = .quarantined;
                    return null;
                },
            }
        }

        /// Never erases or releases memory that DMA might still access.
        pub fn retire(self: *@This()) void {
            if (self.backing) |backing| backing.retire();
            if (self.state != .empty) self.state = .quarantined;
        }
    };
}
