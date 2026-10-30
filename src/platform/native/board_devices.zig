//! CPU0 board I2C owner after display/power setup. One bounded transaction job
//! per second, plus incremental IMU initialization/acquisition, with interrupts
//! enabled. No bus resets or recovery at runtime.
const std = @import("std");
const camera_preview = @import("camera_preview");
const display = @import("display_service");
const i2c = @import("boot_i2c");
const rtc = @import("tab5_rtc");
const bmi270 = @import("tab5_bmi270");
const camera = @import("tab5_camera");
const csi = @import("tab5_csi_preflight");
const inflight = @import("tab5_csi_inflight_adapter");
const first_frame = inflight.first_frame;
const stability = @import("tab5_csi_stability");
const exposure = @import("sc202cs_exposure");
const csi_workspace = @import("csi_workspace.zig");
const options = @import("native_options");
pub const rs485 = @import("rs485_probe.zig");
pub const microphone = @import("microphone_probe.zig");
pub const audio = @import("audio_probe.zig");
pub const touch = @import("normal_touch.zig");
const timers = @import("timer_group");
const Bus = i2c.Master(display.probe.Pins);
// SAFETY: begin binds the bus before active allows poll or setCalendar.
var bus: Bus = undefined;
// SAFETY: begin binds the free-running timer before active is set.
var clock: timers.Timer = undefined;
var next: u64 = 0;
var job: u1 = 0;
var imu: bmi270.Driver = .{};
var camera_probe: camera.Probe = .{};
var csi_probe: csi.Diagnostic = .{};
const MemoryState = enum(u32) { idle, preparing, erasing, done, pinned };
var csi_memory_state: MemoryState = .idle;
const DomainState = enum(u32) { idle, acquire, release, done, pinned };
var domain_state: DomainState = .idle;
var domain_result: u32 = 0;
var domain_token: u32 = 0;
extern fn nih_camera_dma_test_begin(u32) callconv(.c) bool;
extern fn nih_camera_dma_test_poll(bool) callconv(.c) i32;
const DmaTestState = enum(u32) { idle, acquire, waiting, done, pinned };
var dma_test_state: DmaTestState = .idle;
var dma_test_result: u32 = 0;
var dma_test_started: u64 = 0;
extern fn nih_camera_dma_psram_test_begin(u32, u32) callconv(.c) bool;
const PsramDmaState = enum(u32) { idle, preparing, acquire, waiting, done, pinned };
var psram_dma_state: PsramDmaState = .idle;
var psram_dma_result: u32 = 0;
var psram_dma_started: u64 = 0;

extern fn nih_camera_dma_domain_acquire() callconv(.c) u32;
extern fn nih_camera_dma_domain_denial() callconv(.c) u32;
extern fn nih_camera_dma_domain_common(u32, *u32) callconv(.c) bool;
extern fn nih_camera_dma_domain_release_unused(u32) callconv(.c) bool;

extern fn nih_csi_prepare_720p() callconv(.c) i32;
extern fn nih_csi_prepare_stop() callconv(.c) bool;
extern fn nih_csi_prepare_busy_flags() callconv(.c) u32;
pub const cameraBootAction = first_frame.bootAction;
pub fn cameraBootFlags() u32 {
    return nih_csi_prepare_busy_flags();
}
const CsiHardware = struct {
    fn mask() u32 {
        return asm volatile ("csrrci %[previous], mstatus, 8"
            : [previous] "=r" (-> u32),
            :
            : .{ .memory = true });
    }
    fn restore(previous: u32) void {
        if (previous & 8 != 0) asm volatile ("csrsi mstatus, 8" ::: .{ .memory = true });
    }
    pub fn prepare(_: *@This()) i32 {
        const previous = mask();
        defer restore(previous);
        return nih_csi_prepare_720p();
    }
    pub fn stop(_: *@This()) bool {
        const previous = mask();
        defer restore(previous);
        return nih_csi_prepare_stop();
    }
};
var csi_hardware: CsiHardware = .{};
extern fn nih_camera_dma_domain_mark_started(u32) callconv(.c) bool;
const CsiRx = extern struct { state: u32 = 0, events: u32 = 0 };
extern fn nih_csi_dma_configure(u32, u32, u32) callconv(.c) i32;
extern fn nih_csi_dma_arm(*CsiRx) callconv(.c) bool;
extern fn nih_csi_dma_bridge_on(*CsiRx) callconv(.c) bool;
extern fn nih_csi_dma_poll(*CsiRx, u32) callconv(.c) u32;
extern fn nih_csi_dma_observe(u32) callconv(.c) u32;
extern fn nih_csi_dma_window_poll(*CsiRx, *u32) callconv(.c) bool;
extern fn nih_csi_dma_window_finish() callconv(.c) u32;
extern fn nih_csi_dma_stop(*CsiRx) callconv(.c) bool;
extern fn nih_csi_dma_retained_ready() callconv(.c) bool;
extern fn nih_csi_dma_retained_flags() callconv(.c) u32;
extern fn nih_csi_stream_begin(u32, u32) callconv(.c) bool;
extern fn nih_csi_stream_stop() callconv(.c) void;
extern fn nih_csi_stream_abort() callconv(.c) void;
extern fn nih_csi_stream_state(u32) callconv(.c) u32;
extern fn nih_csi_stream_borrow(*u32) callconv(.c) u32;
extern fn nih_csi_stream_release(u32) callconv(.c) bool;
extern fn nih_csi_stream_end() callconv(.c) bool;
var stream_requested = false;
var stream_stopping = false;
var stream_retired = false;
var stream_borrow: u32 = 0;
var stream_generation: u32 = 0;
var stream_last_shown: u32 = 0;
var stream_produced: u32 = 0;
var stream_progress_at: u64 = 0;
pub fn cameraStreaming() bool {
    return stream_requested;
}
pub fn cameraStreamStats() extern struct { completed: u32, dropped: u32, fault: u32, incomplete: u32 } {
    const previous = CsiHardware.mask();
    defer CsiHardware.restore(previous);
    return .{ .completed = nih_csi_stream_state(1), .dropped = nih_csi_stream_state(2), .fault = nih_csi_stream_state(3), .incomplete = nih_csi_stream_state(5) };
}
pub fn cameraStopStreaming() void {
    if (!stream_requested or stream_stopping) return;
    stream_stopping = true;
    const previous = CsiHardware.mask();
    defer CsiHardware.restore(previous);
    if (stream_borrow != 0) {
        if (!nih_csi_stream_release(stream_generation)) preview_fault = true;
        stream_borrow = 0;
    }
    nih_csi_stream_stop();
}
pub fn cameraStreamDrained() bool {
    if (!stream_requested or !stream_stopping or first_frame_probe.phase != .done or first_frame_probe.result != .dma_complete) return false;
    const previous = CsiHardware.mask();
    defer CsiHardware.restore(previous);
    if (!nih_csi_stream_end()) {
        preview_fault = true;
        return false;
    }
    stream_requested = false;
    stream_retired = true;
    if (camera_sequence == stream_last_shown) camera_sequence += 1;
    sample_preview_requested = false;
    screen_preview_taken = true;
    return true;
}
extern fn nih_csi_inflight_active() callconv(.c) bool;
extern fn nih_csi_inflight_generation() callconv(.c) bool;
extern fn nih_csi_inflight_masked() callconv(.c) bool;
extern fn nih_csi_inflight_status() callconv(.c) u32;
extern fn nih_csi_inflight_clear_disabled() callconv(.c) void;
extern fn nih_csi_inflight_bridge_off() callconv(.c) bool;
extern fn nih_csi_inflight_request_disable() callconv(.c) bool;
extern fn nih_csi_inflight_fifo() callconv(.c) u32;

