//! Fixed per-task allocation ledger. Caller serializes one owner CPU.
//! Closing only touches ledger state; drainOne performs deferred heap work.
pub const Key = struct { slot: u16, generation: u16 };

pub fn Resources(comptime Backend: type, comptime capacity: usize, comptime limit: usize) type {
    return struct {
        const Self = @This();
        pub const Error = Backend.Error || error{ Inactive, Full };
        const State = enum { vacant, active, closing, cleaned, faulted };
        const Entry = struct {
            allocation: Backend.Allocation,
            // Canonical cursor stays in the ledger, so copied pool handles
            // cannot allocate overlapping children with independent cursors.
            cursor: ?usize = null,
        };
        pub const Pool = struct { key: Key, allocation: Backend.Allocation };
        const Slot = struct {
            generation: u16 = 0,
            state: State = .vacant,
            allocations: [limit]?Entry = @splat(null),
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

        pub fn alloc(self: *Self, heap: *Backend.Heap, caller: u32, key: Key, length: usize, alignment: usize) Error!Backend.Allocation {
            return self.acquire(heap, caller, key, length, alignment, false);
        }

        noinline fn acquire(self: *Self, heap: *Backend.Heap, caller: u32, key: Key, length: usize, alignment: usize, pool: bool) Error!Backend.Allocation {
            const slot = self.resolve(key) orelse return error.Inactive;
            if (slot.state != .active) return error.Inactive;
            for (&slot.allocations) |*entry| if (entry.* == null) {
                const allocation = try heap.alloc(caller, length, alignment);
                entry.* = .{ .allocation = allocation, .cursor = if (pool) 0 else null };
                return allocation;
            };
            return error.Full;
        }

        pub noinline fn free(self: *Self, heap: *Backend.Heap, caller: u32, key: Key, allocation: Backend.Allocation) Error!void {
            const entry = try self.find(key, allocation);
            try heap.free(caller, allocation);
            entry.* = null;
        }

        fn find(self: *Self, key: Key, allocation: Backend.Allocation) Error!*?Entry {
            const slot = self.resolve(key) orelse return error.Inactive;
            if (slot.state != .active) return error.Inactive;
            for (&slot.allocations) |*entry| if (entry.*) |tracked| {
                if (equal(tracked.allocation, allocation)) return entry;
            };
            return error.InvalidAllocation;
        }

        /// One task-owned parent consumes one ledger entry, however many
        /// children it contains. No child free/reset or fallback allocation.
        pub fn openPool(self: *Self, heap: *Backend.Heap, caller: u32, key: Key, length: usize, alignment: usize) Error!Pool {
            return .{ .key = key, .allocation = try self.acquire(heap, caller, key, length, alignment, true) };
        }

        fn poolEntry(self: *Self, caller: u32, key: Key, pool: Pool) Error!*Entry {
            if (caller != pool.allocation.owner) return error.WrongOwner;
            if (key.slot != pool.key.slot or key.generation != pool.key.generation) return error.Inactive;
            const entry = try self.find(key, pool.allocation);
            if (entry.*.?.cursor == null) return error.InvalidAllocation;
            return &entry.*.?;
        }

        /// Validates the current task and exact live parent before any
        /// pointer arithmetic. Only bounded SRAM metadata is touched here.
        pub noinline fn allocPool(self: *Self, caller: u32, key: Key, pool: Pool, length: usize, alignment: usize) Error![]u8 {
            const entry = try self.poolEntry(caller, key, pool);
            if (length == 0 or alignment == 0 or alignment & (alignment - 1) != 0) return error.InvalidRequest;
            const current = @addWithOverflow(@intFromPtr(entry.allocation.bytes.ptr), entry.cursor.?);
            const padded = @addWithOverflow(current[0], alignment - 1);
            if (current[1] != 0 or padded[1] != 0) return error.InvalidRequest;
            const start = (padded[0] & ~(alignment - 1)) - @intFromPtr(entry.allocation.bytes.ptr);
            if (start > entry.allocation.bytes.len or length > entry.allocation.bytes.len - start) return error.OutOfMemory;
            entry.cursor = start + length;
            return entry.allocation.bytes[start..][0..length];
        }

        pub fn closePool(self: *Self, heap: *Backend.Heap, caller: u32, key: Key, pool: Pool) Error!void {
            _ = try self.poolEntry(caller, key, pool);
            try self.free(heap, caller, key, pool.allocation);
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
                    allocation = entry.?.allocation;
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
            for (&slot.allocations) |*entry| if (entry.*) |tracked| {
                heap.free(caller, tracked.allocation) catch |err| {
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
