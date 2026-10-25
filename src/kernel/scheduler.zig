//! Allocation-free single-core scheduler policy.
//!
//! Timer interrupt code only accumulates elapsed ticks. The safe kernel path
//! applies them here, wakes expired sleepers, and chooses a runnable task.
//! Context save/restore and architecture traps remain outside this policy.

const std = @import("std");

pub const TaskState = enum(u8) {
    vacant,
    ready,
    running,
    sleeping,
    blocked,
    exited,
};

pub const TaskHandle = struct {
    slot: u16,
    generation: u16,
};

pub const TaskSnapshot = struct {
    state: TaskState,
    priority: u8,
    runtime_ticks: u64,
    wake_tick: u64,
    exit_code: i32,
};

pub fn Scheduler(comptime capacity: usize, comptime priority_levels: u8) type {
    if (capacity == 0 or capacity > std.math.maxInt(u16))
        @compileError("scheduler capacity must fit a non-zero u16");
    if (priority_levels == 0)
        @compileError("scheduler must have at least one priority level");

    return struct {
        const Self = @This();

        const Task = struct {
            state: TaskState = .vacant,
            priority: u8 = 0,
            generation: u16 = 0,
            runtime_ticks: u64 = 0,
            wake_tick: u64 = 0,
            exit_code: i32 = 0,
        };

        tasks: [capacity]Task = @splat(.{}),
        current_slot: ?usize = null,
        last_selected: usize = capacity - 1,
        now_tick: u64 = 0,

        pub fn add(self: *Self, priority: u8) ?TaskHandle {
            if (priority >= priority_levels) return null;
            for (&self.tasks, 0..) |*task, slot| {
                if (task.state != .vacant) continue;
                const generation = nextGeneration(task.generation) orelse continue;
                task.* = .{
                    .state = .ready,
                    .priority = priority,
                    .generation = generation,
                };
                return handleFor(slot, task.generation);
            }
            return null;
        }

        pub fn remove(self: *Self, handle: TaskHandle) bool {
            const slot = self.resolve(handle) orelse return false;
            if (self.current_slot == slot) self.current_slot = null;
            const generation = self.tasks[slot].generation;
            self.tasks[slot] = .{ .generation = generation };
            return true;
        }

        /// Exit keeps a completion record until the owner explicitly reaps
        /// the task. A terminated task cannot be woken or selected again.
        pub fn exitCurrent(self: *Self, code: i32) ?TaskHandle {
            const slot = self.current_slot orelse return null;
            const task = &self.tasks[slot];
            if (task.state != .running) return null;
            task.state = .exited;
            task.exit_code = code;
            task.wake_tick = 0;
            self.current_slot = null;
            return handleFor(slot, task.generation);
        }

        pub fn block(self: *Self, handle: TaskHandle) bool {
            const slot = self.resolve(handle) orelse return false;
            switch (self.tasks[slot].state) {
                .ready, .running => self.tasks[slot].state = .blocked,
                else => return false,
            }
            if (self.current_slot == slot) self.current_slot = null;
            return true;
        }

        pub fn wake(self: *Self, handle: TaskHandle) bool {
            const slot = self.resolve(handle) orelse return false;
            switch (self.tasks[slot].state) {
                .blocked, .sleeping => {
                    self.tasks[slot].state = .ready;
                    self.tasks[slot].wake_tick = 0;
                    return true;
                },
                else => return false,
            }
        }

        pub fn sleep(self: *Self, handle: TaskHandle, duration_ticks: u64) bool {
            if (duration_ticks == 0 or
                duration_ticks > std.math.maxInt(u64) - self.now_tick)
            {
                return false;
            }
            const slot = self.resolve(handle) orelse return false;
            switch (self.tasks[slot].state) {
                .ready, .running => {
                    self.tasks[slot].state = .sleeping;
                    self.tasks[slot].wake_tick = self.now_tick + duration_ticks;
                },
                else => return false,
            }
            if (self.current_slot == slot) self.current_slot = null;
            return true;
        }

        pub fn elapse(self: *Self, ticks: u64) bool {
            if (ticks > std.math.maxInt(u64) - self.now_tick) return false;
            if (self.current_slot) |slot| {
                const task = &self.tasks[slot];
                if (ticks > std.math.maxInt(u64) - task.runtime_ticks)
                    return false;
                task.runtime_ticks += ticks;
            }
            self.now_tick += ticks;
            for (&self.tasks) |*task| {
                if (task.state == .sleeping and task.wake_tick <= self.now_tick) {
                    task.state = .ready;
                    task.wake_tick = 0;
                }
            }
            return true;
        }

        pub fn schedule(self: *Self) ?TaskHandle {
            if (self.current_slot) |slot| {
                if (self.tasks[slot].state == .running)
                    self.tasks[slot].state = .ready;
                self.current_slot = null;
            }

            var best_priority: ?u8 = null;
            for (self.tasks) |task| {
                if (task.state != .ready) continue;
                if (best_priority == null or task.priority < best_priority.?)
                    best_priority = task.priority;
            }
            const priority = best_priority orelse return null;

            for (1..capacity + 1) |offset| {
                const slot = (self.last_selected + offset) % capacity;
                const task = &self.tasks[slot];
                if (task.state != .ready or task.priority != priority) continue;
                task.state = .running;
                self.current_slot = slot;
                self.last_selected = slot;
                return handleFor(slot, task.generation);
            }
            unreachable;
        }

        pub fn now(self: *const Self) u64 {
            return self.now_tick;
        }

        pub fn current(self: *const Self) ?TaskHandle {
            const slot = self.current_slot orelse return null;
            return handleFor(slot, self.tasks[slot].generation);
        }

        pub fn snapshot(self: *const Self, handle: TaskHandle) ?TaskSnapshot {
            const slot = self.resolve(handle) orelse return null;
            const task = self.tasks[slot];
            return .{
                .state = task.state,
                .priority = task.priority,
                .runtime_ticks = task.runtime_ticks,
                .wake_tick = task.wake_tick,
                .exit_code = task.exit_code,
            };
        }

        fn resolve(self: *const Self, handle: TaskHandle) ?usize {
            const slot: usize = handle.slot;
            if (slot >= capacity) return null;
            const task = self.tasks[slot];
            if (task.state == .vacant or task.generation != handle.generation)
                return null;
            return slot;
        }

        fn handleFor(slot: usize, generation: u16) TaskHandle {
            return .{ .slot = @intCast(slot), .generation = generation };
        }

        fn nextGeneration(previous: u16) ?u16 {
            // Retire an exhausted slot rather than wrapping and making an
            // ancient handle valid again. No extra per-slot state is needed.
            if (previous == std.math.maxInt(u16)) return null;
            return previous + 1;
        }
    };
}

