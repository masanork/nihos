//! Native allocator adapter for the experimental Hosted long-DMA reservation.
//! Call only in a normal-storage profile that links the service SRAM pool.
//! This reserves memory for the entire boot; it is not connected to networking.
const dma_memory = @import("dma_memory.zig");
const storage = @import("hosted_long_storage");

extern var __service_sram0_start: u8;
extern var __service_sram0_end: u8;
extern var __service_sram1_start: u8;
extern var __service_sram1_end: u8;

pub const Region = struct { start: u32, end: u32 };

/// Range checking complements, but does not replace, the allocator's unique
/// generation and ownership checks. Callers must use a fresh pool lease.
pub fn validLease(lease: dma_memory.Lease, regions: [2]Region) bool {
    if (lease.owner != storage.owner_id or lease.generation == 0 or
        lease.bytes != storage.bytes or lease.start & 63 != 0) return false;
    for (regions) |region| {
        if (region.start >= region.end or lease.start < region.start or lease.start >= region.end) continue;
        if (lease.bytes <= region.end - lease.start) return true;
    }
    return false;
}

pub const Pool = struct {
    pub const Lease = dma_memory.Lease;

    pub fn take(_: *@This(), owner: u32, bytes: usize) ?Lease {
        if (owner != storage.owner_id or bytes != storage.bytes) return null;
        return dma_memory.take(owner, @intCast(bytes), @intCast(bytes));
    }
    pub fn resolve(_: *@This(), lease: Lease) ?*storage.Buffer {
        const regions = [2]Region{
            .{ .start = @intCast(@intFromPtr(&__service_sram0_start)), .end = @intCast(@intFromPtr(&__service_sram0_end)) },
            .{ .start = @intCast(@intFromPtr(&__service_sram1_start)), .end = @intCast(@intFromPtr(&__service_sram1_end)) },
        };
        if (!validLease(lease, regions)) return null;
        return @ptrFromInt(lease.start);
    }
};

pub const Owner = storage.Owner(Pool);

test "native long DMA reservation validates owner, exact regions and alignment" {
    const t = @import("std").testing;
    const regions = [2]Region{ .{ .start = 0x4ff40000, .end = 0x4ff60000 }, .{ .start = 0x4ff6e000, .end = 0x4ff9f000 } };
    const good: dma_memory.Lease = .{ .start = regions[0].start, .bytes = storage.bytes, .generation = 1, .owner = storage.owner_id };
    try t.expect(validLease(good, regions));
    var bad = good;
    bad.start += 1;
    try t.expect(!validLease(bad, regions));
    bad = good;
    bad.start = regions[1].end - 64;
    try t.expect(!validLease(bad, regions));
    bad = good;
    bad.start = regions[0].end;
    try t.expect(!validLease(bad, regions));
    bad = good;
    bad.owner = storage.owner_id + 1;
    try t.expect(!validLease(bad, regions));
    bad = good;
    bad.generation = 0;
    try t.expect(!validLease(bad, regions));
    bad = good;
    bad.bytes -= 64;
    try t.expect(!validLease(bad, regions));
    bad = good;
    bad.start = 0xffffffc0;
    try t.expect(!validLease(bad, regions));
    bad = good;
    bad.start = regions[1].start;
    try t.expect(validLease(bad, regions));
}
