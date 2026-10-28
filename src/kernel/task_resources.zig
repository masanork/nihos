//! Fixed per-task allocation ledger. Caller serializes one owner CPU.
//! Closing only touches ledger state; drainOne performs deferred heap work.
pub const Key = struct { slot: u16, generation: u16 };
/// Runtime-scoped C identity; zero is never a live task. This is an ownership
/// check, not a capability or a persistent identifier. Native migration is off.
pub fn identity(owner: u32, key: Key) u32 {
    if (owner >= 256 or key.slot >= 256 or key.generation == 0) return 0;
    return (owner << 24) | (@as(u32, key.slot) << 16) | key.generation;
}

pub const slab = @import("slab.zig");
pub const c_allocator = @import("c_allocator.zig");
pub const size_pool = @import("size_pool.zig");
const extent_groups = @import("extent_groups.zig");

pub fn Resources(comptime Backend: type, comptime capacity: usize, comptime limit: usize) type {
    return ResourcesWithGroups(Backend, capacity, limit, 0, 0);
}

/// Group metadata is provisioned only by callers opting into this factory.
/// The default Resources keeps zero group slots and the existing task limit.
pub fn ResourcesWithGroups(comptime Backend: type, comptime capacity: usize, comptime limit: usize, comptime group_limit: usize, comptime extent_limit: usize) type {
    return struct {
        const Self = @This();
        const Groups = extent_groups.Registry(Backend, group_limit, extent_limit);
        pub const Error = Backend.Error || slab.Error || Groups.Error || error{ Inactive, Full, NotReady };
        const State = enum { vacant, active, closing, cleaned, faulted };
        const Storage = union(enum) { raw, arena: usize, slab_pending: usize, slab: usize, objects_pending: size_pool.Config, objects: size_pool.Config, extent_group: Groups.Token };
        const Entry = struct {
            allocation: Backend.Allocation,
            // Canonical cursor stays in the ledger, so copied pool handles
            // cannot allocate overlapping children with independent cursors.
            // Slab tags retain only cell size; child state lives in the parent.
            storage: Storage = .raw,
        };
        pub const Pool = struct { key: Key, allocation: Backend.Allocation };
        pub const Slab = struct { key: Key, allocation: Backend.Allocation };
        pub const Objects = struct { key: Key, allocation: Backend.Allocation };
        pub const Group = struct { key: Key, allocation: Backend.Allocation, token: Groups.Token };
        const Slot = struct {
            generation: u16 = 0,
            state: State = .vacant,
            allocations: [limit]?Entry = @splat(null),
        };
        pub const Pending = struct { key: Key, allocation: ?Backend.Allocation };
        slots: [capacity]Slot = @splat(.{}),
        groups: Groups = .{},
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
            return self.acquire(heap, caller, key, length, alignment, .raw);
        }

        noinline fn acquire(self: *Self, heap: *Backend.Heap, caller: u32, key: Key, length: usize, alignment: usize, storage: Storage) Error!Backend.Allocation {
            const slot = self.resolve(key) orelse return error.Inactive;
            if (slot.state != .active) return error.Inactive;
            for (&slot.allocations) |*entry| if (entry.* == null) {
                const allocation = try heap.alloc(caller, length, alignment);
                entry.* = .{ .allocation = allocation, .storage = storage };
                return allocation;
            };
            return error.Full;
        }

        pub noinline fn free(self: *Self, heap: *Backend.Heap, caller: u32, key: Key, allocation: Backend.Allocation) Error!void {
            const entry = try self.find(key, allocation);
            switch (entry.*.?.storage) {
                .extent_group => |token| try self.groups.close(heap, caller, token, allocation),
                else => try heap.free(caller, allocation),
            }
            entry.* = null;
        }

        /// One task-ledger entry owns a root plus a bounded, noncontiguous set
        /// of extents. The root is not a backing arena; children stay movable
        /// only through explicit client copies, never by relocating pointers.
        pub fn openGroup(self: *Self, heap: *Backend.Heap, caller: u32, key: Key) Error!Group {
            if (group_limit == 0 or extent_limit == 0) return error.Full;
            const allocation = try self.acquire(heap, caller, key, 64, 64, .raw);
            const token = self.groups.open(allocation) catch |err| {
                try self.free(heap, caller, key, allocation);
                return err;
            };
            const entry = try self.find(key, allocation);
            entry.*.?.storage = .{ .extent_group = token };
            return .{ .key = key, .allocation = allocation, .token = token };
        }

        fn groupEntry(self: *Self, caller: u32, key: Key, group: Group) Error!Groups.Token {
            const entry = try self.leaseEntry(caller, key, group.key, group.allocation);
            return switch (entry.storage) {
                .extent_group => |token| if (token.index == group.token.index and token.ticket == group.token.ticket) token else error.InvalidGroup,
                else => error.InvalidGroup,
            };
        }

        pub fn allocExtent(self: *Self, heap: *Backend.Heap, caller: u32, key: Key, group: Group, length: usize, alignment: usize) Error!Backend.Allocation {
            return self.groups.alloc(heap, caller, try self.groupEntry(caller, key, group), group.allocation, length, alignment);
        }

        pub fn freeExtent(self: *Self, heap: *Backend.Heap, caller: u32, key: Key, group: Group, allocation: Backend.Allocation) Error!void {
            try self.groups.free(heap, caller, try self.groupEntry(caller, key, group), group.allocation, allocation);
        }

        pub fn extentCount(self: *Self, caller: u32, key: Key, group: Group) Error!usize {
            return self.groups.count(try self.groupEntry(caller, key, group), group.allocation);
        }

        pub fn extentFromPointer(self: *Self, caller: u32, key: Key, group: Group, address: usize) Error!Backend.Allocation {
            return self.groups.fromPointer(try self.groupEntry(caller, key, group), group.allocation, address);
        }

        pub fn closeGroup(self: *Self, heap: *Backend.Heap, caller: u32, key: Key, group: Group) Error!void {
            _ = try self.groupEntry(caller, key, group);
            try self.free(heap, caller, key, group.allocation);
        }

        noinline fn find(self: *Self, key: Key, allocation: Backend.Allocation) Error!*?Entry {
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
            return .{ .key = key, .allocation = try self.acquire(heap, caller, key, length, alignment, .{ .arena = 0 }) };
        }

        noinline fn leaseEntry(self: *Self, caller: u32, key: Key, lease_key: Key, allocation: Backend.Allocation) Error!*Entry {
            if (caller != allocation.owner) return error.WrongOwner;
            if (key.slot != lease_key.slot or key.generation != lease_key.generation) return error.Inactive;
            const entry = try self.find(key, allocation);
            return &entry.*.?;
        }

        fn poolEntry(self: *Self, caller: u32, key: Key, pool: Pool) Error!*Entry {
            const entry = try self.leaseEntry(caller, key, pool.key, pool.allocation);
            switch (entry.storage) {
                .arena => return entry,
                else => return error.InvalidAllocation,
            }
        }

        /// Validates the current task and exact live parent before any
        /// pointer arithmetic. Only bounded SRAM metadata is touched here.
        pub noinline fn allocPool(self: *Self, caller: u32, key: Key, pool: Pool, length: usize, alignment: usize) Error![]u8 {
            const entry = try self.poolEntry(caller, key, pool);
            if (length == 0 or alignment == 0 or alignment & (alignment - 1) != 0) return error.InvalidRequest;
            const current = @addWithOverflow(@intFromPtr(entry.allocation.bytes.ptr), entry.storage.arena);
            const padded = @addWithOverflow(current[0], alignment - 1);
            if (current[1] != 0 or padded[1] != 0) return error.InvalidRequest;
            const start = (padded[0] & ~(alignment - 1)) - @intFromPtr(entry.allocation.bytes.ptr);
            if (start > entry.allocation.bytes.len or length > entry.allocation.bytes.len - start) return error.OutOfMemory;
            entry.storage.arena = start + length;
            return entry.allocation.bytes[start..][0..length];
        }

        pub fn closePool(self: *Self, heap: *Backend.Heap, caller: u32, key: Key, pool: Pool) Error!void {
            _ = try self.poolEntry(caller, key, pool);
            try self.free(heap, caller, key, pool.allocation);
        }

        /// Phase one registers the parent before any linear initialization.
        /// Caller initializes prepareSlab's view outside the owner lock, then
        /// publishes. Closing a task can reclaim even an unfinished parent.
        pub fn reserveSlab(self: *Self, heap: *Backend.Heap, caller: u32, key: Key, object_bytes: usize, count: usize) Error!Slab {
            const length = slab.requiredBytes(object_bytes, count) orelse return error.InvalidRequest;
            return .{ .key = key, .allocation = try self.acquire(heap, caller, key, length, slab.alignment, .{ .slab_pending = object_bytes }) };
        }

        pub fn prepareSlab(self: *Self, caller: u32, key: Key, lease: Slab) Error!slab.View {
            const entry = try self.leaseEntry(caller, key, lease.key, lease.allocation);
            return switch (entry.storage) {
                .slab_pending => |object_bytes| slab.View.from(entry.allocation.bytes, object_bytes, entry.allocation.ticket) orelse error.InvalidRequest,
                else => error.InvalidAllocation,
            };
        }

        /// Publication checks the fixed parent header, never a child list.
        /// Caller has completed initialization while retaining ownership.
        pub fn publishSlab(self: *Self, caller: u32, key: Key, lease: Slab) Error!void {
            const entry = try self.leaseEntry(caller, key, lease.key, lease.allocation);
            switch (entry.storage) {
                .slab_pending => |object_bytes| {
                    const view = slab.View.from(entry.allocation.bytes, object_bytes, entry.allocation.ticket) orelse return error.InvalidRequest;
                    try view.ready();
                    entry.storage = .{ .slab = object_bytes };
                },
                else => return error.InvalidAllocation,
            }
        }

        noinline fn slabView(self: *Self, caller: u32, key: Key, lease: Slab) Error!slab.View {
            const entry = try self.leaseEntry(caller, key, lease.key, lease.allocation);
            return switch (entry.storage) {
                .slab => |object_bytes| slab.View.from(entry.allocation.bytes, object_bytes, entry.allocation.ticket) orelse error.InvalidRequest,
                .slab_pending => error.NotReady,
                else => error.InvalidAllocation,
            };
        }

        pub fn allocSlab(self: *Self, caller: u32, key: Key, lease: Slab) Error!slab.Allocation {
            return (try self.slabView(caller, key, lease)).alloc();
        }

        pub fn freeSlab(self: *Self, caller: u32, key: Key, lease: Slab, allocation: slab.Allocation) Error!void {
            return (try self.slabView(caller, key, lease)).free(allocation);
        }

        /// Explicit close also permits aborting phase-one initialization.
        pub fn closeSlab(self: *Self, heap: *Backend.Heap, caller: u32, key: Key, lease: Slab) Error!void {
            const entry = try self.leaseEntry(caller, key, lease.key, lease.allocation);
            switch (entry.storage) {
                .slab, .slab_pending => try self.free(heap, caller, key, lease.allocation),
                else => return error.InvalidAllocation,
            }
        }

        pub fn reserveObjects(self: *Self, heap: *Backend.Heap, caller: u32, key: Key, count: usize) Error!Objects {
            return self.reserveConfiguredObjects(heap, caller, key, size_pool.Config.uniform(count) orelse return error.InvalidRequest);
        }

        pub fn reserveConfiguredObjects(self: *Self, heap: *Backend.Heap, caller: u32, key: Key, config: size_pool.Config) Error!Objects {
            const length = size_pool.configuredBytes(config) orelse return error.InvalidRequest;
            return .{ .key = key, .allocation = try self.acquire(heap, caller, key, length, slab.alignment, .{ .objects_pending = config }) };
        }

        pub fn prepareObjects(self: *Self, caller: u32, key: Key, lease: Objects) Error!size_pool.View {
            const entry = try self.leaseEntry(caller, key, lease.key, lease.allocation);
            return switch (entry.storage) {
                .objects_pending => |config| size_pool.View.fromConfigured(entry.allocation.bytes, config, entry.allocation.ticket) orelse error.InvalidRequest,
                else => error.InvalidAllocation,
            };
        }

        pub fn publishObjects(self: *Self, caller: u32, key: Key, lease: Objects) Error!void {
            const entry = try self.leaseEntry(caller, key, lease.key, lease.allocation);
            switch (entry.storage) {
                .objects_pending => |config| {
                    const view = size_pool.View.fromConfigured(entry.allocation.bytes, config, entry.allocation.ticket) orelse return error.InvalidRequest;
                    try view.ready();
                    entry.storage = .{ .objects = config };
                },
                else => return error.InvalidAllocation,
            }
        }

        noinline fn objectsView(self: *Self, caller: u32, key: Key, lease: Objects) Error!size_pool.View {
            const entry = try self.leaseEntry(caller, key, lease.key, lease.allocation);
            return switch (entry.storage) {
                .objects => |config| size_pool.View.fromConfigured(entry.allocation.bytes, config, entry.allocation.ticket) orelse error.InvalidRequest,
                .objects_pending => error.NotReady,
                else => error.InvalidAllocation,
            };
        }

        pub fn allocObject(self: *Self, caller: u32, key: Key, lease: Objects, length: usize) Error!size_pool.Allocation {
            return (try self.objectsView(caller, key, lease)).alloc(length);
        }

        pub fn objectFromPointer(self: *Self, caller: u32, key: Key, lease: Objects, address: usize) Error!size_pool.Allocation {
            return (try self.objectsView(caller, key, lease)).lookup(address);
        }

        pub fn freeObject(self: *Self, caller: u32, key: Key, lease: Objects, allocation: size_pool.Allocation) Error!void {
            try (try self.objectsView(caller, key, lease)).free(allocation);
        }

        pub fn objectCapacity(self: *Self, caller: u32, key: Key, lease: Objects, allocation: size_pool.Allocation) Error!usize {
            return (try self.objectsView(caller, key, lease)).capacity(allocation);
        }

        pub fn beginObjectResize(self: *Self, caller: u32, key: Key, lease: Objects, old: ?size_pool.Allocation, length: usize) Error!size_pool.Resize {
            return (try self.objectsView(caller, key, lease)).beginResize(old, length);
        }

        pub fn commitObjectResize(self: *Self, caller: u32, key: Key, lease: Objects, plan: size_pool.Move) Error!size_pool.Allocation {
            return (try self.objectsView(caller, key, lease)).commit(plan);
        }

        pub fn cancelObjectResize(self: *Self, caller: u32, key: Key, lease: Objects, plan: size_pool.Move) Error!void {
            try (try self.objectsView(caller, key, lease)).cancel(plan);
        }

        pub fn closeObjects(self: *Self, heap: *Backend.Heap, caller: u32, key: Key, lease: Objects) Error!void {
            const entry = try self.leaseEntry(caller, key, lease.key, lease.allocation);
            switch (entry.storage) {
                .objects, .objects_pending => try self.free(heap, caller, key, lease.allocation),
                else => return error.InvalidAllocation,
            }
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
                const complete = switch (tracked.storage) {
                    .extent_group => |token| self.groups.drainOne(heap, caller, token, tracked.allocation),
                    else => blk: {
                        heap.free(caller, tracked.allocation) catch |err| break :blk @as(Error!bool, err);
                        break :blk @as(Error!bool, true);
                    },
                } catch |err| {
                    slot.state = .faulted;
                    return err;
                };
                if (!complete) return false;
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