extern fn nih_camera_xclk_start() callconv(.c) bool;
extern fn nih_camera_xclk_stop() callconv(.c) bool;
extern fn nih_camera_xclk_levels() callconv(.c) u32;
extern fn nih_camera_isp_start() callconv(.c) i32;
extern fn nih_camera_isp_stop() callconv(.c) bool;
var first_frame_probe: first_frame.Probe = .{};
var camera_reset_hold = false; // explicit camera-fixture reset diagnostic only
pub fn cameraResetHoldActive() bool {
    return camera_reset_hold and first_frame_probe.phase == .isp_prepare and first_frame_hardware.token == 0 and !first_frame_hardware.dma_uncertain;
}
const FirstFrameHardware = struct {
    retained: bool = false,
    continuous: bool = false,
    keep_configured: bool = false,
    sensor_idle_at: u64 = 0,
    retained_chunk: usize = 0,
    sensor_started: bool = false,
    low_exposure: bool = false,
    display_preview: bool = false,
    display_tone: bool = false,
    exposure_driver: exposure.Driver = .{},
    xclk_attempted: bool = false,
    frame_started: bool = false,
    frame_identity: u64 = 0,
    cancel: inflight.policy.State = .{},
    cancel_min_offset: u32 = 1,
    cancel_status: u32 = 0,
    cancel_fifo: u32 = 0,
    csi_owned: bool = false,
    isp_owned: bool = false,
    stream_attempted: bool = false,
    dma_uncertain: bool = false,
    domain_fault: bool = false,
    reason: u32 = 0,
    xclk_levels: u32 = 0,
    phy_seen: u32 = 0,
    bridge_raw: u32 = 0,
    dma_progress: u32 = 0,
    dar_samples: u32 = 0,
    dar_min: u32 = 0,
    dar_max: u32 = 0,
    window: first_frame.StopWindow = .{},
    window_late: u32 = 0,
    stop_observed: u32 = 0,
    stop_fifo: u32 = 0,
    stop_status: u32 = 0,
    stop_signal: u32 = 0,
    stop_generation: u32 = 0,
    stop_channels: u32 = 0,
    stop_before_clear: u32 = 0,
    token: u32 = 0,
    rx: CsiRx = .{},
    pub fn prepareSensor(self: *@This()) first_frame.Step {
        if (!self.sensor_started) {
            self.xclk_attempted = true;
            const previous = CsiHardware.mask();
            const clock_started = nih_camera_xclk_start();
            CsiHardware.restore(previous);
            if (!clock_started) return .failed;
            self.sensor_started = true;
            if (!camera_probe.startHeldMode()) return .failed;
        }
        return switch (camera_probe.state) {
            .held => blk: {
                if (!self.low_exposure) break :blk .done;
                if (self.exposure_driver.state == .idle and !self.exposure_driver.start(0x100)) break :blk .failed;
                self.exposure_driver.poll(&bus);
                break :blk switch (self.exposure_driver.state) {
                    .done => .done,
                    .failed => .failed,
                    else => .pending,
                };
            },
            .done, .pinned => .failed,
            else => .pending,
        };
    }
    pub fn prepareFrame(self: *@This()) first_frame.Step {
        if (self.retained) {
            var fault: u32 = 0;
            if (!nih_camera_dma_domain_common(self.token, &fault) or fault != 0 or !nih_csi_dma_retained_ready()) return .failed;
            // Normal preview batches up to 128 KiB within a 1 ms budget;
            // diagnostic fixtures retain their original 16 KiB cadence.
            const started = clock.counter();
            for (0..if (options.camera_diagnostics) @as(usize, 16) else 128) |_| {
                if (csi_workspace.readChunk(self.frame_identity, self.retained_chunk) == null) return .failed;
                self.retained_chunk += 1;
                if (self.retained_chunk == 900) break;
                if (!options.camera_diagnostics and cameraBudgetExpired(started)) break;
            }
            return if (self.retained_chunk == 900) self.prepareSecond() else .pending;
        }
        if (!self.frame_started) {
            self.frame_started = true;
            if (!csi_workspace.begin()) return .failed;
        }
        const started = clock.counter();
        for (0..if (options.camera_diagnostics) @as(usize, 16) else 128) |_| {
            csi_workspace.poll();
            if (csi_workspace.phase() == .ready_dma or csi_workspace.phase() == .pinned) break;
            if (!options.camera_diagnostics and cameraBudgetExpired(started)) break;
        }
        return switch (csi_workspace.phase()) {
            .ready_dma => self.prepareSecond(),
            .pinned => .failed,
            else => .pending,
        };
    }
    fn prepareSecond(self: *@This()) first_frame.Step {
        if (!self.continuous) return .done;
        const started = clock.counter();
        for (0..128) |_| {
            const ready = csi_workspace.prepareStreamSecond() orelse return .failed;
            if (ready) return .done;
            if (cameraBudgetExpired(started)) break;
        }
        return .pending;
    }
    pub fn prepareCsi(self: *@This()) bool {
        const status = csi_hardware.prepare();
        if (status == -2) {
            const previous = CsiHardware.mask();
            self.reason = 0x1000 | nih_csi_prepare_busy_flags();
            CsiHardware.restore(previous);
        } else if (status != 0) self.reason = @bitCast(status);
        self.csi_owned = status == 0 or status == -3;
        return status == 0;
    }
    pub fn configureDma(self: *@This()) bool {
        const address = csi_workspace.address() orelse {
            self.reason = 0x101;
            return false;
        };
        if (address < 0x48030000 or address > 0x4c000000 - 921600) {
            self.reason = 0x102;
            return false;
        }
        if (!self.retained) self.token = nih_camera_dma_domain_acquire();
        if (self.token == 0) {
            self.reason = 0x200 | nih_camera_dma_domain_denial();
            return false;
        }
        var common: u32 = 0;
        if (self.retained and (!nih_camera_dma_domain_common(self.token, &common) or common != 0 or !nih_csi_dma_retained_ready())) return false;
        if (!self.retained and !nih_camera_dma_domain_mark_started(self.token)) {
            self.reason = 0x300;
            return false;
        }
        if (!(if (self.retained) csi_workspace.restartRetainedDma(self.frame_identity) else csi_workspace.startDma())) {
            self.reason = 0x400;
            return false;
        }
        self.frame_identity = csi_workspace.dmaLeaseIdentity() orelse {
            self.reason = 0x401;
            return false;
        };
        const code = nih_csi_dma_configure(address, address, 921600);
        if (code != 0) self.reason = @bitCast(code);
        if (code == 0 and self.continuous) {
            const second = csi_workspace.streamSecondAddress() orelse return false;
            const previous = CsiHardware.mask();
            defer CsiHardware.restore(previous);
            if (!nih_csi_stream_begin(address, second)) return false;
        }
        return code == 0;
    }
    pub fn prepareIsp(self: *@This()) bool {
        const previous = CsiHardware.mask();
        const status = nih_camera_isp_start();
        CsiHardware.restore(previous);
        self.isp_owned = status == 0 or status == -2;
        if (status != 0) self.reason = @bitCast(status);
        return status == 0;
    }
    pub fn armDma(self: *@This()) bool {
        self.dma_uncertain = true;
        return nih_csi_dma_arm(&self.rx);
    }
    pub fn bridgeOn(self: *@This()) bool {
        return nih_csi_dma_bridge_on(&self.rx);
    }
    pub fn sensorOn(self: *@This()) bool {
        self.stream_attempted = true;
        // SCCB write + readback is a short bit-banged transaction pair. A
        // scheduler switch must not stretch it while the CSI receiver is armed.
        const previous = CsiHardware.mask();
        defer CsiHardware.restore(previous);
        camera.setStream(&bus, true) catch |err| {
            self.reason = 0x800 | cameraTransferReason(err);
            return false;
        };
        return true;
    }
    pub fn events(self: *@This()) first_frame.Events {
        if (self.xclk_levels == 0) self.xclk_levels = nih_camera_xclk_levels();
        if (self.stream_attempted and self.rx.state == 2 and !self.continuous) {
            self.phy_seen |= nih_csi_dma_observe(0);
            self.bridge_raw |= nih_csi_dma_observe(1);
            self.dma_progress = @max(self.dma_progress, nih_csi_dma_observe(2));
            // The adapter checks both the live DMA token and workspace
            // generation around a fresh, non-atomic DAR observation.
            var io: InFlightIo = .{ .hardware = self };
            if (io.frame()) |frame| {
                var adapter: inflight.Adapter(InFlightIo) = .{ .io = &io, .lease = self.token, .frame = frame };
                if (adapter.owned(self.token) and !adapter.commonFault(self.token)) {
                    if (adapter.snapshot()) |sample| {
                        if (adapter.owned(self.token) and !adapter.commonFault(self.token)) {
                            if (sample.offset()) |offset| {
                                if (self.dar_samples == 0) self.dar_min = offset else self.dar_min = @min(self.dar_min, offset);
                                self.dar_max = @max(self.dar_max, offset);
                                self.dar_samples +|= 1;
                            }
                        }
                    }
                }
            }
        }
        var common: u32 = 0;
        if (self.token == 0 or !nih_camera_dma_domain_common(self.token, &common)) {
            self.domain_fault = true;
            return .{ .error_detected = true };
        }
        self.domain_fault = self.domain_fault or common != 0;
        const value = if (self.rx.state == 1 or self.rx.state == 2) nih_csi_dma_poll(&self.rx, common) else self.rx.events;
        return .{ .done = value & 2 != 0, .error_detected = common != 0 or value & 0x07ffffe0 != 0 or self.bridge_raw & 0x1f != 0 };
    }
    pub fn cancelStart(self: *@This()) first_frame.Step {
        if (self.dar_samples == 0 or self.dar_max < self.cancel_min_offset) return .pending;
        var io: InFlightIo = .{ .hardware = self };
        const frame = io.frame() orelse return .failed;
        if (frame.identity != self.frame_identity) return .failed;
        var adapter: inflight.Adapter(InFlightIo) = .{ .io = &io, .lease = self.token, .frame = frame };
        return if (self.cancel.startAt(&adapter, self.token, self.cancel_min_offset)) .done else .failed;
    }
    pub fn cancelPoll(self: *@This()) first_frame.Step {
        var io: InFlightIo = .{ .hardware = self };
        const frame = io.frame() orelse return .failed;
        if (frame.identity != self.frame_identity) return .failed;
        var adapter: inflight.Adapter(InFlightIo) = .{ .io = &io, .lease = self.token, .frame = frame };
        return switch (self.cancel.poll(&adapter)) {
            .pending => .pending,
            .observed => blk: {
                self.cancel_status = io.status();
                self.cancel_fifo = io.fifo();
                // This only permits ordered peripheral shutdown. The DMA lease
                // and frame remain pinned and are never reused before reset.
                self.rx.state = 3;
                self.dma_uncertain = false;
                break :blk .done;
            },
            else => .failed,
        };
    }
    pub fn sensorOff(self: *@This()) bool {
        if (!self.stream_attempted) return true;
        const previous = CsiHardware.mask();
        defer CsiHardware.restore(previous);
        camera.setStream(&bus, false) catch |err| {
            if (self.reason == 0) self.reason = 0x900 | cameraTransferReason(err);
            return false;
        };
        self.stream_attempted = false;
        return true;
    }
    pub fn dmaStop(self: *@This()) first_frame.Step {
        if (!self.dma_uncertain) return .done;
        if (self.rx.state == 0) {
            self.dma_uncertain = false;
            return .done;
        }
        if (!self.window.started) {
            if (!nih_csi_dma_stop(&self.rx)) return .failed;
            self.stop_before_clear = nih_csi_dma_observe(8);
            if (!self.window.start(clock.counter(), 50_000)) {
                _ = nih_csi_dma_window_finish();
                return .failed;
            }
        }
        if (!nih_csi_dma_window_poll(&self.rx, &self.window_late)) {
            _ = nih_csi_dma_window_finish();
            return .failed;
        }
        const observation = self.window.observe(clock.counter());
        if (observation == .failed) {
            _ = nih_csi_dma_window_finish();
            return .failed;
        }
        if (observation == .pending and self.window_late == 0 and !self.domain_fault) return .pending;
        // Snapshot before disabling status generation; a single diagnostic sample.
        self.stop_fifo = nih_csi_dma_observe(3);
        self.stop_status = nih_csi_dma_observe(4);
        self.stop_signal = nih_csi_dma_observe(5);
        self.stop_generation = nih_csi_dma_observe(6);
        self.stop_channels = nih_csi_dma_observe(7);
        self.stop_observed = 1;
        self.window_late |= nih_csi_dma_window_finish();
        self.dma_uncertain = self.domain_fault or self.window_late != 0 or self.bridge_raw & 0x1f != 0 or self.rx.events & 2 == 0 or self.rx.events & 0x07ffffe0 != 0;
        return if (self.dma_uncertain) .failed else .done;
    }
    pub fn csiStop(self: *@This()) bool {
        if (!self.csi_owned) return true;
        if (self.dma_uncertain or self.isp_owned or !csi_hardware.stop()) return false;
        self.csi_owned = false;
        return true;
    }
    pub fn ispStop(self: *@This()) bool {
        if (!self.isp_owned) return true;
        if (self.dma_uncertain) return false;
        const previous = CsiHardware.mask();
        const stopped = nih_camera_isp_stop();
        CsiHardware.restore(previous);
        if (!stopped) return false;
        self.isp_owned = false;
        return true;
    }
    pub fn powerOff(self: *@This()) first_frame.Step {
        if (self.keep_configured and first_frame_probe.canKeepSensor() and
            camera_probe.state == .held and self.xclk_attempted and !self.stream_attempted and
            !self.csi_owned and !self.isp_owned and !self.dma_uncertain and !self.domain_fault)
        {
            const now = clock.counter() orelse return .failed;
            self.sensor_idle_at = now + 500_000;
            return .done;
        }
        switch (camera_probe.state) {
            .idle, .done => {
                if (self.xclk_attempted) {
                    const previous = CsiHardware.mask();
                    const stopped = nih_camera_xclk_stop();
                    CsiHardware.restore(previous);
                    if (!stopped) return .failed;
                    self.xclk_attempted = false;
                }
                return .done;
            },
            .pinned => return .failed,
            .held => if (!camera_probe.releaseHeld()) return .failed,
            else => camera_probe.cancel(),
        }
        return .pending;
    }
    pub fn pin(_: *@This()) void {
        csi_workspace.pin();
    }
};
// CPU0 yields between bounded batches. Missing/backward clocks end a batch.
inline fn cameraBudgetExpired(started: ?u64) bool {
    const start = started orelse return true;
    const now = clock.counter() orelse return true;
    return now < start or now - start >= 1_000;
}
inline fn cameraTransferReason(err: anyerror) u32 {
    return switch (err) {
        error.Readback => 1,
        error.AddressNack => 2,
        error.ReadAddressNack => 3,
        error.Nack => 4,
        error.BusBusy => 5,
        error.ClockTimeout => 6,
        error.ArbitrationLost => 7,
        error.Timer => 8,
        else => 255,
    };
}
// CPU0 board I2C/domain owner only. These are deliberately not exposed as a
// command outside the diagnostic capture. Failed cleanup remains unqualified.
const InFlightIo = struct {
    hardware: *FirstFrameHardware,
    pub fn domain(_: *@This(), token: u32) ?u32 {
        var fault: u32 = 0;
        if (!nih_camera_dma_domain_common(token, &fault)) return null;
        return fault;
    }
    pub fn frame(_: *@This()) ?inflight.Frame {
        const identity = csi_workspace.dmaLeaseIdentity() orelse return null;
        const base = csi_workspace.address() orelse return null;
        return .{ .identity = identity, .base = base, .length = 921600, .dma_owned = true };
    }
    pub fn active(_: *@This()) bool {
        return nih_csi_inflight_active();
    }
    pub fn status(_: *@This()) u32 {
        return nih_csi_inflight_status();
    }
    pub fn dar(_: *@This()) u32 {
        return nih_csi_dma_observe(9);
    }
    pub fn generation(_: *@This()) bool {
        return nih_csi_inflight_generation();
    }
    pub fn masked(_: *@This()) bool {
        return nih_csi_inflight_masked();
    }
    pub fn clearDisabled(_: *@This()) void {
        nih_csi_inflight_clear_disabled();
    }
    pub fn sensorOff(self: *@This()) bool {
        return self.hardware.sensorOff();
    }
    pub fn bridgeOff(_: *@This()) bool {
        return nih_csi_inflight_bridge_off();
    }
    pub fn requestDisable(_: *@This()) bool {
        return nih_csi_inflight_request_disable();
    }
    pub fn fifo(_: *@This()) u32 {
        return nih_csi_inflight_fifo();
    }
};
var first_frame_hardware: FirstFrameHardware = .{};

