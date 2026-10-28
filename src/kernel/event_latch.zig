//! Resident doorbell word. Publication precedes the hardware interrupt; the
//! serialized IRQ tail forwards take() to the kernel event wait, even if the
//! task has not registered its wait yet. Coalescing is safe: queues hold work.
const std = @import("std");
pub const Latch = extern struct {
    bits: std.atomic.Value(u32) = .init(0),
    pub inline fn notify(self: *@This()) void {
        _ = self.bits.fetchOr(1, .release);
    }
    pub inline fn take(self: *@This()) u32 {
        return self.bits.swap(0, .acq_rel);
    }
};
comptime {
    if (@sizeOf(Latch) != 4 or @alignOf(Latch) != 4) @compileError("IRQ doorbell must be one resident atomic word");
}
