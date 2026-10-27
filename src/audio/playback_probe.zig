//! Finite playback lifecycle shared by native glue and host fault models.
const std = @import("std");
pub const Phase = enum(u32) { idle, prepare, settle, start, playing, drain, shutdown, done, failed };
pub const Fault = enum(u32) { none, codec, hardware, start, descriptor, timeout, clock, cleanup };
pub const Status = extern struct { dma: u32 = 0, bclk: u32 = 0, fifo: u32 = 0, eof_descriptor: u32 = 0, parked: u32 = 0 };
pub const Report = extern struct {
    phase: u32 = 0,
    fault: u32 = 0,
    dma: u32 = 0,
    bclk: u32 = 0,
    fifo: u32 = 0,
    eof_descriptor: u32 = 0,
    parked: u32 = 0,
    codec_off: u32 = 0,
    stopped: u32 = 0,
    returned: u32 = 0,
};
/// Output operations return errors, and clock.counter() is monotonic usec.
/// stop() must not release buffers without proven DMA quiescence.
pub fn Player(comptime Output: type) type {
    return struct {
        output: Output,
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
                self.abort(bus, .clock);
                return;
            };
            if (now < self.next) return;
            self.step(bus, clock, now) catch |err| {
                const fault: Fault = switch (@as(anyerror, err)) {
                    error.Hardware => .hardware,
                    error.Start => .start,
                    error.Descriptor => .descriptor,
                    error.Timeout => .timeout,
                    error.Clock => .clock,
                    else => .codec,
                };
                self.abort(bus, fault);
            };
            self.report.phase = @backingInt(self.phase);
        }
        fn abort(self: *@This(), bus: anytype, fault: Fault) void {
            self.report.fault = @backingInt(fault);
            self.cleanup(bus);
            self.phase = .failed;
            self.report.phase = @backingInt(self.phase);
        }
        fn cleanup(self: *@This(), bus: anytype) void {
            // Always try both; I2C failure cannot skip DMA stop, and DMA stop
            // failure cannot skip amplifier-off/mute attempts.
            var mute_ok = true;
            self.output.mute(bus) catch {
                mute_ok = false;
            };
            self.report.codec_off = @intFromBool(mute_ok and self.output.codecOff());
            var stop_ok = true;
            self.output.stop() catch {
                stop_ok = false;
            };
            self.report.stopped = @intFromBool(self.output.stopped());
            self.report.returned = @intFromBool(stop_ok and self.output.returned());
            if (self.report.fault == 0 and (self.report.codec_off == 0 or self.report.stopped == 0 or self.report.returned == 0)) self.report.fault = @backingInt(Fault.cleanup);
        }
        fn step(self: *@This(), bus: anytype, clock: anytype, now: u64) !void {
            switch (self.phase) {
                .prepare => {
                    try self.output.configure(bus);
                    try self.output.prepare();
                    const completed = clock.counter() orelse return error.Clock;
                    self.next = completed +| 150_000;
                    self.phase = .settle;
                },
                .settle => self.phase = .start,
                .start => {
                    try self.output.start();
                    try self.output.unmute(bus);
                    const completed = clock.counter() orelse return error.Clock;
                    self.deadline = completed +| 2_000_000;
                    self.phase = .playing;
                },
                .playing => {
                    const status = self.output.status();
                    self.report.dma = status.dma;
                    self.report.bclk = status.bclk;
                    self.report.fifo = status.fifo;
                    self.report.eof_descriptor = status.eof_descriptor;
                    self.report.parked = status.parked;
                    if (status.dma & 4 != 0) return error.Descriptor;
                    if (status.dma & 8 != 0) {
                        if (!self.output.endMatches(status.eof_descriptor) or status.bclk == 0) return error.Descriptor;
                        // DMA completion is not final audible output. Leave
                        // clocks running to drain the I2S FIFO before muting.
                        self.next = now +| 10_000;
                        self.phase = .drain;
                    } else if (now >= self.deadline) return error.Timeout;
                },
                .drain => self.phase = .shutdown,
                .shutdown => {
                    self.cleanup(bus);
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
    unmuted: bool = false,
    muted: bool = false,
    stop_called: bool = false,
    stop_failed: bool = false,
    mute_failed: bool = false,
    start_failed: bool = false,
    status_value: Status = .{},
    pub fn configure(self: *@This(), _: anytype) !void {
        self.configured = true;
    }
    pub fn prepare(self: *@This()) !void {
        try std.testing.expect(self.configured);
    }
    pub fn start(self: *@This()) !void {
        if (self.start_failed) return error.Start;
        self.running = true;
    }
    pub fn unmute(self: *@This(), _: anytype) !void {
        try std.testing.expect(self.running);
        self.unmuted = true;
    }
    pub fn mute(self: *@This(), _: anytype) !void {
        if (self.mute_failed) return error.Nack;
        self.muted = true;
    }
    pub fn stop(self: *@This()) !void {
        self.stop_called = true;
        if (self.stop_failed) return error.Busy;
        self.running = false;
    }
    pub fn codecOff(self: *@This()) bool {
        return self.muted;
    }
    pub fn stopped(self: *@This()) bool {
        return self.stop_called and !self.stop_failed;
    }
    pub fn returned(self: *@This()) bool {
        return self.stopped();
    }
    pub fn status(self: *@This()) Status {
        return self.status_value;
    }
    pub fn endMatches(_: *@This(), address: u32) bool {
        return address == 0x4ff101f0;
    }
};
const Clock = struct {
    now: ?u64,
    pub fn counter(self: @This()) ?u64 {
        return self.now;
    }
};
fn begin(player: *Player(Model)) !void {
    try std.testing.expect(player.request());
    player.poll({}, Clock{ .now = 0 });
    player.poll({}, Clock{ .now = 149_999 });
    try std.testing.expect(!player.output.running and !player.output.unmuted);
    player.poll({}, Clock{ .now = 150_000 });
    player.poll({}, Clock{ .now = 150_001 });
}
test "finite audio unmutes only after start and drains before confirmed shutdown" {
    var player = Player(Model){ .output = .{} };
    try begin(&player);
    try std.testing.expect(player.output.unmuted);
    player.output.status_value = .{ .dma = 8, .bclk = 260000, .eof_descriptor = 0x4ff101f0, .parked = 1 };
    player.poll({}, Clock{ .now = 700_000 });
    player.poll({}, Clock{ .now = 709_999 });
    try std.testing.expect(!player.output.stop_called);
    player.poll({}, Clock{ .now = 710_000 });
    player.poll({}, Clock{ .now = 710_001 });
    try std.testing.expectEqual(Phase.done, player.phase);
    try std.testing.expect(player.report.codec_off == 1 and player.report.stopped == 1 and player.report.returned == 1);
    try std.testing.expect(!player.request());
}
test "audio start failure, timeout, descriptor faults and dead clock always try cleanup" {
    for (0..4) |kind| {
        var player = Player(Model){ .output = .{ .start_failed = kind == 0 } };
        try begin(&player);
        if (kind != 0) {
            if (kind == 2) player.output.status_value.dma = 4;
            player.poll({}, Clock{ .now = if (kind == 3) null else 2_200_000 });
        }
        try std.testing.expectEqual(Phase.failed, player.phase);
        try std.testing.expect(player.output.muted and player.output.stop_called);
        if (kind == 0) try std.testing.expect(!player.output.unmuted);
    }
}
test "audio never reports returned buffers after failed DMA stop or confirmed amp-off after I2C failure" {
    var player = Player(Model){ .output = .{ .stop_failed = true, .mute_failed = true } };
    try begin(&player);
    player.poll({}, Clock{ .now = 2_200_000 });
    try std.testing.expectEqual(Phase.failed, player.phase);
    try std.testing.expect(player.output.stop_called);
    try std.testing.expectEqual(@as(u32, 0), player.report.returned);
    try std.testing.expectEqual(@as(u32, 0), player.report.codec_off);
}
