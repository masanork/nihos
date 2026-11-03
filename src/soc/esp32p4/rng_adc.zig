//! P4 SAR digital setup for the RNG noise source (ESP-IDF v5.4.4 layout).
//! Analog setup, ownership, clock/power and entropy qualification are separate.
const std = @import("std");
const adc: usize = 0x500de000;
const ctrl = adc + 0x00;
const ctrl2 = adc + 0x04;
const pattern = adc + 0x18;
const int_enable = adc + 0x50;
const int_raw = adc + 0x54;
const int_clear = adc + 0x5c;
const dma = adc + 0x60;
const mux: usize = 0x50127010;
const clock_div: usize = 0x500e60a4;
const mux_force: u32 = 1 << 31;
const force_start: u32 = 1;
const start_bit: u32 = 1 << 1;
const work_mode: u32 = 0x1c;
const pattern_length: u32 = 15 << 14;
const sar_power: u32 = 15 << 26;
const ctrl_mask: u32 = force_start | pattern_length | sar_power;
const timer_enable: u32 = 1 << 24;
const timer_target: u32 = 0xfff << 12;
const ctrl2_mask: u32 = timer_enable | timer_target;
const done: u32 = 1 << 31;
const events: u32 = 0xfc00_0000;
const dma_enable: u32 = 1 << 31;
const reset_fsm: u32 = 1 << 30;
const pattern_mask: u32 = 0xffffff;
const noise_pattern: u32 = 0xae_ba_eb; // channel 10, attenuation 3, four entries.

/// Caller owns both SAR units, their digital controller, interrupt, shared
/// clock/power fields and analog bus, with clocks enabled. ownershipValid()
/// must remain true until stop completes. analogReady() must only be true
/// after the separate SAR analog setup is complete. These checks do not prove
/// source entropy or exclude an uncooperative hardware user.
pub const Session = struct {
    const State = enum { idle, prepared, running, ready, quarantined };
    pub const Poll = enum { pending, ready, unavailable };
    state: State = .idle,
    saved_ctrl: u32 = 0,
    saved_ctrl2: u32 = 0,
    saved_pattern: u32 = 0,
    saved_mux: u32 = 0,
    target: u32 = 0,

    fn setMasked(io: anytype, address: usize, mask: u32, value: u32) void {
        io.write(address, (io.read(address) & ~mask) | (value & mask));
    }

    /// Read the SAR1 divider field while clocks are stable under ownership.
    /// Refuse active controller/DMA/interrupt state rather than consuming it.
    pub fn prepare(self: *Session, io: anytype) !void {
        if (self.state != .idle) return error.Busy;
        if (!io.ownershipValid()) return error.Unavailable;
        const divider = io.read(clock_div) & 0xff;
        if (divider == 0 or divider > 0xfff / 25) return error.InvalidDivider;
        if (io.read(ctrl2) & timer_enable != 0 or io.read(dma) & (dma_enable | reset_fsm) != 0 or
            io.read(ctrl) & (start_bit | work_mode) != 0 or io.read(int_enable) & events != 0 or
            io.read(int_raw) & events != 0) return error.Busy;
        self.saved_ctrl = io.read(ctrl) & ctrl_mask;
        self.saved_ctrl2 = io.read(ctrl2) & ctrl2_mask;
        self.saved_pattern = io.read(pattern) & pattern_mask;
        self.saved_mux = io.read(mux) & mux_force;
        self.target = divider * 25;
        setMasked(io, mux, mux_force, mux_force);
        setMasked(io, ctrl, force_start, force_start);
        self.state = .prepared;
    }

    /// Invoke only after the SAR analog fields have been configured.
    pub fn activate(self: *Session, io: anytype) !void {
        if (self.state != .prepared) return error.InvalidState;
        if (!io.ownershipValid()) {
            self.state = .quarantined;
            return error.Unavailable;
        }
        if (!io.analogReady()) return error.Unavailable;
        if (io.read(int_raw) & events != 0) return error.Busy;
        setMasked(io, pattern, pattern_mask, noise_pattern);
        setMasked(io, ctrl, ctrl_mask, sar_power); // length 1, both SAR power on, timer trigger.
        setMasked(io, ctrl2, ctrl2_mask, timer_enable | (self.target << 12));
        self.state = .running;
    }

    /// One completion check, no wait. Caller enforces an absolute deadline.
    pub fn poll(self: *Session, io: anytype) Poll {
        if (self.state != .running and self.state != .ready) return .unavailable;
        if (!io.ownershipValid() or !io.analogReady()) {
            self.state = .quarantined;
            return .unavailable;
        }
        const observed = io.read(int_raw) & events;
        if (observed & ~done != 0) {
            self.state = .quarantined;
            return .unavailable;
        }
        if (self.state == .ready) return .ready;
        if (observed & done == 0) return .pending;
        io.write(int_clear, done);
        self.state = .ready;
        return .ready;
    }

    /// Disable the trigger, then reset the digital FSM as in IDF's P4 ADC
    /// deinit. Analog fields must be restored separately while still owned.
    /// Never call after losing ownership; external recovery is then required.
    pub fn stop(self: *Session, io: anytype) bool {
        if (self.state == .idle) return true;
        if (self.state == .quarantined or !io.ownershipValid()) {
            self.state = .quarantined;
            return false;
        }
        const unexpected = if (self.state == .prepared) events else events & ~done;
        if (io.read(int_raw) & unexpected != 0) {
            self.state = .quarantined;
            return false;
        }
        setMasked(io, ctrl2, timer_enable, 0);
        setMasked(io, dma, reset_fsm, reset_fsm);
        setMasked(io, dma, reset_fsm, 0);
        io.write(int_clear, done);
        setMasked(io, pattern, pattern_mask, self.saved_pattern);
        setMasked(io, ctrl, ctrl_mask, self.saved_ctrl);
        setMasked(io, ctrl2, ctrl2_mask, self.saved_ctrl2);
        setMasked(io, mux, mux_force, self.saved_mux);
        self.* = .{};
        return true;
    }
};

