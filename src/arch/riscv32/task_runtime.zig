//! CPU-local bridge from scheduler policy and task calls to captured frames.
//! Live mutations run on the outermost interrupt stack with MIE cleared.
//! Initialization/reaping may also run on the kernel bootstrap stack while
//! this runtime is quiescent and has no executing task on another core.

pub const context = @import("context.zig");
const pmp = @import("pmp.zig");
const scheduler = @import("scheduler");
const task_control = @import("task_control");
const std = @import("std");

comptime {
    if (pmp.frame_bytes != context.integer_context_size)
        @compileError("PMP resume frame differs from the integer context");
}

pub const Image = struct {
    // The already-running bootstrap is captured by its first trap.
    frame: ?*context.IntegerContext = null,
    state: context.ReturnState = .{ .mstatus = 0, .mcause = 0 },
    stack_min: u32,
    stack_max: u32,
    floating_context: u32 = 0,
    protection: ?context.Protection = null,

    fn fits(self: Image, frame: *context.IntegerContext) bool {
        const address = @intFromPtr(frame);
        if (address & (context.stack_alignment - 1) != 0 or
            address < self.stack_min or address > self.stack_max) return false;
        return context.integer_context_size <= self.stack_max - address;
    }

    fn selected(self: Image) ?context.TaskContext {
        const frame = self.frame orelse return null;
        if (!self.privilegeAccepted(self.state)) return null;
        if (!self.fits(frame)) return null;
        return .{
            .frame = frame,
            .state = self.state,
            .stack_min = self.stack_min,
            .stack_max = self.stack_max,
            .floating_context = self.floating_context,
            .protection = self.protection,
        };
    }

    fn privilegeAccepted(self: Image, state: context.ReturnState) bool {
        const expected: u32 = if (self.protection == null) pmp.mpp_mask else pmp.user_mpp;
        return state.mstatus & pmp.mpp_mask == expected;
    }
};

pub const ContainedFault = struct {
    exited: ?scheduler.TaskHandle = null,
    next: ?context.TaskContext = null,
};

/// Protected execution is an explicit kernel-owned opt-in. The only caller
/// currently enabled by the platform is the bounded CPU0 diagnostic fixture.
pub const ProtectedAdmission = enum { denied, diagnostic };