var active = false;
var audio_requested = false;
var microphone_requested = false;
var rs485_requested = false;
pub const Report = extern struct {
    rtc_present: u32 = 0,
    rtc_valid: u32 = 0,
    rtc_flags: u32 = 0,
    rtc_control: u32 = 0,
    rtc_error: u32 = 0,
    rtc_raw_date: u32 = 0,
    rtc_raw_time: u32 = 0,
    year: u32 = 0,
    month: u32 = 0,
    day: u32 = 0,
    hour: u32 = 0,
    minute: u32 = 0,
    second: u32 = 0,
    ina_present: u32 = 0,
    bus_uv: u32 = 0,
    shunt_uv_x10: u32 = 0,
    shunt_negative: u32 = 0,
    imu_chip: u32 = 0,
    imu_initialized: u32 = 0,
    errors: u32 = 0,
    samples: u32 = 0,
};
var report: Report = .{};
pub fn begin(timer: timers.Timer, panel: u32) void {
    if (options.devices) touch.begin(panel);
    clock = timer;
    bus = .{ .pins = .{ .clock = timer } };
    report = .{};
    job = 0;
    imu = .{};
    camera_probe = .{};
    csi_probe = .{};
    csi_memory_state = .idle;
    domain_state = .idle;
    domain_result = 0;
    domain_token = 0;
    dma_test_state = .idle;
    dma_test_result = 0;
    dma_test_started = 0;
    psram_dma_state = .idle;
    psram_dma_result = 0;
    psram_dma_started = 0;
    next = 0;
    active = true;
}
fn word(register: u8) !u16 {
    var bytes: [2]u8 = undefined;
    try bus.transfer(0x41, &.{register}, &bytes);
    return (@as(u16, bytes[0]) << 8) | bytes[1];
}
fn step() !void {
    switch (job) {
        0 => {
            report.rtc_present = 0;
            report.rtc_valid = 0;
            const sample = try rtc.read(&bus);
            report.rtc_present = 1;
            report.rtc_flags = sample.registers[13];
            report.rtc_control = sample.registers[14];
            const raw = sample.registers;
            report.rtc_raw_time = (@as(u32, raw[2]) << 16) | (@as(u32, raw[1]) << 8) | raw[0];
            report.rtc_raw_date = (@as(u32, raw[6]) << 24) | (@as(u32, raw[5]) << 16) | (@as(u32, raw[4]) << 8) | raw[3];
            report.rtc_error = 0;
            const value = sample.calendar() catch |err| {
                report.rtc_error = switch (err) {
                    error.VoltageLow => 1,
                    error.Stopped => 2,
                    else => 3,
                };
                return;
            };
            report.rtc_valid = 1;
            report.year = value.year;
            report.month = value.month;
            report.day = value.day;
            report.hour = value.hour;
            report.minute = value.minute;
            report.second = value.second;
        },
        1 => {
            report.ina_present = 0;
            if (try word(0xfe) != 0x5449 or (try word(0xff)) & 0xfff0 != 0x2260) return error.WrongDevice;
            const voltage = try word(2);
            const shunt: i16 = @bitCast(try word(1));
            report.bus_uv = @as(u32, voltage) * 1250;
            report.shunt_uv_x10 = @as(u32, @abs(@as(i32, shunt))) * 25;
            report.shunt_negative = @intFromBool(shunt < 0);
            report.ina_present = 1;
        },
    }
}
fn pollPsramDmaTest() void {
    switch (psram_dma_state) {
        .preparing => {
            csi_workspace.poll();
            switch (csi_workspace.phase()) {
                .ready_dma => psram_dma_state = .acquire,
                .pinned => {
                    psram_dma_result = 2;
                    psram_dma_state = .pinned;
                },
                else => {},
            }
        },
        .acquire => {
            const address = csi_workspace.address() orelse {
                csi_workspace.pin();
                psram_dma_result = 3;
                psram_dma_state = .pinned;
                return;
            };
            const lease = nih_camera_dma_domain_acquire();
            const now = clock.counter();
            if (lease == 0 or now == null or !csi_workspace.startDma() or
                !nih_camera_dma_psram_test_begin(lease, address))
            {
                csi_workspace.pin();
                psram_dma_result = 4;
                psram_dma_state = .pinned;
                return;
            }
            psram_dma_started = now.?;
            psram_dma_state = .waiting;
        },
        .waiting => {
            const now = clock.counter();
            const timeout = if (now) |value| value < psram_dma_started or value - psram_dma_started >= 3_000_000 else true;
            const result = nih_camera_dma_test_poll(timeout);
            if (result != 0) {
                // No evidence yet permits reuse after started DMA, even after a
                // successful copy. Pin the whole frame allocation until reset.
                csi_workspace.pin();
                if (result == 1) {
                    psram_dma_result = 1;
                    psram_dma_state = .done;
                } else {
                    psram_dma_result = @bitCast(result);
                    psram_dma_state = .pinned;
                }
            }
        },
        else => {},
    }
}
const StabilityScan = stability.Scan(900);
const CaptureScratch = union(enum) {
    preview: [camera_preview.height][camera_preview.width]u8,
    stability: StabilityScan,
};
// One-shot admission prevents simultaneous preview and scan users.
const capture_memory = @import("native_tasks").memory.reusable;
// SAFETY: prepareCaptureScratch binds this before any capture starts. The
// bootstrap owner's pin prevents reclamation while sampling or displaying it.
var capture_scratch: *CaptureScratch = undefined;
var capture_scratch_pin: ?capture_memory.Pin = null;
fn prepareCaptureScratch() bool {
    if (capture_scratch_pin != null) return true;
    const pin = capture_memory.allocPinnedTask(@sizeOf(CaptureScratch), 64) catch return false;
    capture_scratch = @ptrCast(@alignCast(pin.allocation.bytes.ptr));
    // SAFETY: the first sampling pass writes every row; display is admitted
    // only after the second complete pass has compared those initialized rows.
    capture_scratch.* = .{ .preview = undefined };
    capture_scratch_pin = pin;
    return true;
}
var scan_completed_frame = false;
var stability_timing: stability.Timing = .{};
const StabilityBackend = struct {
    pub fn counter(_: *@This()) ?u64 {
        return clock.counter();
    }
    pub fn chunk(_: *@This(), index: usize) ?[]const u8 {
        const h = &first_frame_hardware;
        var common: u32 = 0;
        if (h.token == 0 or h.frame_identity == 0 or !nih_camera_dma_domain_common(h.token, &common) or common != 0 or h.rx.state != 3) return null;
        return csi_workspace.readChunk(h.frame_identity, index);
    }
    pub fn zero(_: *@This(), index: usize) bool {
        const h = &first_frame_hardware;
        var common: u32 = 0;
        if (h.token == 0 or h.frame_identity == 0 or !nih_camera_dma_domain_common(h.token, &common) or common != 0 or h.rx.state != 3) return false;
        return csi_workspace.zeroChunk(h.frame_identity, index);
    }
    pub fn flip(_: *@This(), index: usize) bool {
        const h = &first_frame_hardware;
        var common: u32 = 0;
        if (h.token == 0 or h.frame_identity == 0 or !nih_camera_dma_domain_common(h.token, &common) or common != 0 or h.rx.state != 3) return false;
        return csi_workspace.flipChunkByte(h.frame_identity, index);
    }
};
var stability_backend: StabilityBackend = .{};

