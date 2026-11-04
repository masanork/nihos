//! Compile-only MMIO instantiation. Not an ADC owner or entropy source.
const adc = @import("rng_adc");
const IO = struct {
    pub fn ownershipValid(_: *@This()) bool {
        return true;
    }
    pub fn analogReady(_: *@This()) bool {
        return true;
    }
    pub fn read(_: *@This(), address: usize) u32 {
        return @as(*const volatile u32, @ptrFromInt(address)).*;
    }
    pub fn write(_: *@This(), address: usize, value: u32) void {
        @as(*volatile u32, @ptrFromInt(address)).* = value;
    }
};
export fn nih_p4_rng_adc_compile_probe(session: *adc.Session) u32 {
    var io: IO = .{};
    session.prepare(&io) catch return 0;
    session.activate(&io) catch return 0;
    _ = session.poll(&io);
    return @intFromBool(session.stop(&io));
}
