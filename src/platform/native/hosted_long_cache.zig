//! Experimental CPU0-only cache adapter for the long Hosted DMA fixture.
//! Caller owns aligned storage and keeps CPU1 out of the ROM cache engine.
const std = @import("std");

pub fn Adapter(comptime Ops: type) type {
    return struct {
        ops: Ops,
        pub fn address(_: *@This(), ptr: anytype) ?u32 {
            const addr = @intFromPtr(ptr);
            if (addr % 64 != 0 or addr > std.math.maxInt(u32)) return null;
            return @intCast(addr);
        }
        fn operate(self: *@This(), addr: usize, length: usize, invalidating: bool) bool {
            if (addr % 64 != 0 or length == 0 or length > 1536 or length % 64 != 0 or
                addr > std.math.maxInt(u32) or length - 1 > std.math.maxInt(u32) - addr) return false;
            const previous = self.ops.mask();
            defer self.ops.restore(previous);
            self.ops.fence();
            const status = self.ops.cache(@intCast(addr), @intCast(length), invalidating);
            self.ops.fence();
            return status == 0;
        }
        pub fn writeback(self: *@This(), addr: usize, length: usize) bool {
            return self.operate(addr, length, false);
        }
        pub fn invalidate(self: *@This(), addr: usize, length: usize) bool {
            return self.operate(addr, length, true);
        }
        pub fn fence(self: *@This()) void {
            self.ops.fence();
        }
    };
}

extern fn nih_rom_cache_writeback(u32, u32, u32) callconv(.c) i32;
extern fn nih_rom_cache_invalidate(u32, u32, u32) callconv(.c) i32;
pub const RomOps = struct {
    pub fn mask(_: *@This()) u32 {
        return asm volatile ("csrrci %[previous], mstatus, 8"
            : [previous] "=r" (-> u32),
            :
            : .{ .memory = true });
    }
    pub fn restore(_: *@This(), previous: u32) void {
        if (previous & 8 != 0) asm volatile ("csrsi mstatus, 8" ::: .{ .memory = true });
    }
    pub fn fence(_: *@This()) void {
        asm volatile ("fence iorw, iorw" ::: .{ .memory = true });
    }
    pub fn cache(_: *@This(), addr: u32, length: u32, invalidate: bool) i32 {
        return if (invalidate) nih_rom_cache_invalidate(1 << 4, addr, length) else nih_rom_cache_writeback(1 << 4, addr, length);
    }
};
pub const Rom = Adapter(RomOps);