pub fn Runtime(comptime capacity: usize, comptime priority_levels: u8) type {
    return struct {
        const Self = @This();
        pub const Policy = scheduler.Scheduler(capacity, priority_levels);
        policy: Policy = .{},
        call_options: task_control.Options = .{},
        images: [capacity]?Image = @splat(null),
        protected_admission: ProtectedAdmission = .denied,

        // Registration runs on the kernel bootstrap stack before execution.
        // Keep admission checks in Flash without moving capture/select off SRAM.
        pub noinline fn add(self: *Self, priority: u8, image: Image) linksection(pmp.text_section) ?scheduler.TaskHandle {
            if (image.stack_min >= image.stack_max) return null;
            if (image.protection) |region| {
                if (self.protected_admission != .diagnostic) return null;
                if (!pmp.protectionAccepted(region.code_lo, region.code_hi, region.data_lo, region.data_hi, image.state.mstatus, image.floating_context, image.stack_min, image.stack_max)) return null;
            }
            if (image.frame) |frame| if (!image.fits(frame) or !image.privilegeAccepted(image.state)) return null;
            const handle = self.policy.add(priority) orelse return null;
            self.images[handle.slot] = image;
            return handle;
        }

        /// Trusted kernel caller only, with interrupts masked across the actual
        /// SP transition. No scheduler slot, priority or allocation owner changes.
        pub inline fn beginStackSwitch(self: *Self, expected: scheduler.TaskHandle, low: u32, high: u32) ?Image {
            const current = self.policy.current() orelse return null;
            if (!std.meta.eql(current, expected) or low % context.stack_alignment != 0 or
                high % context.stack_alignment != 0 or low >= high or high - low < context.integer_context_size) return null;
            const original = self.images[current.slot] orelse return null;
            if (original.protection != null or original.floating_context != 0 or !original.privilegeAccepted(original.state)) return null;
            self.images[current.slot].?.stack_min = low;
            self.images[current.slot].?.stack_max = high;
            self.images[current.slot].?.frame = null;
            return original;
        }
        pub inline fn endStackSwitch(self: *Self, expected: scheduler.TaskHandle, original: Image) bool {
            const current = self.policy.current() orelse return false;
            if (!std.meta.eql(current, expected) or original.protection != null or original.floating_context != 0) return false;
            self.images[current.slot] = original;
            return true;
        }

        pub fn capture(self: *Self, frame: *context.IntegerContext, state: context.ReturnState) bool {
            const current = self.policy.current() orelse return false;
            const image = self.images[current.slot] orelse return false;
            if (!image.fits(frame) or !image.privilegeAccepted(state)) return false;
            self.images[current.slot].?.frame = frame;
            self.images[current.slot].?.state = state;
            return true;
        }

        pub fn select(self: *Self) ?context.TaskContext {
            const next = self.policy.schedule() orelse return null;
            const selected = (self.images[next.slot] orelse return null).selected() orelse return null;
            if (self.policy.takeEventResult(next)) |bits| {
                selected.frame.a0 = bits;
                selected.frame.a1 = 0;
            }
            return selected;
        }

        pub fn call(self: *Self, frame: *context.IntegerContext, state: context.ReturnState) ?context.TaskContext {
            if (!self.capture(frame, state) or frame.mepc > std.math.maxInt(u32) - 4)
                return null;
            // ECALL is always 32 bits, including when C is enabled. A sleeping
            // caller resumes after the syscall with its saved scalar reply.
            frame.mepc += 4;
            const current = self.policy.current() orelse return null;
            // Every ECALL finishes in Flash. The timer path does not call this.
            // A protected caller is refused there when the call names another task.
            return self.finishCall(frame, current);
        }

        noinline fn finishCall(self: *Self, frame: *context.IntegerContext, current: scheduler.TaskHandle) linksection(pmp.text_section) ?context.TaskContext {
            const protected = self.images[current.slot].?.protection != null;
            const reply = task_control.dispatchFrom(&self.policy, frame.a7, frame.a0, frame.a1, self.call_options, protected);
            frame.a0 = reply.low;
            frame.a1 = reply.high;
            if (reply.reschedule) return self.select();
            return (self.images[current.slot] orelse return null).selected();
        }

        /// True only for a protected task already exited by a contained fault.
        /// The caller closes and drains the ledger before reaping the slot.
        pub inline fn faultCloseable(self: *const Self, handle: scheduler.TaskHandle) bool {
            const image = self.images[handle.slot] orelse return false;
            if (image.protection == null or image.floating_context != 0) return false;
            const snapshot = self.policy.snapshot(handle) orelse return false;
            return snapshot.state == .exited and snapshot.exit_code == pmp.fault_exit;
        }

        pub const Reclaim = enum { waiting, reaped, refused };

        /// `waiting` keeps the slot while the ledger still holds it. `reaped`
        /// is returned only after `cleaned` is true.
        pub inline fn reclaimIfClean(self: *Self, handle: scheduler.TaskHandle, cleaned: bool, completed: *u64) Reclaim {
            if (!cleaned) return .waiting;
            if (!self.faultCloseable(handle)) return .refused;
            const snapshot = self.policy.snapshot(handle) orelse return .refused;
            completed.* += snapshot.runtime_ticks;
            if (!self.reap(handle)) return .refused;
            return .reaped;
        }

        /// End the running untrusted task after a contained fault. The saved
        /// frame is not resumed. `exited` is set only after that task is
        /// marked exited with `pmp.fault_exit`. Another ready task may be
        /// selected into `next`.
        pub noinline fn containFault(self: *Self) linksection(pmp.text_section) ContainedFault {
            const current = self.policy.current() orelse return .{};
            const image = self.images[current.slot] orelse return .{};
            if (image.protection == null) return .{};
            if (self.policy.exitCurrent(pmp.fault_exit) == null) return .{};
            return .{ .exited = current, .next = self.select() };
        }

        /// Reap only a completed task, from the interrupt/kernel stack. No
        /// other core or retained frame may still own its stack or FP area.
        pub fn reap(self: *Self, handle: scheduler.TaskHandle) bool {
            const snapshot = self.policy.snapshot(handle) orelse return false;
            if (snapshot.state != .exited) return false;
            if (!self.policy.remove(handle)) return false;
            self.images[handle.slot] = null;
            return true;
        }
    };
}

