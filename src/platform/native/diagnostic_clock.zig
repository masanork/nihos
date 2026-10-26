//! Dedicated TG1.T0, 40 MHz XTAL /40. Never borrows TG0 scheduler channels.
const timers = @import("timer_group");
fn reg(address: usize) *volatile u32 {
    return @ptrFromInt(address);
}
pub fn timer() timers.Timer {
    return timers.Timer.fromGroup(0x500c3000, 0).?;
}
pub fn initialize() bool {
    reg(0x500e601c).* |= 1 << 22;
    reg(0x500e60c4).* |= 1 << 7;
    reg(0x500e60c4).* &= ~@as(u32, 1 << 7);
    reg(0x500c3064).* = 0x50d83aa1;
    reg(0x500c3048).* = 0;
    reg(0x500c3064).* = 0;
    reg(0x500e6098).* = (reg(0x500e6098).* & ~@as(u32, 3 << 20)) | (1 << 22);
    reg(0x500c3070).* = 0; // no TG1 interrupts; counter only.
    const counter = timer();
    counter.channel.config = 40 << 13;
    if (!counter.configureOneShot(1)) return false;
    counter.disarm();
    counter.channel.config |= timers.counter_enable;
    return counter.counter() != null;
}
