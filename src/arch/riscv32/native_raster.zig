//! Lazy task-owned PSRAM mask storage. Only validated tokens expose a view.
const heap = @import("native_memory").reusable;
const lease = @import("raster_lease");
pub const Lease = lease.Lease;
var state: lease.State = .{ .producer = 0, .consumer = 0 };
var allocation: ?heap.Allocation = null;
var charge: u32 = 0;
pub const Report = struct {
    created: u32 = 0,
    discarded: u32 = 0,
    published: u32 = 0,
    reclaimed: u32 = 0,
    live_charge: u32 = 0,
    peak_charge: u32 = 0,
    held_ticks: u32 = 0,
    stale_rejected: u32 = 0,
    foreign_rejected: u32 = 0,
};
pub var metrics: Report = .{};
pub fn bind(producer: u32, consumer: u32) void {
    state = .{ .producer = producer, .consumer = consumer };
}
pub fn create() ![]u8 {
    const caller = try heap.currentIdentity();
    _ = try state.begin(caller);
    const before = heap.availableBytes() orelse return error.NotReady;
    allocation = heap.allocTask(16384, 16) catch |err| {
        try state.reclaim(caller, state.token);
        return err;
    };
    charge = @intCast(before - (heap.availableBytes() orelse return error.NotReady));
    metrics.created += 1;
    metrics.live_charge = charge;
    metrics.peak_charge = @max(metrics.peak_charge, charge);
    return allocation.?.bytes;
}
pub fn publish(bytes: u32) !Lease {
    const value = try state.publish(try heap.currentIdentity(), bytes);
    metrics.published += 1;
    return value;
}
pub fn read(value: Lease) ![]const u8 {
    const bytes = try state.read(try heap.currentIdentity(), value);
    return allocation.?.bytes[0..bytes];
}
pub fn retire(value: Lease) !void {
    try state.retire(try heap.currentIdentity(), value);
}
pub fn release(token: u32) !void {
    const discarded = state.phase == .writing;
    try state.reclaim(try heap.currentIdentity(), token);
    const before = heap.availableBytes() orelse return error.NotReady;
    @memset(allocation.?.bytes, 0xa5);
    try heap.freeTask(allocation.?);
    if ((heap.availableBytes() orelse return error.NotReady) - before != charge) return error.Accounting;
    allocation = null;
    metrics.live_charge = 0;
    if (discarded) metrics.discarded += 1 else metrics.reclaimed += 1;
}
pub fn discard() !void {
    try release(state.token);
}
pub fn liveCharge() u32 {
    return metrics.live_charge;
}
pub fn empty() bool {
    return allocation == null and state.phase == .vacant;
}
