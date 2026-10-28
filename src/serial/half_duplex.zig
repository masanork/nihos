//! Finite, CPU-owned half-duplex UART transaction. No allocation, IRQ or DMA.
const std = @import("std");
pub const limit = 64;
pub const budget = 8;
pub const Phase = enum(u32) { idle, prepare, enable_wait, sending, draining, receiving, shutdown, done, failed };
pub const Fault = enum(u32) { none, clock, hardware, uart, timeout, overflow, mismatch, cleanup };
pub const Report = extern struct { phase: u32 = 0, fault: u32 = 0, tx: u32 = 0, rx: u32 = 0, raw: u32 = 0, tx_idle: u32 = 0, dir_low: u32 = 0, stopped: u32 = 0, matched: u32 = 0 };
pub fn Exchange(comptime Hardware: type) type {
    return struct {
        hardware: Hardware,
        phase: Phase = .idle,
        report: Report = .{},
        transmit: [limit]u8 = @splat(0),
        receive: [limit]u8 = @splat(0),
        expected: [limit]u8 = @splat(0),
        tx_len: usize = 0,
        rx_len: usize = 0,
        next: u64 = 0,
        deadline: u64 = 0,
        pub fn request(self: *@This(), data: []const u8, reply: []const u8) error{ Busy, InvalidLength }!void {
            if (self.phase != .idle) return error.Busy;
            if (data.len == 0 or data.len > limit or reply.len == 0 or reply.len > limit) return error.InvalidLength;
            @memcpy(self.transmit[0..data.len], data);
            @memcpy(self.expected[0..reply.len], reply);
            self.tx_len = data.len;
            self.rx_len = reply.len;
            self.phase = .prepare;
        }
        pub fn poll(self: *@This(), clock: anytype) void {
            if (self.phase == .idle or self.phase == .done or self.phase == .failed) return;
            const now = clock.counter() orelse {
                self.abort(.clock);
                return;
            };
            if (self.phase != .prepare and now >= self.deadline) {
                self.abort(.timeout);
                return;
            }
            self.step(clock, now) catch |err| {
                const fault: Fault = switch (@as(anyerror, err)) {
                    error.Uart => .uart,
                    error.Overflow => .overflow,
                    error.Mismatch => .mismatch,
                    error.Clock => .clock,
                    else => .hardware,
                };
                self.abort(fault);
                return;
            };
            self.report.phase = @backingInt(self.phase);
        }
        fn cleanup(self: *@This()) void {
            // A failed direction write cannot skip disabling/resetting our UART.
            var direction_ok = true;
            self.hardware.direction(false) catch {
                direction_ok = false;
            };
            var stopped = true;
            self.hardware.close() catch {
                stopped = false;
            };
            self.report.dir_low = @intFromBool(self.hardware.directionLow());
            self.report.stopped = @intFromBool(stopped and self.hardware.closed());
            if (self.report.fault == 0 and (!direction_ok or self.report.dir_low == 0 or self.report.stopped == 0)) self.report.fault = @backingInt(Fault.cleanup);
        }
        fn abort(self: *@This(), fault: Fault) void {
            self.report.fault = @backingInt(fault);
            self.cleanup();
            self.phase = .failed;
            self.report.phase = @backingInt(self.phase);
        }
        fn step(self: *@This(), clock: anytype, now: u64) !void {
            if (self.phase == .prepare) {
                try self.hardware.open();
                try self.hardware.direction(true);
                const completed = clock.counter() orelse return error.Clock;
                self.next = completed +| 2;
                self.deadline = completed +| 1_000_000;
                self.phase = .enable_wait;
                return;
            }
            self.report.raw = self.hardware.errors();
            if (self.report.raw != 0) return error.Uart;
            switch (self.phase) {
                .enable_wait => {
                    if (now >= self.next) self.phase = .sending;
                },
                .sending => {
                    for (0..budget) |_| {
                        if (self.report.tx == self.tx_len or !self.hardware.writable()) break;
                        try self.hardware.write(self.transmit[self.report.tx]);
                        self.report.tx += 1;
                    }
                    if (self.report.tx == self.tx_len) self.phase = .draining;
                },
                .draining => {
                    // FIFO empty is insufficient: the final stop bit must leave
                    // the shift register before deasserting the transceiver DE.
                    if (!self.hardware.txIdle()) return;
                    self.report.tx_idle = 1;
                    try self.hardware.direction(false);
                    self.phase = .receiving;
                },
                .receiving => {
                    for (0..budget) |_| {
                        if (!self.hardware.readable()) break;
                        if (self.report.rx == self.rx_len) return error.Overflow;
                        self.receive[self.report.rx] = try self.hardware.read();
                        self.report.rx += 1;
                    }
                    if (self.report.rx == self.rx_len) {
                        if (self.hardware.readable()) return error.Overflow;
                        if (!std.mem.eql(u8, self.receive[0..self.rx_len], self.expected[0..self.rx_len])) return error.Mismatch;
                        self.report.matched = 1;
                        self.phase = .shutdown;
                    }
                },
                .shutdown => {
                    self.cleanup();
                    self.phase = if (self.report.fault == 0) .done else .failed;
                },
                .idle, .prepare, .done, .failed => unreachable,
            }
        }
    };
}
pub fn crc16(data: []const u8) u16 {
    var value: u16 = 0xffff;
    for (data) |byte| {
        value ^= @as(u16, byte) << 8;
        for (0..8) |_| value = (value << 1) ^ (if (value & 0x8000 != 0) @as(u16, 0x1021) else 0);
    }
    return value;
}
/// Peer response deliberately differs from a local echo. Fixed test protocol,
/// not a fieldbus/Modbus command or authentication mechanism.
pub fn frame(response: bool) [limit]u8 {
    var data: [limit]u8 = undefined;
    @memcpy(data[0..8], "NIHOS485");
    data[8] = if (response) 2 else 1;
    data[9] = 1;
    for (10..limit - 2) |index| data[index] = @as(u8, @intCast(index * 37 % 256)) ^ (if (response) @as(u8, 0xa5) else 0);
    const checksum = crc16(data[0 .. limit - 2]);
    std.mem.writeInt(u16, data[limit - 2 ..][0..2], checksum, .big);
    return data;
}
const Model = struct {
    is_open: bool = false,
    tx_enabled: bool = false,
    shift_idle: bool = true,
    fail_close: bool = false,
    fail_direction_off: bool = false,
    line_errors: u32 = 0,
    input: [limit + 1]u8 = @splat(0),
    input_len: usize = 0,
    position: usize = 0,
    output: [limit]u8 = @splat(0),
    output_len: usize = 0,
    pub fn open(self: *@This()) !void {
        if (self.is_open) return error.Busy;
        self.is_open = true;
    }
    pub fn direction(self: *@This(), tx: bool) !void {
        if (!tx and self.fail_direction_off) return error.Hardware;
        self.tx_enabled = tx;
    }
    pub fn errors(self: *@This()) u32 {
        return self.line_errors;
    }
    pub fn writable(_: *@This()) bool {
        return true;
    }
    pub fn write(self: *@This(), byte: u8) !void {
        try std.testing.expect(self.tx_enabled);
        self.output[self.output_len] = byte;
        self.output_len += 1;
    }
    pub fn txIdle(self: *@This()) bool {
        return self.shift_idle;
    }
    pub fn readable(self: *@This()) bool {
        return !self.tx_enabled and self.position < self.input_len;
    }
    pub fn read(self: *@This()) !u8 {
        const byte = self.input[self.position];
        self.position += 1;
        return byte;
    }
    pub fn close(self: *@This()) !void {
        self.tx_enabled = false;
        if (self.fail_close) return error.Hardware;
        self.is_open = false;
    }
    pub fn directionLow(self: *@This()) bool {
        return !self.tx_enabled;
    }
    pub fn closed(self: *@This()) bool {
        return !self.is_open;
    }
};
const Clock = struct {
    now: ?u64,
    pub fn counter(self: @This()) ?u64 {
        return self.now;
    }
};
fn ready(value: *Exchange(Model)) !void {
    const request = frame(false);
    const reply = frame(true);
    @memcpy(value.hardware.input[0..limit], &reply);
    value.hardware.input_len = limit;
    try value.request(&request, &reply);
    value.poll(Clock{ .now = 0 });
    value.poll(Clock{ .now = 1 });
    try std.testing.expectEqual(Phase.enable_wait, value.phase);
    value.poll(Clock{ .now = 2 });
    for (0..limit / budget) |_| value.poll(Clock{ .now = 3 });
}
test "half duplex retains DE until FIFO and shift register are idle, then bounded receive and close" {
    var value = Exchange(Model){ .hardware = .{ .shift_idle = false } };
    try ready(&value);
    try std.testing.expectEqual(Phase.draining, value.phase);
    value.poll(Clock{ .now = 100 });
    try std.testing.expect(value.hardware.tx_enabled and value.report.tx_idle == 0);
    value.hardware.shift_idle = true;
    value.poll(Clock{ .now = 101 });
    try std.testing.expect(!value.hardware.tx_enabled and value.report.tx_idle == 1);
    for (0..limit / budget + 1) |_| value.poll(Clock{ .now = 102 });
    try std.testing.expectEqual(Phase.done, value.phase);
    try std.testing.expect(value.report.stopped == 1 and value.report.matched == 1);
    const expected = frame(false);
    try std.testing.expectEqualSlices(u8, &expected, &value.hardware.output);
    try std.testing.expectError(error.Busy, value.request("x", "x"));
}
test "half duplex clock loss, timeout and UART errors force direction-low and close" {
    for (0..3) |kind| {
        var value = Exchange(Model){ .hardware = .{ .shift_idle = false } };
        try ready(&value);
        if (kind == 2) value.hardware.line_errors = 0x10;
        value.poll(Clock{ .now = if (kind == 0) null else if (kind == 1) 1_000_000 else 100 });
        try std.testing.expectEqual(Phase.failed, value.phase);
        try std.testing.expect(value.report.stopped == 1 and value.report.dir_low == 1);
        try std.testing.expectEqual(@as(u32, 0), value.report.matched);
    }
}
test "half duplex rejects extra reply bytes and local echoes as peer responses" {
    for (0..2) |kind| {
        var value = Exchange(Model){ .hardware = .{} };
        try ready(&value);
        if (kind == 0) value.hardware.input_len += 1 else {
            const echo = frame(false);
            @memcpy(value.hardware.input[0..limit], &echo);
        }
        for (0..limit / budget + 2) |_| value.poll(Clock{ .now = 100 });
        try std.testing.expectEqual(Phase.failed, value.phase);
        try std.testing.expectEqual(@as(u32, 0), value.report.matched);
    }
}
test "half duplex independent cleanup and invalid admission never claim ownership release" {
    var value = Exchange(Model){ .hardware = .{ .fail_close = true, .fail_direction_off = true } };
    try std.testing.expectError(error.InvalidLength, value.request("", "x"));
    try std.testing.expect(!value.hardware.is_open);
    try ready(&value);
    value.poll(Clock{ .now = 1_000_000 });
    try std.testing.expectEqual(Phase.failed, value.phase);
    try std.testing.expect(value.report.dir_low == 1 and value.report.stopped == 0);
}
test "RS485 diagnostic CRC matches standard CCITT-FALSE vector and response differs" {
    try std.testing.expectEqual(@as(u16, 0x29b1), crc16("123456789"));
    const request = frame(false);
    const response = frame(true);
    try std.testing.expect(!std.mem.eql(u8, &request, &response));
    try std.testing.expectEqual(crc16(request[0 .. limit - 2]), std.mem.readInt(u16, request[limit - 2 ..][0..2], .big));
}
