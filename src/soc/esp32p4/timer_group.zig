//! ESP32-P4 Timer Group channel operations, independent of ESP-IDF.
//!
//! The owner supplies an exclusively leased, clocked 1 MHz channel and an
//! enabled peripheral interrupt. Shared clock, watchdog and interrupt-enable
//! registers belong to the resource owner and are never modified here.

const std = @import("std");

pub const Channel = extern struct {
    config: u32,
    count_low: u32,
    count_high: u32,
    update: u32,
    alarm_low: u32,
    alarm_high: u32,
    reload_low: u32,
    reload_high: u32,
    load: u32,
};

pub const alarm_enable: u32 = 1 << 10;
pub const auto_reload: u32 = 1 << 29;
pub const count_up: u32 = 1 << 30;
pub const counter_enable: u32 = 1 << 31;
pub const interrupt_status_offset: u32 = 0x78;
pub const interrupt_clear_offset: u32 = 0x7c;
pub const max_counter: u64 = (@as(u64, 1) << 54) - 1;
const capture_update: u32 = 1 << 31;

pub const Timer = struct {
    channel: *volatile Channel,
    interrupt_status: *volatile u32,
    interrupt_clear: *volatile u32,
    event_mask: u32,

    pub fn fromGroup(group_address: u32, channel_id: u32) ?Timer {
        if (group_address == 0 or group_address & 3 != 0 or channel_id >= 2 or
            group_address > std.math.maxInt(u32) - interrupt_clear_offset)
            return null;
        return .{
            .channel = @ptrFromInt(group_address + channel_id * @sizeOf(Channel)),
            .interrupt_status = @ptrFromInt(group_address + interrupt_status_offset),
            .interrupt_clear = @ptrFromInt(group_address + interrupt_clear_offset),
            .event_mask = @as(u32, 1) << @intCast(channel_id),
        };
    }

    /// Configure while stopped. The clock divider established by the owner is
    /// preserved; no assumption about the XTAL/PLL clock tree is made here.
    pub fn configure(self: Timer, period_ticks: u32) bool {
        if (period_ticks == 0) return false;
        self.stop();
        self.channel.config = (self.channel.config & ~counter_enable) |
            count_up | auto_reload;
        self.channel.reload_high = 0;
        self.channel.reload_low = 0;
        self.channel.load = 1;
        self.channel.alarm_high = 0;
        self.channel.alarm_low = period_ticks;
        return true;
    }

    pub fn start(self: Timer) void {
        self.channel.config = self.channel.config | alarm_enable | counter_enable;
    }

    /// Free-running mode: software supplies absolute future alarm deadlines.
    pub fn configureOneShot(self: Timer, first_deadline: u64) bool {
        if (first_deadline == 0 or first_deadline > max_counter) return false;
        self.stop();
        self.channel.config = (self.channel.config & ~auto_reload) | count_up;
        self.channel.reload_high = 0;
        self.channel.reload_low = 0;
        self.channel.load = 1;
        return self.armAt(first_deadline);
    }

    pub fn armAt(self: Timer, deadline: u64) bool {
        if (deadline == 0 or deadline > max_counter) return false;
        self.channel.alarm_high = @intCast(deadline >> 32);
        self.channel.alarm_low = @truncate(deadline);
        self.channel.config = self.channel.config | alarm_enable;
        return true;
    }

    /// Capture crosses a clock domain. Bound the wait so a bad peripheral
    /// cannot trap the kernel forever inside an interrupt.
    pub fn counter(self: Timer) ?u64 {
        self.channel.update = capture_update;
        for (0..1024) |_| {
            if (self.channel.update & capture_update == 0) {
                return (@as(u64, self.channel.count_high & 0x003f_ffff) << 32) |
                    self.channel.count_low;
            }
        }
        return null;
    }

    pub fn clearPending(self: Timer) bool {
        if (self.interrupt_status.* & self.event_mask == 0) return false;
        self.interrupt_clear.* = self.event_mask;
        return true;
    }

    /// Alarm-enable self-clears on a match even with hardware auto-reload.
    /// Acknowledge only this channel's W1C bit, then arm the next match.
    pub fn acknowledge(self: Timer) bool {
        if (!self.clearPending()) return false;
        self.channel.config = self.channel.config | alarm_enable;
        return true;
    }

    pub fn stop(self: Timer) void {
        self.channel.config = self.channel.config & ~(counter_enable | alarm_enable);
        self.interrupt_clear.* = self.event_mask;
    }

    /// Keep the free-running counter available for elapsed-time accounting,
    /// but remove this channel's alarm as a source of wakeups.
    pub fn disarm(self: Timer) void {
        self.channel.config = self.channel.config & ~alarm_enable;
        self.interrupt_clear.* = self.event_mask;
    }
};

