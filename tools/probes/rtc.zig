//! SDK-free RTC read/set code generation; never execute on a board.
const rtc = @import("tab5_rtc");
extern fn nih_rtc_test_transfer(u8, [*]const u8, usize, [*]u8, usize) callconv(.c) bool;
const Bus = struct {
    pub fn transfer(_: *Bus, addr: u8, write: []const u8, read: []u8) !void {
        if (!nih_rtc_test_transfer(addr, write.ptr, write.len, read.ptr, read.len)) return error.Nack;
    }
};
export fn nih_rtc_codegen(date: *const rtc.DateTime) bool {
    var bus: Bus = .{};
    rtc.set(&bus, date.*) catch return false;
    const value = rtc.read(&bus) catch return false;
    _ = value.calendar() catch return false;
    return true;
}