const user_region = context.Protection{
    .code_lo = 0x3000,
    .code_hi = 0x3100,
    .data_lo = 0x2000,
    .data_hi = 0x2800,
};

test "protected registration requires user status and the arena as its stack" {
    var runtime = Runtime(2, 2){ .protected_admission = .diagnostic };
    try std.testing.expect(runtime.add(0, .{
        .stack_min = user_region.data_lo,
        .stack_max = user_region.data_hi,
        .state = .{ .mstatus = pmp.user_mstatus, .mcause = 0 },
        .protection = user_region,
    }) != null);
    try std.testing.expect(runtime.add(0, .{
        .stack_min = user_region.data_lo,
        .stack_max = user_region.data_hi,
        .state = .{ .mstatus = 0x1880, .mcause = 0 },
        .protection = user_region,
    }) == null);
    try std.testing.expect(runtime.add(0, .{
        .stack_min = 0x1000,
        .stack_max = 0x1800,
        .state = .{ .mstatus = 0x1880, .mcause = 0 },
    }) != null);
}

test "a contained fault exits a protected task and does not exit a kernel task" {
    var kernel_runtime = Runtime(1, 1){};
    const kernel = kernel_runtime.add(0, .{
        .stack_min = 0x1000,
        .stack_max = 0x1800,
        .state = .{ .mstatus = 0x1880, .mcause = 0 },
    }).?;
    try std.testing.expect(kernel_runtime.policy.schedule() != null);
    const kernel_fault = kernel_runtime.containFault();
    try std.testing.expect(kernel_fault.exited == null and kernel_fault.next == null);
    try std.testing.expectEqual(scheduler.TaskState.running, kernel_runtime.policy.snapshot(kernel).?.state);

    var user_runtime = Runtime(1, 1){ .protected_admission = .diagnostic };
    const user = user_runtime.add(0, .{
        .stack_min = user_region.data_lo,
        .stack_max = user_region.data_hi,
        .state = .{ .mstatus = pmp.user_mstatus, .mcause = 0 },
        .protection = user_region,
    }).?;
    try std.testing.expect(user_runtime.policy.schedule() != null);
    const user_fault = user_runtime.containFault();
    try std.testing.expectEqual(user, user_fault.exited.?);
    try std.testing.expect(user_fault.next == null);
    try std.testing.expectEqual(scheduler.TaskState.exited, user_runtime.policy.snapshot(user).?.state);
    try std.testing.expectEqual(pmp.fault_exit, user_runtime.policy.snapshot(user).?.exit_code);
    try std.testing.expect(user_runtime.policy.current() == null);
    try std.testing.expect(user_runtime.reap(user));
    try std.testing.expect(user_runtime.policy.snapshot(user) == null);
    try std.testing.expect(user_runtime.add(0, .{
        .stack_min = user_region.data_lo,
        .stack_max = user_region.data_hi,
        .state = .{ .mstatus = pmp.user_mstatus, .mcause = 0 },
        .protection = user_region,
    }) != null);
}