comptime {
    if (@sizeOf(Channel) != 0x24 or @offsetOf(Channel, "load") != 0x20)
        @compileError("ESP32-P4 Timer Group channel layout changed");
}

test "one-shot deadlines retain 54-bit precision and disable auto-reload" {
    var channel = std.mem.zeroes(Channel);
    channel.config = (40 << 13) | auto_reload;
    var status: u32 = 1;
    var clear: u32 = 0;
    const timer = Timer{
        .channel = &channel,
        .interrupt_status = &status,
        .interrupt_clear = &clear,
        .event_mask = 1,
    };
    try std.testing.expect(timer.configureOneShot(0x12_3456_789a));
    try std.testing.expectEqual(@as(u32, 0x12), channel.alarm_high);
    try std.testing.expectEqual(@as(u32, 0x3456_789a), channel.alarm_low);
    try std.testing.expect(channel.config & auto_reload == 0);
    try std.testing.expect(!timer.armAt(max_counter + 1));
    try std.testing.expectEqual(@as(u32, 0x12), channel.alarm_high);
    // Plain memory never completes the hardware capture handshake.
    try std.testing.expect(timer.counter() == null);
    try std.testing.expect(timer.clearPending());
    try std.testing.expectEqual(@as(u32, 1), clear);
}

test "periodic timer preserves its divider and acknowledges only its own event" {
    const divider = 40 << 13;
    var channel = std.mem.zeroes(Channel);
    channel.config = divider | counter_enable | alarm_enable;
    var status: u32 = 0b111; // Both timers and the watchdog are pending.
    var clear: u32 = 0;
    const timer = Timer{
        .channel = &channel,
        .interrupt_status = &status,
        .interrupt_clear = &clear,
        .event_mask = 0b10,
    };
    try std.testing.expect(!timer.configure(0));
    try std.testing.expectEqual(divider | counter_enable | alarm_enable, channel.config);
    try std.testing.expect(timer.configure(1000));
    try std.testing.expectEqual(divider | count_up | auto_reload, channel.config);
    try std.testing.expectEqual(@as(u32, 1000), channel.alarm_low);
    try std.testing.expectEqual(@as(u32, 0), channel.reload_low);
    try std.testing.expectEqual(@as(u32, 1), channel.load);

    timer.start();
    channel.config &= ~alarm_enable; // Hardware cleared it after matching.
    try std.testing.expect(timer.acknowledge());
    try std.testing.expectEqual(@as(u32, 0b10), clear);
    try std.testing.expect(channel.config & alarm_enable != 0);
    status = 0b101;
    clear = 0;
    try std.testing.expect(!timer.acknowledge());
    try std.testing.expectEqual(@as(u32, 0), clear);
    channel.config |= alarm_enable;
    timer.disarm();
    try std.testing.expectEqual(divider | count_up | auto_reload | counter_enable, channel.config);
    try std.testing.expectEqual(@as(u32, 0b10), clear);
    timer.stop();
    try std.testing.expectEqual(@as(u32, 0b10), clear);
    try std.testing.expectEqual(divider | count_up | auto_reload, channel.config);
}

test "timer mapping rejects invalid channels and overflowing register windows" {
    try std.testing.expect(Timer.fromGroup(0, 0) == null);
    try std.testing.expect(Timer.fromGroup(0x5000_0001, 0) == null);
    try std.testing.expect(Timer.fromGroup(0x5000_0000, 2) == null);
    try std.testing.expect(Timer.fromGroup(0xffff_ffc0, 0) == null);
    const timer = Timer.fromGroup(0x5000_0000, 1).?;
    try std.testing.expectEqual(@as(usize, 0x5000_0024), @intFromPtr(timer.channel));
    try std.testing.expectEqual(@as(usize, 0x5000_007c), @intFromPtr(timer.interrupt_clear));
}
