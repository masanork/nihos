//! Fail-closed scanout state shared by the boot poller and CPU0 ISR.
const std = @import("std");
pub const State = struct {
    frames: u32 = 0,
    fault: u32 = 0,
    backlight: bool = false,
    pub fn observe(self: *State, completed: bool, dma_errors: u32, underrun: bool) void {
        if (self.fault != 0) return;
        if (dma_errors != 0 or underrun) {
            self.fault = if (dma_errors != 0) 1 else 2;
            self.backlight = false;
            return;
        }
        if (completed) self.frames +|= 1;
        // Two complete DMA blocks before permitting a visible frame.
        if (self.frames >= 2) self.backlight = true;
    }
};
test "backlight requires completed frames and every fault latches dark" {
    var state = State{};
    state.observe(false, 0, false);
    try std.testing.expect(!state.backlight);
    state.observe(true, 0, false);
    try std.testing.expect(!state.backlight);
    state.observe(true, 0, false);
    try std.testing.expect(state.backlight);
    state.observe(true, 1 << 5, false);
    try std.testing.expect(!state.backlight and state.fault != 0);
    const frames = state.frames;
    state.observe(true, 0, false);
    try std.testing.expectEqual(frames, state.frames);
    var underrun = State{};
    underrun.observe(true, 0, true);
    try std.testing.expect(!underrun.backlight and underrun.fault == 2);
}
