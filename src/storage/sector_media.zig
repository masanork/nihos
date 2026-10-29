//! Experimental bounded sector adapter for checkpoint media; no native driver.
//! The owner must validate the lease and its exclusive range atomically with
//! every operation, serialize access, stop using buffers before returning,
//! and implement sync as a real durability barrier. Errors fault the adapter:
//! a failed write or sync may already have changed media and requires recovery.
pub const sector_bytes = 512;

pub fn Media(comptime Owner: type, comptime byte_count: u64) type {
    if (byte_count == 0 or byte_count % 4096 != 0) @compileError("whole checkpoint pages required");
    return struct {
        const Self = @This();
        pub const capacity = byte_count;
        owner: *Owner,
        lease: Owner.Lease,
        first: u64,
        faulted: bool = false,

        /// Owner grants are external; this only accepts an already granted
        /// exclusive range and never formats or chooses a region automatically.
        pub fn init(owner: *Owner, lease: Owner.Lease, first: u64, total_sectors: u64) error{Io}!Self {
            const sectors = capacity / sector_bytes;
            if (total_sectors > (@as(u64, 1) << 32) or first >= total_sectors or sectors > total_sectors - first) return error.Io;
            owner.checkRange(lease, first, sectors) catch return error.Io;
            return .{ .owner = owner, .lease = lease, .first = first };
        }
        fn fail(self: *Self) error{Io} {
            self.faulted = true;
            return error.Io;
        }
        fn valid(self: *const Self, offset: u64, len: usize) bool {
            return !self.faulted and offset <= capacity and len <= capacity - offset;
        }
        pub fn read(self: *Self, offset: u64, destination: []u8) error{Io}!void {
            if (!self.valid(offset, destination.len)) return self.fail();
            var position: usize = 0;
            while (position < destination.len) {
                const absolute = offset + position;
                const in_sector: usize = @intCast(absolute % sector_bytes);
                const amount = @min(destination.len - position, sector_bytes - in_sector);
                var sector: [sector_bytes]u8 = undefined;
                self.owner.readSector(self.lease, @intCast(self.first + absolute / sector_bytes), &sector) catch return self.fail();
                @memcpy(destination[position..][0..amount], sector[in_sector..][0..amount]);
                position += amount;
            }
        }
        pub fn write(self: *Self, offset: u64, bytes: []const u8) error{Io}!void {
            if (!self.valid(offset, bytes.len) or offset % sector_bytes != 0 or bytes.len % sector_bytes != 0) return self.fail();
            var position: usize = 0;
            while (position < bytes.len) : (position += sector_bytes) {
                const sector: *const [sector_bytes]u8 = bytes[position..][0..sector_bytes];
                self.owner.writeSector(self.lease, @intCast(self.first + (offset + position) / sector_bytes), sector) catch return self.fail();
            }
        }
        pub fn sync(self: *Self) error{Io}!void {
            if (self.faulted) return error.Io;
            self.owner.sync(self.lease) catch return self.fail();
        }
    };
}