pub const PreviewRow = extern struct { pass: u32, row: u32, changed: u32, p0: u32, p1: u32, p2: u32, p3: u32, p4: u32, p5: u32, p6: u32, p7: u32, p8: u32, p9: u32, p10: u32, p11: u32, p12: u32, p13: u32, p14: u32, p15: u32, p16: u32, p17: u32, p18: u32, p19: u32 };
var sample_preview_requested = false;
var preview_pass: u32 = 0;
var preview_row: u32 = 0;
var preview_fault = false;
/// Called only by the CPU0 foreground after a completed, stopped capture.
/// Compare two sampled passes; the complete frame remains pinned until reset.
fn cameraPreviewRow() ?PreviewRow {
    if (!sample_preview_requested or first_frame_probe.phase != .done or first_frame_probe.result != .dma_complete or preview_pass >= 2 or preview_fault) return null;
    var common: u32 = 0;
    const h = &first_frame_hardware;
    if (h.token == 0 or h.frame_identity == 0 or h.rx.state != 3 or !nih_camera_dma_domain_common(h.token, &common) or common != 0) {
        preview_fault = true;
        return null;
    }
    const pixels = csi_workspace.previewRow(h.frame_identity, preview_row) orelse {
        preview_fault = true;
        return null;
    };
    if (!nih_camera_dma_domain_common(h.token, &common) or common != 0) {
        preview_fault = true;
        return null;
    }
    const changed = if (preview_pass == 0) blk: {
        capture_scratch.preview[preview_row] = pixels;
        break :blk false;
    } else !std.mem.eql(u8, &capture_scratch.preview[preview_row], &pixels);
    if (changed) preview_fault = true;
    var words: [20]u32 = undefined;
    for (&words, 0..) |*packed_word, i| {
        packed_word.* = (@as(u32, pixels[i * 4]) << 24) | (@as(u32, pixels[i * 4 + 1]) << 16) |
            (@as(u32, pixels[i * 4 + 2]) << 8) | pixels[i * 4 + 3];
    }
    const result: PreviewRow = .{ .pass = preview_pass, .row = preview_row, .changed = @intFromBool(changed), .p0 = words[0], .p1 = words[1], .p2 = words[2], .p3 = words[3], .p4 = words[4], .p5 = words[5], .p6 = words[6], .p7 = words[7], .p8 = words[8], .p9 = words[9], .p10 = words[10], .p11 = words[11], .p12 = words[12], .p13 = words[13], .p14 = words[14], .p15 = words[15], .p16 = words[16], .p17 = words[17], .p18 = words[18], .p19 = words[19] };
    preview_row += 1;
    if (preview_row == camera_preview.height) {
        preview_row = 0;
        preview_pass += 1;
    }
    return result;
}
pub fn cameraPreviewNext() ?PreviewRow {
    if (stream_requested) {
        if (stream_stopping or first_frame_probe.phase != .wait or preview_fault) return null;
        if (screen_preview_taken or stream_borrow == 0) {
            if (stream_borrow == 0) {
                const previous = CsiHardware.mask();
                stream_borrow = nih_csi_stream_borrow(&stream_generation);
                CsiHardware.restore(previous);
                if (stream_borrow == 0) return null;
                if (camera_sequence == stream_last_shown) camera_sequence += 1;
                preview_row = 0;
                preview_pass = 0;
                screen_preview_taken = false;
            }
        }
        const started = clock.counter();
        for (0..camera_preview.height * 2) |_| {
            const pixels = csi_workspace.streamPreviewRow(stream_borrow, preview_row) orelse {
                preview_fault = true;
                return null;
            };
            if (preview_pass == 0) capture_scratch.preview[preview_row] = pixels else if (!std.mem.eql(u8, &capture_scratch.preview[preview_row], &pixels)) {
                preview_fault = true;
                return null;
            }
            preview_row += 1;
            if (preview_row == camera_preview.height) {
                preview_row = 0;
                preview_pass += 1;
                if (preview_pass == 2) {
                    const previous = CsiHardware.mask();
                    if (!nih_csi_stream_release(stream_generation)) preview_fault = true;
                    CsiHardware.restore(previous);
                    stream_borrow = 0;
                    break;
                }
            }
            if (cameraBudgetExpired(started)) break;
        }
        return null;
    }
    const started = clock.counter();
    var result: ?PreviewRow = null;
    for (0..if (options.camera_diagnostics) @as(usize, 1) else camera_preview.height * 2) |_| {
        result = cameraPreviewRow() orelse break;
        if (cameraBudgetExpired(started)) break;
    }
    return result;
}