const Fake = struct {
    registers: [9]u32 = .{ 0x4000_0000, 0x42, 0xab12_3456, 0, 0, 0, 0x1234, 0x1234_5678, 4 },
    valid: bool = true,
    analog: bool = true,
    writes: u32 = 0,
    resets: u32 = 0,
    fn ownershipValid(self: *@This()) bool {
        return self.valid;
    }
    fn analogReady(self: *@This()) bool {
        return self.analog;
    }
    fn index(address: usize) usize {
        return switch (address) {
            ctrl => 0,
            ctrl2 => 1,
            pattern => 2,
            int_enable => 3,
            int_raw => 4,
            int_clear => 5,
            dma => 6,
            mux => 7,
            clock_div => 8,
            else => unreachable,
        };
    }
    fn read(self: *@This(), address: usize) u32 {
        return self.registers[index(address)];
    }
    fn write(self: *@This(), address: usize, value: u32) void {
        self.writes += 1;
        if (address == int_clear) {
            self.registers[index(int_raw)] &= ~value;
        } else {
            if (address == dma and value & reset_fsm != 0) self.resets += 1;
            self.registers[index(address)] = value;
        }
    }
};

test "noise conversion waits for done and restores prior register fields" {
    var io: Fake = .{};
    const original = io.registers;
    var session: Session = .{};
    try session.prepare(&io);
    try std.testing.expect(io.read(ctrl) & force_start != 0);
    try session.activate(&io);
    try std.testing.expectEqual(noise_pattern, io.read(pattern) & pattern_mask);
    try std.testing.expectEqual(@as(u32, 100), (io.read(ctrl2) & timer_target) >> 12);
    try std.testing.expectEqual(Session.Poll.pending, session.poll(&io));
    io.registers[Fake.index(int_raw)] = done;
    try std.testing.expectEqual(Session.Poll.ready, session.poll(&io));
    try std.testing.expectEqual(@as(u32, 0), io.read(int_raw) & done);
    try std.testing.expect(session.stop(&io));
    try std.testing.expectEqual(@as(u32, 1), io.resets);
    try std.testing.expectEqualSlices(u32, &original, &io.registers);
}

