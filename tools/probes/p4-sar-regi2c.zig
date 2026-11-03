//! RV32 compilation only; no hardware access or entropy qualification.
const sar = @import("sar_regi2c");
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
export fn nih_sar_regi2c_compile_probe(tx: *sar.Transaction, now: u64) u32 {
    var io: IO = .{};
    tx.start(&io, 9, null, now, 100) catch return 0;
    return @backingInt(tx.poll(&io, now));
}