var screen_preview_taken = false;
var camera_sequence: u32 = 0;
pub fn cameraCaptureSequence() u32 {
    return camera_sequence;
}
pub fn cameraPreviewDiagnostics() bool {
    return camera_sequence == 0;
}
pub fn cameraCaptureFailed() bool {
    return preview_fault or first_frame_probe.phase == .pinned or (first_frame_probe.phase == .done and first_frame_probe.result != .dma_complete);
}
pub fn cameraRetakeReason() u32 {
    return first_frame_hardware.reason;
}
pub const ScreenPreview = struct { pixels: *const [camera_preview.height][camera_preview.width]u8, tone: bool };
pub fn cameraPreviewForDisplay() ?ScreenPreview {
    if (stream_requested and stream_stopping) return null;
    if (stream_requested) {
        const previous = CsiHardware.mask();
        const fault = nih_csi_stream_state(3);
        CsiHardware.restore(previous);
        if (fault != 0) {
            preview_fault = true;
            return null;
        }
    }
    if (!first_frame_hardware.display_preview or preview_pass != 2 or preview_fault or screen_preview_taken) return null;
    screen_preview_taken = true;
    if (stream_requested) stream_last_shown = camera_sequence;
    return .{ .pixels = &capture_scratch.preview, .tone = first_frame_hardware.display_tone };
}

