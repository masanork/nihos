//! One-shot, never-reused CSI diagnostic. Hardware is injected by CPU0 owner.
//! DONE indicates DMA completion only; it is not evidence of optical content.
const std = @import("std");
pub const Step = enum { pending, done, failed };
pub const Phase = enum(u32) { idle, sensor_prepare, frame_prepare, csi_prepare, dma_configure, dma_arm, bridge_on, sensor_on, wait, sensor_off, dma_stop, csi_stop, power_off, done, pinned, isp_prepare, isp_stop, cancel_wait };
pub const Result = enum(u32) { none, dma_complete, setup_failed, timeout, dma_error, cleanup_failed, cancel_observed };
pub const Events = struct { done: bool = false, error_detected: bool = false };
pub const BootAction = enum { proceed, full_reset, failed };
/// Only USB resets may retry via a full-chip reset. A failed watchdog reset
/// must stop rather than enter a firmware-generated reset loop.
pub fn bootAction(flags: u32, reason: u32) BootAction {
    if (flags == 0) return .proceed;
    return if (reason == 22 or reason == 23) .full_reset else .failed;
}
/// A bracketed DAR sample is a candidate only. Reads are not atomic and this
/// does not prove that a write reached memory or that DMA is still active.
pub const ProgressSnapshot = struct {
    base: u32,
    length: u32,
    address: u32,
    enabled_before: bool,
    enabled_after: bool,
    status_before: u32,
    status_after: u32,
    pub fn offset(self: ProgressSnapshot) ?u32 {
        if (!self.enabled_before or !self.enabled_after or
            (self.status_before | self.status_after) & 0x07ffffe2 != 0 or
            self.address < self.base) return null;
        const delta = self.address - self.base;
        if (delta == 0 or delta >= self.length) return null;
        return delta;
    }
};
/// Bounds the observation in owner polls even if the hardware clock stalls.
/// Failing this policy does not release any DMA resource.
pub const StopWindow = struct {
    deadline: u64 = 0,
    last: u64 = 0,
    samples: u32 = 0,
    started: bool = false,
    pub fn start(self: *StopWindow, now: ?u64, duration: u64) bool {
        if (self.started or now == null or duration == 0) return false;
        self.deadline = std.math.add(u64, now.?, duration) catch return false;
        self.last = now.?;
        self.started = true;
        return true;
    }
    pub fn observe(self: *StopWindow, now: ?u64) Step {
        if (!self.started or now == null or now.? < self.last) return .failed;
        self.last = now.?;
        self.samples += 1;
        if (now.? >= self.deadline and self.samples >= 2) return .done;
        if (self.samples >= 1024) return .failed;
        return .pending;
    }
};
pub const Probe = struct {
    phase: Phase = .idle,
    result: Result = .none,
    deadline: u64 = 0,
    wait_deadline: u64 = 0,
    dma_touched: bool = false,
    completed: bool = false,
    cancel_mode: bool = false,
    cleanup_failed: bool = false,
    failed_phase: Phase = .idle,
    pub fn start(self: *Probe, now: u64, timeout_us: u64) bool {
        if (self.phase != .idle or timeout_us == 0) return false;
        self.deadline = std.math.add(u64, now, timeout_us) catch return false;
        self.phase = .sensor_prepare;
        return true;
    }
    fn fail(self: *Probe, result: Result) void {
        self.failed_phase = self.phase;
        self.result = result;
        self.phase = .sensor_off;
    }
    pub fn poll(self: *Probe, h: anytype, now: ?u64) void {
        if (self.dma_touched and self.phase != .done and self.phase != .pinned and self.phase != .cancel_wait) {
            const e = h.events();
            if (e.error_detected) {
                if (self.failed_phase == .idle) self.failed_phase = self.phase;
                self.completed = false;
                self.result = .dma_error;
                switch (self.phase) {
                    .sensor_off, .dma_stop, .isp_stop, .csi_stop, .power_off => {},
                    else => self.phase = .sensor_off,
                }
            } else if (e.done and self.phase == .wait) {
                self.completed = true;
                self.phase = .sensor_off;
            } else if (e.done and (self.phase == .dma_arm or self.phase == .bridge_on or self.phase == .sensor_on)) {
                self.fail(.dma_error); // a frame before stream-on cannot be ours
            }
        }
        switch (self.phase) {
            .sensor_prepare, .frame_prepare, .csi_prepare, .isp_prepare, .dma_configure, .dma_arm, .bridge_on, .sensor_on, .wait => {
                if (now == null or now.? >= self.deadline or
                    (self.phase == .wait and now.? >= self.wait_deadline)) self.fail(.timeout);
            },
            else => {},
        }
        switch (self.phase) {
            .sensor_prepare => switch (h.prepareSensor()) {
                .pending => {},
                .done => self.phase = .frame_prepare,
                .failed => self.fail(.setup_failed),
            },
            .frame_prepare => switch (h.prepareFrame()) {
                .pending => {},
                .done => self.phase = .csi_prepare,
                .failed => self.fail(.setup_failed),
            },
            .csi_prepare => if (h.prepareCsi()) {
                self.phase = .isp_prepare;
            } else self.fail(.setup_failed),
            .isp_prepare => if (h.prepareIsp()) {
                self.phase = .dma_configure;
            } else self.fail(.setup_failed),
            .dma_configure => if (h.configureDma()) {
                self.phase = .dma_arm;
            } else self.fail(.setup_failed),
            .dma_arm => {
                self.dma_touched = true; // partial enable is treated as active
                if (h.armDma()) self.phase = .bridge_on else self.fail(.setup_failed);
            },
            .bridge_on => if (h.bridgeOn()) {
                self.phase = .sensor_on;
            } else self.fail(.setup_failed),
            .sensor_on => if (h.sensorOn()) {
                self.wait_deadline = std.math.add(u64, now.?, 5_000_000) catch self.deadline;
                self.phase = .wait;
            } else self.fail(.setup_failed),
            .wait => if (self.cancel_mode) switch (h.cancelStart()) {
                .pending => {},
                .done => self.phase = .cancel_wait,
                .failed => {
                    self.cleanup_failed = true;
                    self.phase = .sensor_off;
                },
            },
            .cancel_wait => switch (h.cancelPoll()) {
                .pending => {},
                .done => {
                    self.result = .cancel_observed;
                    self.phase = .sensor_off;
                },
                .failed => {
                    self.cleanup_failed = true;
                    self.phase = .sensor_off;
                },
            },
            .sensor_off => {
                if (!h.sensorOff()) self.cleanup_failed = true;
                self.phase = .dma_stop;
            },
            .dma_stop => switch (h.dmaStop()) {
                .pending => {},
                .done => self.phase = .isp_stop,
                .failed => {
                    self.cleanup_failed = true;
                    self.phase = .isp_stop;
                },
            },
            .isp_stop => {
                if (!h.ispStop()) self.cleanup_failed = true;
                self.phase = .csi_stop;
            },
            .csi_stop => {
                if (!h.csiStop()) self.cleanup_failed = true;
                self.phase = .power_off;
            },
            .power_off => switch (h.powerOff()) {
                .pending => {},
                .failed => {
                    self.cleanup_failed = true;
                    h.pin();
                    self.result = .cleanup_failed;
                    self.phase = .pinned;
                },
                .done => {
                    h.pin();
                    if (self.cleanup_failed) {
                        self.result = .cleanup_failed;
                        self.phase = .pinned;
                    } else {
                        if (self.completed and self.result == .none) self.result = .dma_complete;
                        self.phase = .done;
                    }
                },
            },
            else => {},
        }
    }
};
