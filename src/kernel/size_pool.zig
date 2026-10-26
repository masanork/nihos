//! Ten independently bounded size classes in one task-owned parent span.
//! Metadata operations never copy payloads; moving resize uses an explicit plan.
const slab = @import("slab.zig");
pub const classes = [_]usize{ 8, 16, 32, 64, 128, 256, 512, 1024, 2048, 4096 };
pub const Error = slab.Error;
pub const Allocation = struct { cell: slab.Allocation, class: u32 };
pub const Move = struct { old: Allocation, next: Allocation };
pub const Resize = union(enum) { done: ?Allocation, move: Move };

pub fn classFor(length: usize) ?u32 {
    if (length == 0) return null;
    for (classes, 0..) |capacity, index| if (length <= capacity) return @intCast(index);
    return null;
}

/// Canonical quotas are copied into the owner ledger, never read from PSRAM.
/// Zero disables a class without reserving a header or falling back upward.
pub const Config = struct {
    counts: [classes.len]u16,

    pub fn uniform(count: usize) ?Config {
        if (count == 0 or count > slab.max_cells) return null;
        return .{ .counts = @splat(@intCast(count)) };
    }
};

/// Trace-informed host SQLite fixture; this is not a general service budget.
pub const sqlite_probe = Config{ .counts = .{ 24, 12, 16, 12, 64, 4, 8, 12, 8, 1 } };

pub fn configuredBytes(config: Config) ?usize {
    var total: usize = 0;
    for (classes, config.counts) |capacity, count| {
        if (count == 0) continue;
        const bytes = slab.requiredBytes(capacity, count) orelse return null;
        const sum = @addWithOverflow(total, bytes);
        if (sum[1] != 0) return null;
        total = sum[0];
    }
    return if (total == 0) null else total;
}

pub fn requiredBytes(count: usize) ?usize {
    return configuredBytes(Config.uniform(count) orelse return null);
}

pub const View = struct {
    memory: []u8,
    config: Config,
    epoch: u64,

    pub noinline fn from(memory: []u8, count: usize, epoch: u64) ?View {
        return fromConfigured(memory, Config.uniform(count) orelse return null, epoch);
    }

    pub noinline fn fromConfigured(memory: []u8, config: Config, epoch: u64) ?View {
        if (epoch == 0 or @intFromPtr(memory.ptr) % slab.alignment != 0 or
            @addWithOverflow(@intFromPtr(memory.ptr), memory.len)[1] != 0 or
            configuredBytes(config) != memory.len) return null;
        return .{ .memory = memory, .config = config, .epoch = epoch };
    }

    fn classView(self: View, index: u32) Error!slab.View {
        if (index >= classes.len) return error.InvalidAllocation;
        var start: usize = 0;
        for (classes, 0..) |cell_bytes, current| {
            const count = self.config.counts[current];
            if (count == 0) {
                if (current == index) return error.OutOfMemory;
                continue;
            }
            const length = slab.requiredBytes(cell_bytes, count) orelse return error.InvalidRequest;
            if (current == index) return slab.View.from(self.memory[start..][0..length], cell_bytes, self.epoch) orelse error.InvalidRequest;
            start += length;
        }
        unreachable;
    }

    /// Linear work belongs outside the owner interrupt mask.
    pub noinline fn initialize(self: View) Error!void {
        for (self.config.counts, 0..) |count, index| {
            if (count != 0) (try self.classView(@intCast(index))).initialize();
        }
    }

    /// Fixed ten-header publication check; independent of cells per class.
    pub fn ready(self: View) Error!void {
        for (self.config.counts, 0..) |count, index| {
            if (count != 0) try (try self.classView(@intCast(index))).ready();
        }
    }

    pub noinline fn alloc(self: View, length: usize) Error!Allocation {
        const index = classFor(length) orelse return error.InvalidRequest;
        return .{ .cell = try (try self.classView(index)).allocSized(length), .class = index };
    }

    /// At most ten trusted class ranges; foreign pointers are never read.
    pub noinline fn lookup(self: View, address: usize) Error!Allocation {
        const base = @intFromPtr(self.memory.ptr);
        if (address < base or address - base >= self.memory.len) return error.InvalidAllocation;
        for (self.config.counts, 0..) |count, index| {
            if (count == 0) continue;
            const view = try self.classView(@intCast(index));
            const start = @intFromPtr(view.memory.ptr);
            if (address >= start and address - start < view.memory.len) return .{
                .cell = try view.lookup(address),
                .class = @intCast(index),
            };
        }
        return error.InvalidAllocation;
    }

    pub fn validate(self: View, allocation: Allocation) Error!void {
        try (try self.classView(allocation.class)).validate(allocation.cell);
    }

    pub fn capacity(self: View, allocation: Allocation) Error!usize {
        try self.validate(allocation);
        return classes[allocation.class];
    }

    pub noinline fn free(self: View, allocation: Allocation) Error!void {
        try (try self.classView(allocation.class)).free(allocation.cell);
    }

    /// Allocates a destination before releasing the source. A caller must
    /// copy old.cell.bytes, then commit, or cancel to release only next.
    pub noinline fn beginResize(self: View, old: ?Allocation, length: usize) Error!Resize {
        if (old) |allocation| {
            const current = try self.classView(allocation.class);
            try current.validate(allocation.cell);
            if (length == 0) {
                try current.free(allocation.cell);
                return .{ .done = null };
            }
            if (length <= classes[allocation.class]) return .{ .done = .{
                .cell = try current.renew(allocation.cell, length),
                .class = allocation.class,
            } };
            return .{ .move = .{ .old = allocation, .next = try self.alloc(length) } };
        }
        return .{ .done = if (length == 0) null else try self.alloc(length) };
    }

    fn moveShape(plan: Move) bool {
        return plan.old.class < classes.len and plan.next.class < classes.len and plan.next.class > plan.old.class and
            plan.next.cell.bytes.len > classes[plan.old.class] and plan.old.cell.bytes.ptr != plan.next.cell.bytes.ptr;
    }

    pub noinline fn commit(self: View, plan: Move) Error!Allocation {
        if (!moveShape(plan)) return error.InvalidAllocation;
        try self.validate(plan.old);
        try self.validate(plan.next);
        try self.free(plan.old);
        return plan.next;
    }

    /// Cancellation does not need to read a possibly poisoned source class.
    /// The plan is a trusted kernel borrow; the target is still fully checked.
    pub fn cancel(self: View, plan: Move) Error!void {
        if (!moveShape(plan)) return error.InvalidAllocation;
        try self.free(plan.next);
    }
};