test "a contained fault can be reaped while the kernel task keeps running" {
    var runtime = Runtime(2, 2){ .protected_admission = .diagnostic };
    const kernel = runtime.add(1, .{
        .stack_min = 0x1000,
        .stack_max = 0x1800,
        .state = .{ .mstatus = 0x1880, .mcause = 0 },
    }).?;
    const user = runtime.add(0, .{
        .stack_min = user_region.data_lo,
        .stack_max = user_region.data_hi,
        .state = .{ .mstatus = pmp.user_mstatus, .mcause = 0 },
        .protection = user_region,
    }).?;
    try std.testing.expectEqual(user, runtime.policy.schedule().?);
    const fault = runtime.containFault();
    try std.testing.expectEqual(user, fault.exited.?);
    try std.testing.expect(fault.next == null);
    try std.testing.expectEqual(scheduler.TaskState.running, runtime.policy.snapshot(kernel).?.state);
    try std.testing.expectEqual(pmp.fault_exit, runtime.policy.snapshot(user).?.exit_code);
    try std.testing.expect(runtime.reap(user));
    try std.testing.expect(runtime.policy.snapshot(user) == null);
    try std.testing.expectEqual(scheduler.TaskState.running, runtime.policy.snapshot(kernel).?.state);
}

test "ordinary runtime refuses protected tasks before allocating a slot" {
    var runtime = Runtime(2, 2){};
    const user = Image{
        .stack_min = user_region.data_lo,
        .stack_max = user_region.data_hi,
        .state = .{ .mstatus = pmp.user_mstatus, .mcause = 0 },
        .protection = user_region,
    };
    try std.testing.expect(runtime.add(0, user) == null);
    // Metadata-only synthetic RV32 frame; add() does not dereference it.
    try std.testing.expect(runtime.add(0, .{
        .frame = @ptrFromInt(0x1700),
        .stack_min = 0x1000,
        .stack_max = 0x1800,
        .state = .{ .mstatus = pmp.user_mstatus, .mcause = 0 },
    }) == null);
    const kernel = runtime.add(1, .{
        .stack_min = 0x1000,
        .stack_max = 0x1800,
        .state = .{ .mstatus = 0x1880, .mcause = 0 },
    }).?;
    try std.testing.expectEqual(@as(u16, 0), kernel.slot);
    runtime.protected_admission = .diagnostic;
    try std.testing.expect(runtime.add(0, user) != null);
}

test "kernel stack switch admits timer capture and round robin then restores bootstrap bounds" {
    var rt = Runtime(2, 1){};
    const state = context.ReturnState{ .mstatus = 0x1880, .mcause = 0x80000010 };
    const boot_frame: *context.IntegerContext = @ptrFromInt(0x1100);
    const work_frame: *context.IntegerContext = @ptrFromInt(0x3100);
    const borrowed_frame: *context.IntegerContext = @ptrFromInt(0x5100);
    const boot = rt.add(0, .{ .stack_min = 0x1000, .stack_max = 0x1800, .frame = boot_frame, .state = state }).?;
    _ = rt.add(0, .{ .stack_min = 0x3000, .stack_max = 0x3800, .frame = work_frame, .state = state }).?;
    try std.testing.expectEqual(boot, rt.policy.schedule().?);
    try std.testing.expect(!rt.capture(borrowed_frame, state));
    const saved = rt.beginStackSwitch(boot, 0x5000, 0x5800).?;
    try std.testing.expect(rt.capture(borrowed_frame, state));
    try std.testing.expectEqual(work_frame, rt.select().?.frame);
    try std.testing.expect(!rt.endStackSwitch(boot, saved));
    try std.testing.expect(rt.capture(work_frame, state));
    const resumed = rt.select().?;
    try std.testing.expectEqual(borrowed_frame, resumed.frame);
    try std.testing.expectEqual(@as(u32, 0x5000), resumed.stack_min);
    try std.testing.expect(rt.endStackSwitch(boot, saved));
    try std.testing.expect(rt.capture(boot_frame, state));
    try std.testing.expect(!rt.capture(borrowed_frame, state));
    rt.images[boot.slot].?.protection = user_region;
    try std.testing.expect(rt.beginStackSwitch(boot, 0x5000, 0x5800) == null);
}
