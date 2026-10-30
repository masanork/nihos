const std = @import("std");
const m = @import("csi_first_frame.zig");
test "sensor configuration survives only a completed clean capture" {
    var p: m.Probe = .{ .phase = .power_off, .completed = true };
    try std.testing.expect(p.canKeepSensor());
    p.cleanup_failed = true;
    try std.testing.expect(!p.canKeepSensor());
    p.cleanup_failed = false;
    for ([_]m.Result{ .timeout, .dma_error, .setup_failed, .cleanup_failed, .cancel_observed }) |result| {
        p.result = result;
        try std.testing.expect(!p.canKeepSensor());
    }
    p.result = .none;
    p.completed = false;
    try std.testing.expect(!p.canKeepSensor());
    p.completed = true;
    p.phase = .wait;
    try std.testing.expect(!p.canKeepSensor());
}
test "USB residue can reset once; watchdog residue fails closed" {
    for ([_]u32{ 1, 3, 16, 22, 23 }) |reason| try std.testing.expectEqual(m.BootAction.proceed, m.bootAction(0, reason));
    try std.testing.expectEqual(m.BootAction.full_reset, m.bootAction(7, 23));
    try std.testing.expectEqual(m.BootAction.full_reset, m.bootAction(7, 22));
    for ([_]u32{ 0, 1, 3, 7, 9, 16, 18 }) |reason| try std.testing.expectEqual(m.BootAction.failed, m.bootAction(7, reason));
}
const Hardware = struct {
    fail: u8 = 0,
    cleanup_fail: u8 = 0,
    pending: u8 = 0,
    stop_pending: u8 = 0,
    cancel_fail: bool = false,
    event: m.Events = .{},
    pinned: bool = false,
    calls: [32]u8 = @splat(0),
    count: usize = 0,
    fn call(self: *Hardware, n: u8) bool {
        self.calls[self.count] = n;
        self.count += 1;
        return self.fail != n and self.cleanup_fail != n;
    }
    pub fn prepareSensor(self: *Hardware) m.Step {
        if (self.pending > 0) {
            self.pending -= 1;
            return .pending;
        }
        return if (self.call(1)) .done else .failed;
    }
    pub fn prepareFrame(self: *Hardware) m.Step {
        return if (self.call(2)) .done else .failed;
    }
    pub fn prepareCsi(self: *Hardware) bool {
        return self.call(3);
    }
    pub fn prepareIsp(self: *Hardware) bool {
        return self.call(12);
    }
    pub fn configureDma(self: *Hardware) bool {
        return self.call(4);
    }
    pub fn armDma(self: *Hardware) bool {
        return self.call(5);
    }
    pub fn bridgeOn(self: *Hardware) bool {
        return self.call(6);
    }
    pub fn sensorOn(self: *Hardware) bool {
        return self.call(7);
    }
    pub fn events(self: *Hardware) m.Events {
        return self.event;
    }
    pub fn cancelStart(self: *Hardware) m.Step {
        return if (self.cancel_fail) .failed else .done;
    }
    pub fn cancelPoll(self: *Hardware) m.Step {
        return if (self.cancel_fail) .failed else .done;
    }
    pub fn sensorOff(self: *Hardware) bool {
        return self.call(8);
    }
    pub fn dmaStop(self: *Hardware) m.Step {
        if (self.stop_pending > 0) {
            self.stop_pending -= 1;
            return .pending;
        }
        return if (self.call(9)) .done else .failed;
    }
    pub fn ispStop(self: *Hardware) bool {
        return self.call(13);
    }
    pub fn csiStop(self: *Hardware) bool {
        return self.call(10);
    }
    pub fn powerOff(self: *Hardware) m.Step {
        return if (self.call(11)) .done else .failed;
    }
    pub fn pin(self: *Hardware) void {
        self.pinned = true;
    }
};
fn until(p: *m.Probe, h: *Hardware, phase: m.Phase) void {
    for (0..30) |_| {
        if (p.phase == phase) return;
        p.poll(h, 1);
    }
}
test "completion requires ordered cleanup and always retains the frame" {
    var h: Hardware = .{};
    var p: m.Probe = .{};
    try std.testing.expect(p.start(0, 100));
    until(&p, &h, .wait);
    try std.testing.expectEqual(m.Phase.wait, p.phase);
    h.event.done = true;
    until(&p, &h, .done);
    try std.testing.expectEqual(m.Result.dma_complete, p.result);
    try std.testing.expect(h.pinned);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 12, 4, 5, 6, 7, 8, 9, 13, 10, 11 }, h.calls[0..h.count]);
}
test "every setup and cleanup failure still attempts all cleanup" {
    for (1..14) |n| {
        var h: Hardware = .{ .fail = @intCast(n) };
        var p: m.Probe = .{};
        try std.testing.expect(p.start(0, 100));
        for (0..30) |_| {
            if (p.phase == .wait) h.event.done = true;
            p.poll(&h, 1);
            if (p.phase == .done or p.phase == .pinned) break;
        }
        try std.testing.expect(h.pinned);
        try std.testing.expectEqualSlices(u8, &.{ 8, 9, 13, 10, 11 }, h.calls[h.count - 5 .. h.count]);
        try std.testing.expect(p.result != .dma_complete);
        try std.testing.expectEqual(if ((n >= 8 and n <= 11) or n == 13) m.Phase.pinned else m.Phase.done, p.phase);
    }
}
test "late error dominates completion; timeout while preparing cleans up" {
    var h: Hardware = .{};
    var p: m.Probe = .{};
    try std.testing.expect(p.start(0, 100));
    until(&p, &h, .wait);
    h.event.done = true;
    p.poll(&h, 1);
    h.event.error_detected = true;
    until(&p, &h, .done);
    try std.testing.expectEqual(m.Result.dma_error, p.result);
    h = .{ .pending = 20 };
    p = .{};
    try std.testing.expect(p.start(0, 2));
    p.poll(&h, 1);
    p.poll(&h, 2);
    until(&p, &h, .done);
    try std.testing.expectEqual(m.Result.timeout, p.result);
    try std.testing.expect(h.pinned);
}

