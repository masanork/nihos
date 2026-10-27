//! Transfer CPU0's qualified scheduler timer to a foreground elapsed-time owner.
//! Timer.start() also arms an alarm, so disarm alone cannot close the IRQ window.
const std = @import("std");
pub const cpu0_timer_clic: u32 = 0x20801040;
pub const cpu0_timer_route: u32 = 0x500d6000 + 46 * 4;

pub fn retire(io: anytype, clock: anytype) void {
    const previous = io.maskInterrupts();
    defer io.restoreInterrupts(previous);
    io.write(cpu0_timer_clic, 0);
    io.write(cpu0_timer_route, 0);
    clock.stop();
    io.fence();
}

const Model = struct {
    enabled: bool = true,
    clic: u32 = 1,
    route: u32 = 16,
    peer_route: u32 = 16,
    pending: bool = false,
    running: bool = true,
    alarm: bool = false,
    scheduler_entries: u32 = 0,
    fn deliver(self: *Model) void {
        if (self.enabled and self.clic != 0 and self.route == 16 and self.pending) self.scheduler_entries += 1;
    }
    const Io = struct {
        model: *Model,
        pub fn maskInterrupts(self: @This()) u32 {
            const previous: u32 = if (self.model.enabled) 8 else 0;
            self.model.enabled = false;
            return previous;
        }
        pub fn restoreInterrupts(self: @This(), previous: u32) void {
            self.model.enabled = previous & 8 != 0;
            self.model.deliver();
        }
        pub fn write(self: @This(), address: u32, value: u32) void {
            switch (address) {
                cpu0_timer_clic => self.model.clic = value,
                cpu0_timer_route => self.model.route = value,
                else => unreachable,
            }
            self.model.deliver();
        }
        pub fn fence(_: @This()) void {}
    };
    const Clock = struct {
        model: *Model,
        pub fn stop(self: @This()) void {
            self.model.running = false;
            self.model.alarm = false;
            self.model.pending = false;
        }
        fn start(self: @This()) void {
            self.model.running = true;
            self.model.alarm = true;
            // The old absolute alarm deadline has already elapsed. Interrupt
            // delivery can occur before the foreground caller's next disarm.
            self.model.pending = true;
            self.model.deliver();
        }
        fn disarm(self: @This()) void {
            self.model.alarm = false;
            self.model.pending = false;
        }
    };
};

test "foreground timer start/disarm cannot reenter the retired scheduler" {
    var old = Model{};
    const old_clock = Model.Clock{ .model = &old };
    old_clock.stop();
    old_clock.start();
    old_clock.disarm();
    try std.testing.expectEqual(@as(u32, 1), old.scheduler_entries);

    for ([_]bool{ false, true }) |enabled| {
        var model = Model{ .enabled = enabled, .pending = true };
        const io = Model.Io{ .model = &model };
        const clock = Model.Clock{ .model = &model };
        retire(io, clock);
        try std.testing.expectEqual(enabled, model.enabled);
        try std.testing.expectEqual(@as(u32, 16), model.peer_route);
        try std.testing.expect(!model.running and !model.pending);
        clock.start();
        clock.disarm();
        try std.testing.expect(model.running and !model.alarm);
        try std.testing.expectEqual(@as(u32, 0), model.scheduler_entries);
    }
}