fn pollDmaTest() void {
    switch (dma_test_state) {
        .acquire => {
            const lease = nih_camera_dma_domain_acquire();
            const now = clock.counter();
            if (lease == 0 or now == null or !nih_camera_dma_test_begin(lease)) {
                dma_test_result = 2;
                dma_test_state = .pinned;
                return;
            }
            dma_test_started = now.?;
            dma_test_state = .waiting;
        },
        .waiting => {
            const now = clock.counter();
            const timeout = if (now) |value| value < dma_test_started or value - dma_test_started >= 3_000_000 else true;
            const result = nih_camera_dma_test_poll(timeout);
            if (result == 1) {
                dma_test_result = 1;
                dma_test_state = .done;
            } else if (result < 0) {
                dma_test_result = @bitCast(result);
                dma_test_state = .pinned;
            }
        },
        else => {},
    }
}
fn pollDomainDiagnostic() void {
    switch (domain_state) {
        .acquire => {
            domain_token = nih_camera_dma_domain_acquire();
            if (domain_token == 0) {
                domain_result = 0x100 | nih_camera_dma_domain_denial();
                domain_state = .done;
            } else domain_state = .release;
        },
        .release => {
            var common: u32 = 0;
            if (!nih_camera_dma_domain_common(domain_token, &common) or common != 0 or
                !nih_camera_dma_domain_release_unused(domain_token))
            {
                domain_result = 3;
                domain_state = .pinned;
            } else {
                domain_result = 1;
                domain_state = .done;
            }
        },
        else => {},
    }
}
pub noinline fn poll() linksection(if (options.camera_id) ".flash.text.devices" else ".text") void {
    if (!active) return;
    if (options.camera_id) {
        const sensor_started = clock.counter();
        for (0..if (options.camera_diagnostics) @as(usize, 1) else 8) |_| {
            const before = camera_probe.state;
            const index = camera_probe.mode_driver.index;
            camera_probe.poll(&bus, clock);
            if ((camera_probe.state == before and camera_probe.mode_driver.index == index) or cameraBudgetExpired(sensor_started)) break;
        }
        csi_probe.poll(&csi_hardware);
        pollDomainDiagnostic();
        pollDmaTest();
        pollPsramDmaTest();
        const capture_started = clock.counter();
        for (0..if (options.camera_diagnostics) @as(usize, 1) else 8) |_| {
            const before = first_frame_probe.phase;
            if (before == .idle or before == .done or before == .pinned or (camera_reset_hold and before == .isp_prepare)) break;
            if (stream_requested and before == .wait) {
                const previous = CsiHardware.mask();
                if (stream_stopping) nih_csi_stream_stop();
                const produced = nih_csi_stream_state(1);
                const fault = nih_csi_stream_state(3);
                const drained = nih_csi_stream_state(4) != 0;
                CsiHardware.restore(previous);
                const now = clock.counter() orelse break;
                if (produced != stream_produced) {
                    stream_produced = produced;
                    stream_progress_at = now;
                }
                if (fault != 0 or preview_fault or now < stream_progress_at or now - stream_progress_at >= 5_000_000) {
                    const saved = CsiHardware.mask();
                    nih_csi_stream_abort();
                    CsiHardware.restore(saved);
                    first_frame_hardware.reason = fault;
                    first_frame_probe.result = .dma_error;
                    first_frame_probe.failed_phase = .wait;
                    first_frame_probe.phase = .sensor_off;
                    first_frame_hardware.domain_fault = true;
                } else if (stream_stopping and drained) {
                    first_frame_probe.completed = true;
                    first_frame_hardware.rx.events |= 2;
                    first_frame_probe.phase = .sensor_off;
                }
                break;
            }
            first_frame_probe.poll(&first_frame_hardware, clock.counter());
            if (first_frame_probe.phase == before or cameraBudgetExpired(capture_started)) break;
        }
        // Warm mode is useful only while snapshots keep arriving. Stream is
        // already off; an idle shell powers the sensor/XCLK down after 500 ms.
        if (!options.camera_diagnostics and first_frame_probe.phase == .done and first_frame_hardware.xclk_attempted) {
            const now = clock.counter();
            if (now == null or now.? >= first_frame_hardware.sensor_idle_at) first_frame_hardware.keep_configured = false;
            if (!first_frame_hardware.keep_configured and first_frame_hardware.powerOff() == .failed) preview_fault = true;
        }
        if (options.camera_diagnostics and first_frame_probe.phase == .done and first_frame_probe.result == .dma_complete and scan_completed_frame and capture_scratch.stability.phase != .done and capture_scratch.stability.phase != .failed) {
            if (capture_scratch.stability.phase == .idle) _ = capture_scratch.stability.start();
            capture_scratch.stability.pollBatch(&stability_backend, &stability_timing);
        }
        if (csi_memory_state == .preparing or csi_memory_state == .erasing) {
            csi_workspace.poll();
            switch (csi_workspace.phase()) {
                .ready_dma => if (csi_workspace.erase()) {
                    csi_memory_state = .erasing;
                } else {
                    csi_memory_state = .pinned;
                },
                .idle => csi_memory_state = .done,
                .pinned => csi_memory_state = .pinned,
                else => {},
            }
        }
    }
    const now = clock.counter() orelse {
        if ((options.audio or options.devices) and audio_requested) audio.poll(&bus, clock);
        if ((options.microphone or options.devices) and microphone_requested) microphone.poll(&bus, clock);
        if ((options.rs485 or options.devices) and rs485_requested) rs485.poll(clock);
        return;
    };
    if ((options.audio and now >= 10_000_000) or (options.devices and audio_requested)) {
        if (!audio_requested) {
            audio_requested = true;
            _ = audio.request();
        }
        audio.poll(&bus, clock);
    }
    if ((options.microphone and now >= 10_000_000) or (options.devices and microphone_requested)) {
        if (!microphone_requested) {
            microphone_requested = true;
            _ = microphone.request();
        }
        microphone.poll(&bus, clock);
    }
    if ((options.rs485 and now >= 10_000_000) or (options.devices and rs485_requested)) {
        if (!rs485_requested) {
            rs485_requested = true;
            _ = rs485.request();
        }
        rs485.poll(clock);
    }
    if (options.devices) touch.poll(&bus, clock, now);
    if (now < next) {
        imu.poll(&bus, clock);
        return;
    }
    next = now + 1_000_000;
    step() catch {
        report.errors +|= 1;
    };
    report.samples +|= 1;
    job +%= 1;
}
pub fn snapshot() Report {
    report.imu_chip = imu.chip;
    report.imu_initialized = @intFromBool(imu.initialized);
    return report;
}
pub const ImuReport = extern struct {
    chip: u32,
    initialized: u32,
    stage: u32,
    fault: u32,
    uploaded: u32,
    valid: u32,
    samples: u32,
    acc_x: u32,
    acc_y: u32,
    acc_z: u32,
    gyr_x: u32,
    gyr_y: u32,
    gyr_z: u32,
    sensor_error: u32,
    ready_status: u32,
};
pub fn imuSnapshot() ImuReport {
    return .{
        .chip = imu.chip,
        .initialized = @intFromBool(imu.initialized),
        .stage = @backingInt(imu.state),
        .fault = @backingInt(imu.fault),
        .uploaded = imu.uploaded,
        .valid = @intFromBool(imu.valid),
        .samples = imu.samples,
        .acc_x = @bitCast(@as(i32, imu.sample.acceleration[0])),
        .acc_y = @bitCast(@as(i32, imu.sample.acceleration[1])),
        .acc_z = @bitCast(@as(i32, imu.sample.acceleration[2])),
        .gyr_x = @bitCast(@as(i32, imu.sample.gyroscope[0])),
        .gyr_y = @bitCast(@as(i32, imu.sample.gyroscope[1])),
        .gyr_z = @bitCast(@as(i32, imu.sample.gyroscope[2])),
        .sensor_error = imu.error_register,
        .ready_status = imu.ready_status,
    };
}

/// For a future settings/time service, never called implicitly during boot.
pub fn setCalendar(value: rtc.DateTime) !void {
    return setCalendarSection(value, null);
}
fn setCalendarSection(value: rtc.DateTime, comptime section: ?[]const u8) !void {
    if (!active) return error.NotStarted;
    report.rtc_valid = 0;
    try rtc.setSection(&bus, value, section);
    job = 0;
    next = 0;
}

