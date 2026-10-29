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
};

pub const ContainedFault = struct {
    exited: ?scheduler.TaskHandle = null,
    next: ?context.TaskContext = null,
};

pub fn Runtime(comptime capacity: usize, comptime priority_levels: u8) type {
    return struct {
        const Self = @This();
        pub const Policy = scheduler.Scheduler(capacity, priority_levels);
        policy: Policy = .{},
        call_options: task_control.Options = .{},
        images: [capacity]?Image = @splat(null),

        pub fn add(self: *Self, priority: u8, image: Image) ?scheduler.TaskHandle {
            if (image.stack_min >= image.stack_max) return null;
            if (image.protection) |region| {
                if (!pmp.protectionAccepted(region.code_lo, region.code_hi, region.data_lo, region.data_hi, image.state.mstatus, image.floating_context, image.stack_min, image.stack_max)) return null;
            }
            if (image.frame) |frame| if (!image.fits(frame)) return null;
            const handle = self.policy.add(priority) orelse return null;
            self.images[handle.slot] = image;
            return handle;
        }

        pub fn capture(self: *Self, frame: *context.IntegerContext, state: context.ReturnState) bool {
            const current = self.policy.current() orelse return false;
            const image = self.images[current.slot] orelse return false;
            if (!image.fits(frame)) return false;
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
            const reply = task_control.dispatchWithOptions(&self.policy, frame.a7, frame.a0, frame.a1, self.call_options);
            frame.a0 = reply.low;
            frame.a1 = reply.high;
            if (reply.reschedule) return self.select();
            const current = self.policy.current() orelse return null;
            return (self.images[current.slot] orelse return null).selected();
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
    var runtime = Runtime(2, 2){};
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

    var user_runtime = Runtime(1, 1){};
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
    var runtime = Runtime(2, 2){};
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
