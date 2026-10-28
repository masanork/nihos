//! CPU-only service parent layout. Native DMA remains in fixed internal SRAM.
//! Allocate/charge one 64 KiB external broker parent and pin until endpoint,
//! queues and C filesystem have all completed ordinary-owner teardown.
const std = @import("std");
const broker = @import("../kernel/memory_broker.zig");
pub const parent_bytes = 64 * 1024;
pub const Layout = struct {
    disk: usize,
    backend: usize,
    endpoint: usize,
    queues: usize,
    used: usize,
    pub fn make(disk: usize, backend: usize, endpoint: usize, queues: usize) error{TooLarge}!Layout {
        var at: usize = 0;
        // SAFETY: All four entries are assigned before constructing the result.
        var offsets: [4]usize = undefined;
        for ([_]usize{ disk, backend, endpoint, queues }, 0..) |bytes, i| {
            if (bytes == 0 or bytes > parent_bytes) return error.TooLarge;
            at = std.mem.alignForward(usize, at, 128);
            offsets[i] = at;
            if (bytes > parent_bytes - at) return error.TooLarge;
            at += bytes;
        }
        return .{ .disk = offsets[0], .backend = offsets[1], .endpoint = offsets[2], .queues = offsets[3], .used = at };
    }
};

/// Coordinator metadata lives outside its payload. IRQs never call this API.
/// One pin spans initialization, every dispatch and final private-FS teardown.
pub const Parent = struct {
    lease: broker.Lease,
    borrow: ?broker.Borrow,
    pub fn reserve(manager: anytype, owner: broker.Owner) !Parent {
        const lease = try manager.alloc(owner, .external, parent_bytes, 128);
        errdefer manager.free(owner, lease) catch @panic("serialized VFS parent rollback failed");
        return .{ .lease = lease, .borrow = try manager.pin(owner, lease) };
    }
    /// Does not free the parent. After success, the caller may free the returned
    /// lease or let a closing owner's ordinary reaper reclaim it. On failure
    /// the pin remains held, including while private FS teardown is busy.
    pub fn retire(self: *@This(), manager: anytype, endpoint: anytype, queues: anytype, filesystem: anytype) !broker.Lease {
        const held = self.borrow orelse return error.InvalidPin;
        try endpoint.shutdown(queues);
        try filesystem.destroy();
        @memset(held.bytes, 0);
        try manager.unpin(held.token);
        self.borrow = null;
        return self.lease;
    }
};
