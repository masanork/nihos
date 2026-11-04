//! Compile only: ownership stubs are not suitable for hardware execution.
const noise = @import("rng_noise");
const IO = struct {
    pub fn owned(_: *@This()) bool {
        return true;
    }
    pub fn clockReady(_: *@This()) bool {
        return true;
    }
    pub fn read(_: *@This(), address: usize) u32 {
        return @as(*const volatile u32, @ptrFromInt(address)).*;
    }
    pub fn write(_: *@This(), address: usize, value: u32) void {
        @as(*volatile u32, @ptrFromInt(address)).* = value;
    }
};
export fn nih_p4_rng_noise_compile_probe(owner: *noise.Noise, now: u64) u32 {
    var io: IO = .{};
    owner.begin(&io, now, 1000, 100) catch return 0;
    _ = owner.poll(&io, now);
    owner.stop(&io);
    return @backingInt(owner.poll(&io, now));
}