test "generation exhaustion retires a slot without reviving old handles" {
    var policy = Scheduler(2, 1){};
    policy.tasks[0].generation = std.math.maxInt(u16) - 1;
    const last = policy.add(0).?;
    try std.testing.expectEqual(std.math.maxInt(u16), last.generation);
    try std.testing.expect(policy.remove(last));
    const next = policy.add(0).?;
    try std.testing.expectEqual(@as(u16, 1), next.slot);
    try std.testing.expect(policy.snapshot(last) == null);
    try std.testing.expect(!policy.wake(last));
}

test "same-priority tasks run round robin" {
    var scheduler = Scheduler(3, 4){};
    const first = scheduler.add(1).?;
    const second = scheduler.add(1).?;
    const third = scheduler.add(1).?;

    try std.testing.expectEqual(first, scheduler.schedule().?);
    try std.testing.expect(scheduler.elapse(3));
    try std.testing.expectEqual(second, scheduler.schedule().?);
    try std.testing.expect(scheduler.elapse(2));
    try std.testing.expectEqual(third, scheduler.schedule().?);
    try std.testing.expectEqual(@as(u64, 3), scheduler.snapshot(first).?.runtime_ticks);
    try std.testing.expectEqual(@as(u64, 2), scheduler.snapshot(second).?.runtime_ticks);
}

test "higher-priority ready task preempts on the next decision" {
    var scheduler = Scheduler(3, 4){};
    const low = scheduler.add(3).?;
    try std.testing.expectEqual(low, scheduler.schedule().?);
    try std.testing.expect(scheduler.elapse(1));

    const high = scheduler.add(0).?;
    try std.testing.expectEqual(high, scheduler.schedule().?);
    try std.testing.expectEqual(TaskState.ready, scheduler.snapshot(low).?.state);
}

test "sleepers wake at their deadline without entering the run queue early" {
    var scheduler = Scheduler(2, 2){};
    const sleeper = scheduler.add(0).?;
    const idle = scheduler.add(1).?;
    try std.testing.expectEqual(sleeper, scheduler.schedule().?);
    try std.testing.expect(scheduler.sleep(sleeper, 5));
    try std.testing.expectEqual(idle, scheduler.schedule().?);
    try std.testing.expect(scheduler.elapse(4));
    try std.testing.expectEqual(idle, scheduler.schedule().?);
    try std.testing.expect(scheduler.elapse(1));
    try std.testing.expectEqual(sleeper, scheduler.schedule().?);
}

test "blocked tasks require an explicit wake" {
    var scheduler = Scheduler(1, 1){};
    const task = scheduler.add(0).?;
    try std.testing.expectEqual(task, scheduler.schedule().?);
    try std.testing.expect(scheduler.block(task));
    try std.testing.expect(scheduler.schedule() == null);
    try std.testing.expect(scheduler.wake(task));
    try std.testing.expectEqual(task, scheduler.schedule().?);
}

test "capacity and stale handles fail closed" {
    var scheduler = Scheduler(1, 1){};
    const old = scheduler.add(0).?;
    try std.testing.expect(scheduler.add(0) == null);
    try std.testing.expect(scheduler.add(1) == null);
    try std.testing.expect(scheduler.remove(old));
    const replacement = scheduler.add(0).?;
    try std.testing.expect(old.generation != replacement.generation);
    try std.testing.expect(scheduler.snapshot(old) == null);
    try std.testing.expect(!scheduler.wake(old));
}