/// CPU0 foreground only. Explicit requests never run from an interrupt.
fn startCameraSnapshot() bool {
    if (!options.camera_id or first_frame_probe.phase != .idle or camera_probe.state != .idle or csi_probe.state != .idle or csi_memory_state != .idle or psram_dma_state != .idle or dma_test_state != .idle or domain_state != .idle) return false;
    const now = clock.counter() orelse return false;
    if (!prepareCaptureScratch()) return false;
    if (!first_frame_probe.start(now, 120_000_000)) return false;
    sample_preview_requested = true;
    first_frame_hardware.display_preview = true;
    first_frame_hardware.display_tone = true;
    first_frame_hardware.keep_configured = !options.camera_diagnostics;
    return true;
}
pub noinline fn requestDevice(kind: u32) linksection(if (options.camera_id) ".flash.text.devices" else ".text") bool {
    if (!options.devices or !active) return false;
    if (!options.camera_diagnostics and kind >= 6 and kind != 26 and kind != 30) return false;
    return switch (kind) {
        30 => blk: {
            const now = clock.counter() orelse break :blk false;
            if (options.camera_diagnostics or stream_requested or !requestDevice(26)) break :blk false;
            stream_requested = true;
            stream_stopping = false;
            stream_retired = false;
            stream_borrow = 0;
            stream_last_shown = camera_sequence - 1;
            stream_produced = 0;
            stream_progress_at = now;
            first_frame_hardware.continuous = true;
            break :blk true;
        },
        27 => blk: {
            // Leave only the prepared CSI clocks on, BEFORE ISP or DMA start,
            // so a USB-reset recovery can be exercised deterministically.
            if (!requestDevice(24)) break :blk false;
            camera_reset_hold = true;
            break :blk true;
        },
        26 => blk: {
            if (!options.camera_id) break :blk false;
            if (camera_sequence == 0xffffffff) break :blk false;
            if (first_frame_probe.phase == .idle) {
                if (!startCameraSnapshot()) break :blk false;
                camera_sequence += 1;
                break :blk true;
            }
            if ((!sample_preview_requested and !stream_retired) or first_frame_probe.phase != .done or first_frame_probe.result != .dma_complete or (preview_pass != 2 and !stream_retired) or preview_fault or !first_frame_hardware.display_preview) break :blk false;
            const h = &first_frame_hardware;
            var fault: u32 = 0;
            h.reason = 0x600;
            const warm = h.keep_configured and h.xclk_attempted and camera_probe.state == .held;
            const cold = !h.xclk_attempted and camera_probe.state == .done;
            if (h.dma_uncertain or h.domain_fault or h.rx.state != 3 or h.token == 0 or h.csi_owned or h.isp_owned or (!warm and !cold) or !nih_camera_dma_domain_common(h.token, &fault) or fault != 0) break :blk false;
            h.reason = 0x700 | nih_csi_dma_retained_flags();
            if (h.reason != 0x700) break :blk false;
            const now = clock.counter() orelse break :blk false;
            var next_capture: first_frame.Probe = .{};
            if (!next_capture.start(now, 120_000_000)) break :blk false;
            const retained_token = h.token;
            const retained_identity = h.frame_identity;
            first_frame_hardware = .{ .retained = true, .token = retained_token, .frame_identity = retained_identity, .display_preview = true, .display_tone = true, .keep_configured = !options.camera_diagnostics, .sensor_started = warm, .xclk_attempted = warm };
            if (!warm) camera_probe = .{};
            first_frame_probe = next_capture;
            preview_pass = 0;
            preview_row = 0;
            preview_fault = false;
            screen_preview_taken = false;
            sample_preview_requested = true;
            stream_retired = false;
            camera_sequence += 1;
            break :blk true;
        },
        1 => blk: {
            const accepted = audio.request();
            audio_requested = audio_requested or accepted;
            break :blk accepted;
        },
        2 => blk: {
            const accepted = microphone.request();
            microphone_requested = microphone_requested or accepted;
            break :blk accepted;
        },
        3, 4 => blk: {
            const accepted = rs485.requestFixture(if (kind == 3) 1 else 2);
            rs485_requested = rs485_requested or accepted;
            break :blk accepted;
        },
        5 => true,
        6 => if (options.camera_id and first_frame_probe.phase == .idle and psram_dma_state == .idle and dma_test_state == .idle and (domain_state == .idle or domain_state == .done) and (csi_memory_state == .idle or csi_memory_state == .done) and (csi_probe.state == .idle or csi_probe.state == .done)) camera_probe.start() else false,
        7 => if (options.camera_id and first_frame_probe.phase == .idle and psram_dma_state == .idle and dma_test_state == .idle and (domain_state == .idle or domain_state == .done) and (csi_memory_state == .idle or csi_memory_state == .done) and (csi_probe.state == .idle or csi_probe.state == .done)) camera_probe.startMode() else false,
        8 => if (options.camera_id and first_frame_probe.phase == .idle and psram_dma_state == .idle and dma_test_state == .idle and (domain_state == .idle or domain_state == .done) and (csi_memory_state == .idle or csi_memory_state == .done) and (camera_probe.state == .idle or camera_probe.state == .done)) csi_probe.start() else false,
        9 => blk: {
            if (!options.camera_id or first_frame_probe.phase != .idle or psram_dma_state != .idle or dma_test_state != .idle or (domain_state != .idle and domain_state != .done) or csi_memory_state != .idle or (camera_probe.state != .idle and camera_probe.state != .done) or (csi_probe.state != .idle and csi_probe.state != .done) or !csi_workspace.begin()) break :blk false;
            csi_memory_state = .preparing;
            break :blk true;
        },
        11 => blk: {
            if (!options.camera_id or first_frame_probe.phase != .idle or psram_dma_state != .idle or dma_test_state != .idle or domain_state != .idle or (csi_memory_state != .idle and csi_memory_state != .done) or (camera_probe.state != .idle and camera_probe.state != .done) or (csi_probe.state != .idle and csi_probe.state != .done)) break :blk false;
            domain_state = .acquire;
            break :blk true;
        },
        21, 25 => blk: {
            if (!options.camera_id or first_frame_probe.phase != .idle or camera_probe.state != .idle or csi_probe.state != .idle or csi_memory_state != .idle or psram_dma_state != .idle or dma_test_state != .idle or domain_state != .idle) break :blk false;
            const now = clock.counter() orelse break :blk false;
            if (!prepareCaptureScratch()) break :blk false;
            if (!first_frame_probe.start(now, 120_000_000)) break :blk false;
            capture_scratch.* = .{ .stability = .{ .inject = kind == 25 } };
            scan_completed_frame = true;
            break :blk true;
        },
        23, 24 => blk: {
            if (!options.camera_id or first_frame_probe.phase != .idle or camera_probe.state != .idle or csi_probe.state != .idle or csi_memory_state != .idle or psram_dma_state != .idle or dma_test_state != .idle or domain_state != .idle) break :blk false;
            const now = clock.counter() orelse break :blk false;
            if (!prepareCaptureScratch()) break :blk false;
            if (!first_frame_probe.start(now, 120_000_000)) break :blk false;
            sample_preview_requested = true;
            first_frame_hardware.display_preview = true;
            first_frame_hardware.display_tone = kind == 24;
            first_frame_hardware.low_exposure = kind == 23;
            break :blk true;
        },
        15 => blk: {
            if (!options.camera_id or first_frame_probe.phase != .idle or camera_probe.state != .idle or csi_probe.state != .idle or csi_memory_state != .idle or psram_dma_state != .idle or dma_test_state != .idle or domain_state != .idle) break :blk false;
            const now = clock.counter() orelse break :blk false;
            if (!prepareCaptureScratch()) break :blk false;
            if (!first_frame_probe.start(now, 120_000_000)) break :blk false;
            sample_preview_requested = true;
            first_frame_hardware.low_exposure = true;
            break :blk true;
        },
        14 => blk: {
            if (!options.camera_id or first_frame_probe.phase != .idle or camera_probe.state != .idle or csi_probe.state != .idle or csi_memory_state != .idle or psram_dma_state != .idle or dma_test_state != .idle or domain_state != .idle) break :blk false;
            const now = clock.counter() orelse break :blk false;
            if (!prepareCaptureScratch()) break :blk false;
            if (!first_frame_probe.start(now, 120_000_000)) break :blk false;
            sample_preview_requested = true;
            break :blk true;
        },
        13 => blk: {
            if (!options.camera_id or first_frame_probe.phase != .idle or psram_dma_state != .idle or dma_test_state != .idle or domain_state != .idle or csi_memory_state != .idle or (camera_probe.state != .idle and camera_probe.state != .done) or (csi_probe.state != .idle and csi_probe.state != .done) or !csi_workspace.begin()) break :blk false;
            psram_dma_state = .preparing;
            break :blk true;
        },
        12 => blk: {
            if (!options.camera_id or first_frame_probe.phase != .idle or psram_dma_state != .idle or dma_test_state != .idle or domain_state != .idle or (csi_memory_state != .idle and csi_memory_state != .done) or (camera_probe.state != .idle and camera_probe.state != .done) or (csi_probe.state != .idle and csi_probe.state != .done)) break :blk false;
            dma_test_state = .acquire;
            break :blk true;
        },
        10 => if (options.camera_id and first_frame_probe.phase == .idle and psram_dma_state == .idle and dma_test_state == .idle and (domain_state == .idle or domain_state == .done) and (csi_memory_state == .idle or csi_memory_state == .done) and (csi_probe.state == .idle or csi_probe.state == .done)) camera_probe.startStreamProbe() else false,
        else => false,
    };
}

