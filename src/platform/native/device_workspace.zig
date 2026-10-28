//! One lazily reserved CPU0 SRAM block, never PSRAM/DMA aliases. The bounded
//! boot arena cannot free: the first successful request reserves 1536 B plus
//! alignment for this boot; clean I2S transfers reuse it. Failed cleanup pins it.
const memory = @import("native_memory");
const control = @import("device_control");
pub var gate: control.Gate = .{};
var storage: ?*align(64) [1536]u8 = null;
pub fn acquire(owner: control.Owner) bool {
    if (!gate.acquire(owner)) return false;
    if (storage == null) {
        const allocation = memory.alloc(1536, 64) orelse {
            _ = gate.release(owner, true);
            return false;
        };
        storage = @ptrCast(@alignCast(allocation.ptr));
    }
    @memset(storage.?, 0);
    return true;
}
pub fn pcm() *align(64) [1024]u8 {
    return @ptrCast(storage.?);
}
pub fn descriptors(comptime T: type) *align(64) T {
    comptime {
        if (@sizeOf(T) > 512 or @alignOf(T) > 64) @compileError("device DMA descriptors exceed shared reservation");
    }
    return @ptrCast(@alignCast(storage.?[1024..].ptr));
}
pub fn bytesReserved() u32 {
    return if (storage == null) 0 else 1536;
}