test "pending DMA observation blocks downstream cleanup" {
    var h: Hardware = .{ .stop_pending = 2 };
    var p: m.Probe = .{};
    try std.testing.expect(p.start(0, 100));
    until(&p, &h, .wait);
    h.event.done = true;
    until(&p, &h, .dma_stop);
    p.poll(&h, 1);
    try std.testing.expectEqual(m.Phase.dma_stop, p.phase);
    try std.testing.expect(!h.pinned);
    p.poll(&h, 1);
    try std.testing.expectEqual(m.Phase.dma_stop, p.phase);
    until(&p, &h, .done);
    try std.testing.expect(h.pinned);
    try std.testing.expectEqual(m.Result.dma_complete, p.result);
}

test "stop observation bounds a broken or reversed clock" {
    var w: m.StopWindow = .{};
    try std.testing.expect(!w.start(null, 50));
    try std.testing.expect(!w.start(std.math.maxInt(u64), 50));
    try std.testing.expect(w.start(100, 50));
    try std.testing.expectEqual(m.Step.pending, w.observe(100));
    try std.testing.expectEqual(m.Step.failed, w.observe(99));
    w = .{};
    try std.testing.expect(w.start(100, 50));
    for (0..1023) |_| try std.testing.expectEqual(m.Step.pending, w.observe(100));
    try std.testing.expectEqual(m.Step.failed, w.observe(100));
    w = .{};
    try std.testing.expect(w.start(100, 50));
    try std.testing.expectEqual(m.Step.pending, w.observe(150));
    try std.testing.expectEqual(m.Step.done, w.observe(150));
    w = .{};
    try std.testing.expect(w.start(100, 50));
    try std.testing.expectEqual(m.Step.failed, w.observe(null));
}

test "DAR progress filter rejects boundary, disable, and completion races" {
    const base: m.ProgressSnapshot = .{ .base = 100, .length = 10, .address = 105, .enabled_before = true, .enabled_after = true, .status_before = 0, .status_after = 0 };
    try std.testing.expectEqual(@as(?u32, 5), base.offset());
    var s = base;
    s.address = 99;
    try std.testing.expectEqual(@as(?u32, null), s.offset());
    s.address = 100;
    try std.testing.expectEqual(@as(?u32, null), s.offset());
    s.address = 110;
    try std.testing.expectEqual(@as(?u32, null), s.offset());
    s = base;
    s.enabled_before = false;
    try std.testing.expectEqual(@as(?u32, null), s.offset());
    s = base;
    s.enabled_after = false;
    try std.testing.expectEqual(@as(?u32, null), s.offset());
    s = base;
    s.status_before = 2;
    try std.testing.expectEqual(@as(?u32, null), s.offset());
    s = base;
    s.status_after = 0x20;
    try std.testing.expectEqual(@as(?u32, null), s.offset());
}

test "inflight cancellation has distinct result and failure pins" {
    var h: Hardware = .{};
    var p: m.Probe = .{ .cancel_mode = true };
    try std.testing.expect(p.start(0, 100));
    until(&p, &h, .done);
    try std.testing.expectEqual(m.Result.cancel_observed, p.result);
    try std.testing.expect(h.pinned);
    h = .{ .cancel_fail = true };
    p = .{ .cancel_mode = true };
    try std.testing.expect(p.start(0, 100));
    until(&p, &h, .pinned);
    try std.testing.expectEqual(m.Result.cleanup_failed, p.result);
    try std.testing.expect(h.pinned);
}
