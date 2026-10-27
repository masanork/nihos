//! DQS phase/delay windows for AP hex PSRAM200, before cached mapping.
//! Pinned ESP-IDF v5.4.4 mspi_timing_by_dqs.c supplies the sweep policy.
const std = @import("std");
pub const Window = struct { start: u5, length: u6, midpoint: u5 };
pub fn longest(mask: u32, count: u6) ?Window {
    if (count == 0 or count > 32) return null;
    var best_start: u5 = 0;
    var best_length: u6 = 0;
    var run: u6 = 0;
    for (0..count) |index| {
        if (mask & (@as(u32, 1) << @intCast(index)) != 0) {
            run += 1;
            if (run > best_length) {
                best_start = @intCast(index + 1 - run);
                best_length = run;
            }
        } else run = 0;
    }
    if (best_length == 0) return null;
    return .{ .start = best_start, .length = best_length, .midpoint = @intCast(@as(u6, best_start) + (best_length - 1) / 2) };
}
pub const Report = struct { status: u32 = 2, stage: u32 = 0, phase_mask: u32 = 0, phase: u32 = 0, delay_mask: u32 = 0, delay: u32 = 0, repetitions: u32 = 100, reads: u32 = 0, writes: u32 = 0, error_code: u32 = 0 };
const reference = [_]u32{ 0x7f786655, 0xa5ff005a, 0x3f3c33aa, 0xa5ff5a00, 0x1f1e9955, 0xa5005aff, 0x0f0fccaa, 0xa55a00ff, 0x07876655, 0xffa55a00, 0x03c333aa, 0xff00a55a, 0x01e19955, 0xff005aa5, 0x00f0ccaa, 0xff5a00a5, 0x80786655, 0x00a5ff5a, 0xc03c33aa, 0x00a55aff, 0xe01e9355, 0x00ff5aa5, 0xf00fccaa, 0x005affa5, 0xf8876655, 0x5aa5ff00, 0xfcc333aa, 0x5affa500, 0xfee19955, 0x5a00a5ff, 0x11f0ccaa, 0x5a00ffa5 };
fn sample(controller: anytype, hardware: anytype, report: *Report, started: u64) !bool {
    var matched = true;
    for (reference, 0..) |expected, index| {
        if (hardware.now() - started > 15_000_000) return error.TuningDeadline;
        const actual = try controller.readWord(0x80 + @as(u32, @intCast(index)) * 4);
        report.reads += 1;
        matched = matched and actual == expected;
    }
    return matched;
}
pub fn tune(controller: anytype, hardware: anytype, report: *Report) !void {
    return tunePolicy(controller, hardware, report, false);
}

/// A failed delay candidate cannot re-enter the window. Retain 100 samples
/// for every accepted delay; skip only the remaining samples of failed taps.
pub fn tuneRejectEarly(controller: anytype, hardware: anytype, report: *Report) !void {
    return tunePolicy(controller, hardware, report, true);
}
fn tunePolicy(controller: anytype, hardware: anytype, report: *Report, comptime reject_early: bool) !void {
    const started = hardware.now();
    report.stage = 1;
    try hardware.clock(20); // MPLL400 /20, not a PLL source change while mapped.
    hardware.phase(0);
    hardware.delay(15); // zero data and DQS delay.
    for (reference, 0..) |value, index| {
        try controller.writeWord(0x80 + @as(u32, @intCast(index)) * 4, value);
        report.writes += 1;
    }
    if (!try sample(controller, hardware, report, started)) return error.ReferenceMismatch;
    report.stage = 2;
    try hardware.clock(2); //200 MHz, still command-only; no cached CPU loads.
    for (0..4) |phase| {
        hardware.phase(@intCast(phase));
        if (try sample(controller, hardware, report, started)) report.phase_mask |= @as(u32, 1) << @intCast(phase);
    }
    const phase_window = longest(report.phase_mask, 4) orelse return error.NoPhaseWindow;
    report.phase = phase_window.start; //same first-of-longest rule as the SDK.
    hardware.phase(@intCast(report.phase));
    report.stage = 3;
    for (0..31) |delay| {
        hardware.delay(@intCast(delay));
        var good = true;
        for (0..100) |_| {
            good = (try sample(controller, hardware, report, started)) and good;
            if (reject_early and !good) break;
        }
        if (good) report.delay_mask |= @as(u32, 1) << @intCast(delay);
    }
    const window = longest(report.delay_mask, 31) orelse return error.NoDelayWindow;
    if (window.length < 2) return error.NarrowDelayWindow;
    report.delay = window.midpoint;
    hardware.delay(@intCast(report.delay));
    report.stage = 4;
    if (!try sample(controller, hardware, report, started)) return error.FinalMismatch;
    report.status = 1;
}

