//! Finite four-slot capture: DMA ownership precedes sample analysis or clearing.
const std = @import("std");
pub const bytes = 1024;
pub const frames = bytes / 8;
pub const Descriptor = extern struct { control: u32, buffer: u32, next: u32 = 0, padding: u32 = 0 };
pub fn descriptor(base: u32, buffer: u32) error{InvalidMemory}!Descriptor {
    if (base % 64 != 0 or buffer % 64 != 0 or base < 0x4ff00000 or buffer < 0x4ff00000 or
        @as(u64, base) + 64 > 0x4ff28000 or @as(u64, buffer) + bytes > 0x4ff28000 or
        (base < buffer + bytes and buffer < base + 64)) return error.InvalidMemory;
    return .{ .control = (1 << 31) | bytes, .buffer = buffer };
}
pub fn validate(value: Descriptor, expected_buffer: u32) error{ Ownership, Length, Descriptor }!void {
    if (value.control & (1 << 31) != 0) return error.Ownership;
    if ((value.control >> 12) & 0xfff != bytes) return error.Length;
    if (value.control & (1 << 30) == 0 or value.control & 0xfff != bytes or value.buffer != expected_buffer or value.next != 0) return error.Descriptor;
}
pub const Statistics = struct { peak: [4]u32 = @splat(0), span: [4]u32 = @splat(0), clipped: u32 = 0, active: u32 = 0 };
pub fn analyze(data: *const [bytes]u8) Statistics {
    var result: Statistics = .{};
    var low: [4]i32 = @splat(32767);
    var high: [4]i32 = @splat(-32768);
    for (0..bytes / 2) |index| {
        const value: i32 = std.mem.readInt(i16, data[index * 2 ..][0..2], .little);
        const slot = index % 4;
        low[slot] = @min(low[slot], value);
        high[slot] = @max(high[slot], value);
        result.peak[slot] = @max(result.peak[slot], @abs(value));
        if (value == -32768 or value == 32767) result.clipped += 1;
    }
    for (0..4) |slot| {
        result.span[slot] = @intCast(high[slot] - low[slot]);
        if (result.span[slot] != 0) result.active |= @as(u32, 1) << @intCast(slot);
    }
    return result;
}
pub const Status = extern struct { dma: u32 = 0, end: u32 = 0, parked: u32 = 0 };
pub const Phase = enum(u32) { idle, prepare, settle, capture, shutdown, done, failed };
pub const Report = extern struct { phase: u32 = 0, fault: u32 = 0, dma: u32 = 0, end: u32 = 0, parked: u32 = 0, codec_off: u32 = 0, stopped: u32 = 0, returned: u32 = 0, samples: u32 = 0, erased: u32 = 0 };
pub fn Player(comptime Input: type) type {
    return struct {
        input: Input,
        phase: Phase = .idle,
        report: Report = .{},
        next: u64 = 0,
        deadline: u64 = 0,
        pub fn request(self: *@This()) bool {
            if (self.phase != .idle) return false;
            self.phase = .prepare;
            return true;
        }
        pub fn poll(self: *@This(), bus: anytype, clock: anytype) void {
            if (self.phase == .idle or self.phase == .done or self.phase == .failed) return;
            const now = clock.counter() orelse {
                self.abort(bus, 1);
                return;
            };
            if (now < self.next) return;
            self.step(bus, clock, now) catch {
                self.abort(bus, 2);
                return;
            };
            self.report.phase = @backingInt(self.phase);
        }
        fn abort(self: *@This(), bus: anytype, fault: u32) void {
            self.report.fault = fault;
            self.finish(bus);
            self.phase = .failed;
            self.report.phase = @backingInt(self.phase);
        }
        fn finish(self: *@This(), bus: anytype) void {
            self.input.shutdown(bus) catch {
                self.report.fault = 3;
            };
            self.report.codec_off = @intFromBool(self.input.codecOff());
            var returned = true;
            self.input.stop() catch {
                returned = false;
                self.report.fault = 4;
            };
            self.report.stopped = @intFromBool(self.input.stopped());
            self.report.returned = @intFromBool(returned and self.input.returned());
            if (self.report.codec_off == 0 or self.report.stopped == 0 or self.report.returned == 0) {
                if (self.report.fault == 0) self.report.fault = 7;
            }
            // No reads or writes to DMA storage after failed stop/cache/ownership.
            if (self.report.returned == 1) {
                if (self.report.fault == 0) self.input.analyze() catch {
                    self.report.fault = 5;
                };
                self.input.erase() catch {
                    self.report.fault = 6;
                    return;
                };
                self.report.erased = 1;
                if (self.report.fault == 0) self.report.samples = bytes / 2;
            }
        }
        fn step(self: *@This(), bus: anytype, clock: anytype, now: u64) !void {
            switch (self.phase) {
                .prepare => {
                    try self.input.configure(bus);
                    try self.input.prepare();
                    self.next = (clock.counter() orelse return error.Clock) +| 250_000;
                    self.phase = .settle;
                },
                .settle => {
                    try self.input.unmute(bus);
                    try self.input.start();
                    self.deadline = (clock.counter() orelse return error.Clock) +| 1_000_000;
                    self.phase = .capture;
                },
                .capture => {
                    const value = self.input.status();
                    self.report.dma = value.dma;
                    self.report.end = value.end;
                    self.report.parked = value.parked;
                    if (value.dma & 0x7c != 0) return error.Dma;
                    if (value.dma & 2 != 0) {
                        if (!self.input.endMatches(value.end)) return error.Descriptor;
                        self.phase = .shutdown;
                    } else if (now >= self.deadline) return error.Timeout;
                },
                .shutdown => {
                    self.finish(bus);
                    self.phase = if (self.report.fault == 0) .done else .failed;
                },
                .idle, .done, .failed => unreachable,
            }
        }
    };
}
const Model = struct {
    configured: bool = false,
    running: bool = false,
    quiet: bool = false,
    stopped_ok: bool = false,
    fail_stop: bool = false,
    fail_mute: bool = false,
    analyzed: bool = false,
    erased: bool = false,
    status_value: Status = .{},
    pub fn configure(self: *@This(), _: anytype) !void {
        self.configured = true;
    }
    pub fn prepare(_: *@This()) !void {}
    pub fn unmute(_: *@This(), _: anytype) !void {}
    pub fn start(self: *@This()) !void {
        self.running = true;
    }
    pub fn status(self: *@This()) Status {
        return self.status_value;
    }
    pub fn endMatches(_: *@This(), address: u32) bool {
        return address == 0x4ff10000;
    }
    pub fn shutdown(self: *@This(), _: anytype) !void {
        if (self.fail_mute) return error.Nack;
        self.quiet = true;
    }
    pub fn stop(self: *@This()) !void {
        if (self.fail_stop) return error.Busy;
        self.stopped_ok = true;
    }
    pub fn codecOff(self: *@This()) bool {
        return self.quiet;
    }
    pub fn stopped(self: *@This()) bool {
        return self.stopped_ok;
    }
    pub fn returned(self: *@This()) bool {
        return self.stopped_ok;
    }
    pub fn analyze(self: *@This()) !void {
        try std.testing.expect(self.stopped_ok);
        self.analyzed = true;
    }
    pub fn erase(self: *@This()) !void {
        self.erased = true;
    }
};
const Clock = struct {
    now: ?u64,
    pub fn counter(self: @This()) ?u64 {
        return self.now;
    }
};
test "capture requires stopped DMA and returned descriptor with exact length and EOF" {
    var value = try descriptor(0x4ff10000, 0x4ff11000);
    try std.testing.expectError(error.Ownership, validate(value, 0x4ff11000));
    value.control = (1 << 30) | (bytes << 12) | bytes;
    try validate(value, 0x4ff11000);
    value.control -= 1 << 12;
    try std.testing.expectError(error.Length, validate(value, 0x4ff11000));
    for ([_][2]u32{ .{ 0x4ff10000, 0x4ff10000 }, .{ 0x4ff10000, 0x48000000 }, .{ 0x4ff10000, 0x4ff27fc0 } }) |pair| try std.testing.expectError(error.InvalidMemory, descriptor(pair[0], pair[1]));
}
test "capture statistics distinguish silence, DC, signed extrema and interleaved slots" {
    var data: [bytes]u8 = @splat(0);
    try std.testing.expectEqual(@as(u32, 0), analyze(&data).active);
    for (0..bytes / 2) |i| std.mem.writeInt(i16, data[i * 2 ..][0..2], if (i % 4 == 0) -32768 else 42, .little);
    try std.testing.expectEqual(@as(u32, 0), analyze(&data).active);
    std.mem.writeInt(i16, data[0..2], 32767, .little);
    const result = analyze(&data);
    try std.testing.expectEqual(@as(u32, 1), result.active);
    try std.testing.expectEqual(@as(u32, 65535), result.span[0]);
    try std.testing.expectEqual(@as(u32, 32768), result.peak[0]);
}
test "finite capture waits for ADC settling and never analyzes or erases live DMA" {
    for (0..4) |kind| {
        var player = Player(Model){ .input = .{ .fail_stop = kind == 1, .fail_mute = kind == 2 } };
        try std.testing.expect(player.request());
        player.poll({}, Clock{ .now = 0 });
        player.poll({}, Clock{ .now = 249_999 });
        try std.testing.expect(!player.input.running);
        player.poll({}, Clock{ .now = 250_000 });
        player.input.status_value = .{ .dma = 3, .end = 0x4ff10000, .parked = 1 };
        player.poll({}, Clock{ .now = if (kind == 3) null else 260_000 });
        player.poll({}, Clock{ .now = 270_000 });
        try std.testing.expectEqual(kind == 0, player.phase == .done);
        try std.testing.expectEqual(kind != 1, player.input.erased);
        try std.testing.expectEqual(kind == 0, player.input.analyzed);
        try std.testing.expect(!player.request());
    }
}
test "capture timeout, bad final descriptor and DMA error clean up without sample analysis" {
    for (0..3) |kind| {
        var player = Player(Model){ .input = .{} };
        _ = player.request();
        player.poll({}, Clock{ .now = 0 });
        player.poll({}, Clock{ .now = 250_000 });
        player.input.status_value = .{ .dma = if (kind == 0) 0 else if (kind == 1) 3 else 8, .end = 0 };
        player.poll({}, Clock{ .now = 1_250_000 });
        try std.testing.expectEqual(Phase.failed, player.phase);
        try std.testing.expect(player.input.quiet and player.input.stopped_ok and player.input.erased);
        try std.testing.expect(!player.input.analyzed);
    }
}
