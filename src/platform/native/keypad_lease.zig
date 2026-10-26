//! Each CPU allocates its own descriptor slab after its qualification finish.
//! CPU1 publishes one permanent DMA lease, then parks without touching it.
const tasks = @import("native_tasks");
pub const Lease = struct { start: u32, bytes: u32 };
var peer_lease = Lease{ .start = 0, .bytes = 0 };
var peer_ready: u32 = 0;
pub fn publishPeer() void {
    const available = tasks.memory.report(1).free & ~@as(u32, 63);
    if (available < 64) {
        @atomicStore(u32, &peer_ready, 2, .release);
        return;
    }
    const lease = tasks.memory.alloc(available, 64) orelse {
        @atomicStore(u32, &peer_ready, 2, .release);
        return;
    };
    peer_lease = .{ .start = @intFromPtr(lease.ptr), .bytes = @intCast(lease.len) };
    @atomicStore(u32, &peer_ready, 1, .release);
}
pub fn peer() ?Lease {
    return if (@atomicLoad(u32, &peer_ready, .acquire) == 1) peer_lease else null;
}
pub fn local() ?Lease {
    const available = tasks.memory.report(0).free & ~@as(u32, 63);
    const lease = tasks.memory.alloc(available, 64) orelse return null;
    return .{ .start = @intFromPtr(lease.ptr), .bytes = @intCast(lease.len) };
}
