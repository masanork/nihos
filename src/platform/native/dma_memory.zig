//! CPU0 foreground service SRAM from the base linker's free regions.
//! 64-byte alignment; bounded leases, not task isolation or a general heap.
pub const Lease = extern struct { start: u32 = 0, bytes: u32 = 0, generation: u32 = 0, owner: u32 = 0 };
pub const display_owner: u32 = 1;
extern fn nih_base_sram_take(u32, u32, u32, *Lease) callconv(.c) bool;
extern fn nih_base_sram_release(*const Lease) callconv(.c) bool;

pub inline fn take(owner: u32, minimum: u32, maximum: u32) ?Lease {
    var lease: Lease = .{};
    return if (nih_base_sram_take(owner, minimum, maximum, &lease)) lease else null;
}
/// DMA clients must confirm retirement and erase private data before release.
pub inline fn release(lease: Lease) bool {
    return nih_base_sram_release(&lease);
}
