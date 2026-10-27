//! Compile-only native SDIO + AT fixture. Do not call this on a live system.
const probe = @import("c6_probe");
const timers = @import("timer_group");
export fn nih_c6_sdio_compile_probe() u32 {
    return probe.run(timers.Timer.fromGroup(0x500c2000, 0).?, .saved).status;
}
export fn nih_c6_hosted_compile_probe() u32 {
    return probe.runHosted(timers.Timer.fromGroup(0x500c2000, 0).?, .saved, true).status;
}
