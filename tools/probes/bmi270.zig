//! SDK-free code generation of every BMI270 state; no hardware execution.
const imu = @import("tab5_bmi270");
extern fn nih_imu_test_transfer(u8, [*]const u8, usize, [*]u8, usize) callconv(.c) bool;
extern fn nih_imu_test_clock() callconv(.c) u64;
const Bus = struct {
    pub fn transfer(_: *Bus, addr: u8, write: []const u8, read: []u8) !void {
        if (!nih_imu_test_transfer(addr, write.ptr, write.len, read.ptr, read.len)) return error.Nack;
    }
};
const Clock = struct {
    pub fn counter(_: Clock) ?u64 {
        return nih_imu_test_clock();
    }
};
export fn nih_imu_codegen(driver: *imu.Driver) void {
    var bus: Bus = .{};
    driver.poll(&bus, Clock{});
}
