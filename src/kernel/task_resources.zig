//! Fixed per-task allocation ledger. Caller serializes one owner CPU.
//! Closing only touches ledger state; drainOne performs deferred heap work.
pub const Key = struct { slot: u16, generation: u16 };

pub fn Resources(comptime Backend: type, comptime capacity: usize, comptime limit: usize) type {
    return struct {
        const Self = @This();
        pub const Error = Backend.Error || error{ Inactive, Full };
        const State = enum { vacant, active, closing, cleaned, faulted };
        const Slot = struct {
            generation: u16 = 0,
            state: State = .vacant,
            allocations: [limit]?Backend.Allocation = @splat(null),
        };
        pub const Pending = struct { key: Key, allocation: ?Backend.Allocation };
        slots: [capacity]Slot = @splat(.{}),
        opened: u32 = 0,
        closed: u32 = 0,
        completed: u32 = 0,
        reclaimed: u32 = 0,
        reuses: u32 = 0,

        pub fn open(self: *Self, key: Key) bool {
            if (key.slot >= capacity or key.generation == 0) return false;
            const slot = &self.slots[key.slot];
            if ((slot.state != .vacant and slot.state != .cleaned) or key.generation <= slot.generation) return false;
            if (slot.generation != 0) self.reuses += 1;
            slot.* = .{ .generation = key.generation, .state = .active };
            self.opened += 1;
            return true;
        }

        fn resolve(self: *Self, key: Key) ?*Slot {
            if (key.slot >= capacity or key.generation == 0) return null;
            const slot = &self.slots[key.slot];
            return if (slot.generation == key.generation) slot else null;
        }

        pub fn active(self: *Self, key: Key) bool {
            return (self.resolve(key) orelse return false).state == .active;
        }

        pub fn close(self: *Self, key: Key) bool {
            const slot = self.resolve(key) orelse return false;
            if (slot.state == .closing or slot.state == .cleaned) return true;
            if (slot.state != .active) return false;
            slot.state = .closing;
            self.closed += 1;
            return true;
        }

        pub fn cleaned(self: *Self, key: Key) bool {
            return (self.resolve(key) orelse return false).state == .cleaned;
        }

        pub noinline fn alloc(self: *Self, heap: *Backend.Heap, caller: u32, key: Key, length: usize, alignment: usize) Error!Backend.Allocation {
            const slot = self.resolve(key) orelse return error.Inactive;
            if (slot.state != .active) return error.Inactive;
            for (&slot.allocations) |*entry| if (entry.* == null) {
                const allocation = try heap.alloc(caller, length, alignment);
                entry.* = allocation;
                return allocation;
            };
            return error.Full;
        }

        pub noinline fn free(self: *Self, heap: *Backend.Heap, caller: u32, key: Key, allocation: Backend.Allocation) Error!void {
            const slot = self.resolve(key) orelse return error.Inactive;
            if (slot.state != .active) return error.Inactive;
            for (&slot.allocations) |*entry| if (entry.*) |tracked| {
                if (!equal(tracked, allocation)) continue;
                try heap.free(caller, allocation);
                entry.* = null;
                return;
            };
            return error.InvalidAllocation;
        }

        pub fn equal(a: Backend.Allocation, b: Backend.Allocation) bool {
            return a.owner == b.owner and a.ticket == b.ticket and a.node == b.node and
                a.bytes.ptr == b.bytes.ptr and a.bytes.len == b.bytes.len;
        }

        pub fn pending(self: *Self) ?Pending {
            for (&self.slots, 0..) |*slot, index| {
                if (slot.state != .closing) continue;
                var allocation: ?Backend.Allocation = null;
                for (slot.allocations) |entry| if (entry != null) {
                    allocation = entry;
                    break;
                };
                return .{ .key = .{ .slot = @intCast(index), .generation = slot.generation }, .allocation = allocation };
            }
            return null;
        }

        /// One bounded release, never a bulk scan/free of an unbounded list.
        /// A heap error leaves the slot unreusable, with its entry retained.
        pub noinline fn drainOne(self: *Self, heap: *Backend.Heap, caller: u32, key: Key) Error!bool {
            const slot = self.resolve(key) orelse return error.Inactive;
            if (slot.state != .closing) return error.Inactive;
            for (&slot.allocations) |*entry| if (entry.*) |allocation| {
                heap.free(caller, allocation) catch |err| {
                    slot.state = .faulted;
                    return err;
                };
                entry.* = null;
                self.reclaimed += 1;
                break;
            };
            return self.finishEmpty(key);
        }

        /// SRAM-only completion for empty owners, including no-PSRAM boots.
        pub fn finishEmpty(self: *Self, key: Key) Error!bool {
            const slot = self.resolve(key) orelse return error.Inactive;
            if (slot.state != .closing) return error.Inactive;
            for (slot.allocations) |entry| if (entry != null) return false;
            slot.state = .cleaned;
            self.completed += 1;
            return true;
        }

        pub fn owned(self: *const Self) u32 {
            var result: u32 = 0;
            for (self.slots) |slot| for (slot.allocations) |entry| if (entry != null) {
                result += 1;
            };
            return result;
        }
    };
}
