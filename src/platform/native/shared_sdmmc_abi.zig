//! Foreground-only C boundary. A lease is captured once, never reconstructed
//! from whichever owner happens to hold the host later. No IRQ/client pointers.
pub const Lease = extern struct { serial: u32 = 0, generation: u32 = 0, slot: u32 = 0 };
extern fn nih_shared_sdmmc_acquire(u32, *Lease) callconv(.c) u32;
extern fn nih_shared_sdmmc_release(*const Lease) callconv(.c) u32;
extern fn nih_shared_sdmmc_owns(*const Lease) callconv(.c) u32;
extern fn nih_shared_sdmmc_read(*const Lease, u32) callconv(.c) u32;
extern fn nih_shared_sdmmc_write(*const Lease, u32, u32) callconv(.c) void;
extern fn nih_shared_sdmmc_generation() callconv(.c) u32;
pub fn acquire(slot: u32) error{ Busy, Unavailable }!Lease {
    var lease = Lease{};
    return switch (nih_shared_sdmmc_acquire(slot, &lease)) {
        0 => lease,
        1 => error.Busy,
        else => error.Unavailable,
    };
}
pub const Release = enum(u32) { clean, recovered, quarantined, invalid };
pub fn release(lease: Lease) Release {
    return @fromBackingInt(@intCast(nih_shared_sdmmc_release(&lease)));
}
pub fn owns(lease: Lease) bool {
    return nih_shared_sdmmc_owns(&lease) == 1;
}
pub fn read(lease: Lease, register: usize) u32 {
    return nih_shared_sdmmc_read(&lease, @intCast(register));
}
pub fn write(lease: Lease, register: usize, value: u32) void {
    nih_shared_sdmmc_write(&lease, @intCast(register), value);
}
pub fn generation() u32 {
    return nih_shared_sdmmc_generation();
}