pub fn requestedMask() u32 {
    return @as(u32, @intFromBool(audio_requested)) | (@as(u32, @intFromBool(microphone_requested)) << 1) | (@as(u32, @intFromBool(rs485_requested)) << 2);
}
pub const ServiceReport = extern struct { available: u32, requested: u32, i2s_owner: u32, pinned: u32, workspace: u32 };
pub fn serviceSnapshot() ServiceReport {
    const workspace = @import("device_workspace.zig");
    return .{ .available = if (options.devices) 7 else 0, .requested = requestedMask(), .i2s_owner = @backingInt(workspace.gate.owner), .pinned = @intFromBool(workspace.gate.pinned), .workspace = workspace.bytesReserved() };
}

pub const TimeResult = extern struct { applied: u32 = 0, failures: u32 = 0, error_code: u32 = 0, unix_high: u32 = 0, unix_low: u32 = 0 };
var time_result: TimeResult = .{};
pub noinline fn applyNetworkTime(unix_us: u64, received: u64) linksection(".flash.text.time") void {
    const now = clock.counter() orelse return;
    if (!active or now < received or now - received > 5_000_000) return;
    const seconds = (unix_us + now - received) / 1_000_000;
    const value = rtc.fromUnixSection(seconds, ".flash.text.time") catch {
        time_result.failures +|= 1;
        time_result.error_code = 1;
        return;
    };
    setCalendarSection(value, ".flash.text.time") catch |err| {
        time_result.failures +|= 1;
        time_result.error_code = @intFromError(err);
        return;
    };
    time_result.applied +|= 1;
    time_result.error_code = 0;
    time_result.unix_high = @truncate(seconds >> 32);
    time_result.unix_low = @truncate(seconds);
}
pub fn timeSnapshot() TimeResult {
    return time_result;
}

/// Identity diagnostic only; no camera frame or CSI is started.
pub fn cameraSnapshot() extern struct { state: u32, result: u32 } {
    return .{ .state = @backingInt(camera_probe.state), .result = @backingInt(camera_probe.result) };
}

pub fn csiSnapshot() extern struct { state: u32, result: u32 } {
    return .{ .state = @backingInt(csi_probe.state), .result = @backingInt(csi_probe.result) };
}

pub fn csiMemorySnapshot() extern struct { state: u32, result: u32 } {
    return .{ .state = @backingInt(csi_memory_state), .result = @backingInt(csi_workspace.phase()) };
}

pub fn cameraDomainSnapshot() extern struct { state: u32, result: u32 } {
    return .{ .state = @backingInt(domain_state), .result = domain_result };
}

pub fn cameraDmaTestSnapshot() extern struct { state: u32, result: u32 } {
    return .{ .state = @backingInt(dma_test_state), .result = dma_test_result };
}

pub fn cameraPsramDmaSnapshot() extern struct { state: u32, result: u32 } {
    return .{ .state = @backingInt(psram_dma_state), .result = psram_dma_result };
}

const CameraReport = extern struct { state: u32, result: u32 };
pub fn cameraFirstFrameSnapshot() CameraReport {
    return .{ .state = @backingInt(first_frame_probe.phase), .result = @backingInt(first_frame_probe.result) };
}
pub const FirstFrameDetail = extern struct { dma_state: u32, dma_events: u32, sensor_state: u32, sensor_result: u32, failed_phase: u32, reason: u32, xclk_levels: u32, phy_seen: u32, bridge_raw: u32, dma_progress: u32, exposure: u32, exposure_state: u32, stop_observed: u32, stop_fifo: u32, stop_status: u32, stop_signal: u32, stop_generation: u32, stop_channels: u32, window_samples: u32, window_late: u32, stop_before_clear: u32, dar_samples: u32, dar_min: u32, dar_max: u32 };

pub const FrameLeaseDetail = extern struct { low: u32, high: u32 };
pub fn cameraFrameLeaseDetail() FrameLeaseDetail {
    return .{ .low = @truncate(first_frame_hardware.frame_identity), .high = @truncate(first_frame_hardware.frame_identity >> 32) };
}

pub fn cameraFirstFrameDetail() FirstFrameDetail {
    return .{ .dma_state = first_frame_hardware.rx.state, .dma_events = first_frame_hardware.rx.events, .sensor_state = @backingInt(camera_probe.state), .sensor_result = @backingInt(camera_probe.result), .failed_phase = @backingInt(first_frame_probe.failed_phase), .reason = first_frame_hardware.reason, .xclk_levels = first_frame_hardware.xclk_levels, .phy_seen = first_frame_hardware.phy_seen, .bridge_raw = first_frame_hardware.bridge_raw, .dma_progress = first_frame_hardware.dma_progress, .exposure = first_frame_hardware.exposure_driver.lines, .exposure_state = @backingInt(first_frame_hardware.exposure_driver.state), .stop_observed = first_frame_hardware.stop_observed, .stop_fifo = first_frame_hardware.stop_fifo, .stop_status = first_frame_hardware.stop_status, .stop_signal = first_frame_hardware.stop_signal, .stop_generation = first_frame_hardware.stop_generation, .stop_channels = first_frame_hardware.stop_channels, .window_samples = first_frame_hardware.window.samples, .window_late = first_frame_hardware.window_late, .stop_before_clear = first_frame_hardware.stop_before_clear, .dar_samples = first_frame_hardware.dar_samples, .dar_min = first_frame_hardware.dar_min, .dar_max = first_frame_hardware.dar_max };
}

pub const StabilityTiming = extern struct { valid: u32, first_us: u32, second_us: u32, max_step_us: u32, steps: u32, max_batch_us: u32, batches: u32 };
pub fn cameraStabilityTiming() StabilityTiming {
    return .{ .valid = @intFromBool(stability_timing.valid), .first_us = stability_timing.first_us, .second_us = stability_timing.second_us, .max_step_us = stability_timing.max_step_us, .steps = stability_timing.steps, .max_batch_us = stability_timing.max_batch_us, .batches = stability_timing.batches };
}
pub const StabilityDetail = extern struct { state: u32, changed: u32, chunks: u32, sha_match: u32, injected: u32, zeroed: u32, nonzero: u32 };
pub fn cameraStabilityDetail() StabilityDetail {
    if (!scan_completed_frame) return .{ .state = 0, .changed = 0, .chunks = 900, .sha_match = 0, .injected = 0, .zeroed = 0, .nonzero = 0 };
    return .{ .state = @backingInt(capture_scratch.stability.phase), .changed = capture_scratch.stability.changed, .chunks = 900, .sha_match = capture_scratch.stability.sha_match, .injected = @intFromBool(capture_scratch.stability.injected), .zeroed = capture_scratch.stability.zeroed, .nonzero = capture_scratch.stability.nonzero };
}