test "tuning selects a genuine contiguous window and never falls back to an invalid point" {
    try std.testing.expect(longest(0, 4) == null);
    try std.testing.expectEqualDeep(Window{ .start = 1, .length = 2, .midpoint = 1 }, longest(0b0110, 4).?);
    try std.testing.expectEqualDeep(Window{ .start = 4, .length = 3, .midpoint = 5 }, longest(0b1110011, 7).?);
    try std.testing.expectEqualDeep(Window{ .start = 0, .length = 31, .midpoint = 15 }, longest(0x7fffffff, 31).?);
    try std.testing.expectEqualDeep(Window{ .start = 0, .length = 32, .midpoint = 15 }, longest(0xffffffff, 32).?);
    try std.testing.expect(longest(1, 0) == null);
}

const TuningModel = struct {
    seed: [32]u32 = @splat(0),
    phase_id: u2 = 0,
    delay_id: u5 = 15,
    divider: u32 = 20,
    phases: u4 = 0b0110,
    ticks: u64 = 0,
    tick_step: u64 = 1,
    late_failure: bool = false,
    delay16_reads: u32 = 0,
    pub fn now(self: *@This()) u64 {
        self.ticks += self.tick_step;
        return self.ticks;
    }
    pub fn clock(self: *@This(), divider: u32) !void {
        self.divider = divider;
    }
    pub fn phase(self: *@This(), value: u2) void {
        self.phase_id = value;
    }
    pub fn delay(self: *@This(), value: u5) void {
        self.delay_id = value;
    }
    pub fn writeWord(self: *@This(), address: u32, value: u32) !void {
        self.seed[(address - 0x80) / 4] = value;
    }
    pub fn readWord(self: *@This(), address: u32) !u32 {
        if (self.divider == 2 and self.phase_id == 1 and self.delay_id == 16) {
            self.delay16_reads += 1;
            if (self.late_failure and self.delay16_reads == 3200) return 1 ^ self.seed[(address - 0x80) / 4];
        }
        const good = self.divider == 20 or
            (self.phases & (@as(u4, 1) << self.phase_id) != 0 and self.delay_id >= 10 and self.delay_id <= 22);
        return self.seed[(address - 0x80) / 4] ^ (if (good) @as(u32, 0) else @as(u32, 1));
    }
};

test "full tuning uses all repeated samples before publishing a selected window" {
    var model = TuningModel{};
    var report = Report{};
    try tune(&model, &model, &report);
    try std.testing.expectEqual(@as(u32, 1), report.status);
    try std.testing.expectEqual(@as(u32, 4), report.stage);
    try std.testing.expectEqual(@as(u32, 6), report.phase_mask);
    try std.testing.expectEqual(@as(u32, 1), report.phase);
    try std.testing.expectEqual(@as(u32, 0x7ffc00), report.delay_mask);
    try std.testing.expectEqual(@as(u32, 16), report.delay);
    try std.testing.expectEqual(@as(u32, 99_392), report.reads);
    try std.testing.expectEqual(@as(u32, 32), report.writes);
}

test "no phase window or elapsed deadline prevents calibration success" {
    var missing = TuningModel{ .phases = 0 };
    var report = Report{};
    try std.testing.expectError(error.NoPhaseWindow, tune(&missing, &missing, &report));
    try std.testing.expectEqual(@as(u32, 2), report.status);
    var late = TuningModel{ .tick_step = 500_000 };
    var timed = Report{};
    try std.testing.expectError(error.TuningDeadline, tune(&late, &late, &timed));
    try std.testing.expectEqual(@as(u32, 2), timed.status);
}

test "early rejection preserves accepted 100-sample windows and final selection" {
    var model = TuningModel{};
    var report = Report{};
    try tuneRejectEarly(&model, &model, &report);
    try std.testing.expectEqual(@as(u32, 1), report.status);
    try std.testing.expectEqual(@as(u32, 100), report.repetitions);
    try std.testing.expectEqual(@as(u32, 0x7ffc00), report.delay_mask);
    try std.testing.expectEqual(@as(u32, 16), report.delay);
    // 6 setup/final samples, 13 valid taps x100, 18 invalid taps x1.
    try std.testing.expectEqual(@as(u32, (6 + 13 * 100 + 18) * 32), report.reads);
}

test "early rejection still detects a failure in the hundredth sample" {
    var model = TuningModel{ .late_failure = true };
    var report = Report{};
    try tuneRejectEarly(&model, &model, &report);
    try std.testing.expectEqual(@as(u32, 3200), model.delay16_reads);
    try std.testing.expectEqual(@as(u32, 0x7efc00), report.delay_mask);
    try std.testing.expectEqual(@as(u32, 12), report.delay);
}