test "active hardware, invalid divider and stale interrupts do not mutate" {
    var io: Fake = .{};
    var session: Session = .{};
    io.registers[Fake.index(clock_div)] = 0;
    try std.testing.expectError(error.InvalidDivider, session.prepare(&io));
    io.registers[Fake.index(clock_div)] = 164;
    try std.testing.expectError(error.InvalidDivider, session.prepare(&io));
    io.registers[Fake.index(clock_div)] = 4;
    io.registers[Fake.index(int_raw)] = done;
    try std.testing.expectError(error.Busy, session.prepare(&io));
    io.registers[Fake.index(int_raw)] = 0;
    io.registers[Fake.index(dma)] |= dma_enable;
    try std.testing.expectError(error.Busy, session.prepare(&io));
    try std.testing.expectEqual(@as(u32, 0), io.writes);
}

test "abort before completion resets FSM; lost ownership quarantines" {
    var io: Fake = .{};
    const original = io.registers;
    var session: Session = .{};
    try session.prepare(&io);
    try session.activate(&io);
    try std.testing.expect(session.stop(&io));
    try std.testing.expectEqualSlices(u32, &original, &io.registers);
    try session.prepare(&io);
    io.valid = false;
    const writes = io.writes;
    try std.testing.expect(!session.stop(&io));
    io.valid = true;
    try std.testing.expect(!session.stop(&io));
    try std.testing.expectEqual(writes, io.writes);
}

test "unready analog and revoked ownership never admit ADC completion" {
    var io: Fake = .{ .analog = false };
    var session: Session = .{};
    try session.prepare(&io);
    const writes = io.writes;
    try std.testing.expectError(error.Unavailable, session.activate(&io));
    try std.testing.expectEqual(writes, io.writes);
    io.analog = true;
    try session.activate(&io);
    io.registers[Fake.index(int_raw)] = done;
    try std.testing.expectEqual(Session.Poll.ready, session.poll(&io));
    io.valid = false;
    const at_loss = io.writes;
    try std.testing.expectEqual(Session.Poll.unavailable, session.poll(&io));
    io.valid = true;
    try std.testing.expect(!session.stop(&io));
    try std.testing.expectEqual(at_loss, io.writes);
}

test "restoration preserves unrelated fields changed while owned" {
    var io: Fake = .{};
    var session: Session = .{};
    try session.prepare(&io);
    try session.activate(&io);
    io.registers[Fake.index(ctrl)] ^= 1 << 31;
    io.registers[Fake.index(ctrl2)] ^= 1 << 5;
    io.registers[Fake.index(pattern)] ^= 1 << 31;
    const expected_ctrl = io.read(ctrl) & ~ctrl_mask;
    const expected_ctrl2 = io.read(ctrl2) & ~ctrl2_mask;
    const expected_pattern = io.read(pattern) & ~pattern_mask;
    try std.testing.expect(session.stop(&io));
    try std.testing.expectEqual(expected_ctrl, io.read(ctrl) & ~ctrl_mask);
    try std.testing.expectEqual(expected_ctrl2, io.read(ctrl2) & ~ctrl2_mask);
    try std.testing.expectEqual(expected_pattern, io.read(pattern) & ~pattern_mask);
}

test "unexpected ADC events quarantine without consuming them" {
    var io: Fake = .{};
    var session: Session = .{};
    io.registers[Fake.index(int_enable)] = 1 << 30;
    try std.testing.expectError(error.Busy, session.prepare(&io));
    io.registers[Fake.index(int_enable)] = 0;
    try session.prepare(&io);
    io.registers[Fake.index(int_raw)] = done;
    const writes = io.writes;
    try std.testing.expect(!session.stop(&io));
    try std.testing.expectEqual(writes, io.writes);
    try std.testing.expectEqual(done, io.read(int_raw));
}
