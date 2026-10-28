//! CPU-local bridge from scheduler policy and task calls to captured frames.
//! Live mutations run on the outermost interrupt stack with MIE cleared.
//! Initialization/reaping may also run on the kernel bootstrap stack while
//! this runtime is quiescent and has no executing task on another core.

pub const context = @import("context.zig");
const scheduler = @import("scheduler");
const task_control = @import("task_control");
const std = @import("std");

pub const Image = struct {
    // The already-running bootstrap is captured by its first trap.
    frame: ?*context.IntegerContext = null,
    state: context.ReturnState = .{ .mstatus = 0, .mcause = 0 },
    stack_min: u32,
    stack_max: u32,
    floating_context: u32 = 0,

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
        };
    }
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
