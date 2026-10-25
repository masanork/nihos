//! WFI resumes for a locally enabled pending interrupt even with global MIE
//! clear. Keep MIE clear across the final exit check and WFI, then restore
//! its exact prior state so an arrival in that gap cannot be handled early.
pub const InterruptWait = struct {
    pub fn mask(_: *InterruptWait) u32 {
        return asm volatile ("csrrci %[previous], mstatus, 8"
            : [previous] "=r" (-> u32),
            :
            : .{ .memory = true });
    }

    pub fn wait(_: *InterruptWait) void {
        asm volatile ("wfi" ::: .{ .memory = true });
    }

    pub fn restore(_: *InterruptWait, previous: u32) void {
        asm volatile ("csrw mstatus, %[previous]"
            :
            : [previous] "r" (previous),
            : .{ .memory = true });
    }
};
