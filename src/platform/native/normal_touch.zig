//! CPU0 foreground adapter. Borrows board I2C and the running UI timer;
//! never resets either controller/power policy, owns no IRQ or DMA memory.
const pointer = @import("pointer_input");
const Shared = pointer.TouchService(@import("card").Touch, pointer);
pub const Status = Shared.Status;
pub const Events = Shared.Events;
pub const begin = Shared.begin;
pub const ready = Shared.ready;
pub const pop = Shared.pop;
pub const poll = Shared.poll;
pub const snapshot = Shared.snapshot;
pub const eventSnapshot = Shared.eventSnapshot;
