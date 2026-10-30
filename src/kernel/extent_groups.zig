//! Opt-in bounded extent ownership. Canonical handles stay in trusted metadata.
//! The caller serializes one owner CPU; no payload initialization or copy here.
pub fn Registry(comptime Backend: type, comptime group_limit: usize, comptime extent_limit: usize) type {
    return struct {
        const Self = @This();
        pub const Token = struct { index: u32, ticket: u64 };
        pub const Error = Backend.Error || error{ Full, InvalidGroup, GroupBusy };
        const Group = struct {
            root: Backend.Allocation,
            children: [extent_limit]?Backend.Allocation = @splat(null),
        };
        groups: [group_limit]?Group = @splat(null),

        fn equal(a: Backend.Allocation, b: Backend.Allocation) bool {
            return a.owner == b.owner and a.ticket == b.ticket and a.node == b.node and
                a.bytes.ptr == b.bytes.ptr and a.bytes.len == b.bytes.len;
        }

        pub fn open(self: *Self, root: Backend.Allocation) Error!Token {
            for (&self.groups, 0..) |*entry, index| if (entry.* == null) {
                entry.* = .{ .root = root };
                return .{ .index = @intCast(index), .ticket = root.ticket };
            };
            return error.Full;
        }

        fn resolve(self: *Self, token: Token, root: Backend.Allocation) Error!*Group {
            if (token.index >= group_limit) return error.InvalidGroup;
            const group = if (self.groups[token.index]) |*live| live else return error.InvalidGroup;
            if (token.ticket != group.root.ticket or !equal(root, group.root)) return error.InvalidGroup;
            return group;
        }

        pub fn alloc(self: *Self, heap: *Backend.Heap, caller: u32, token: Token, root: Backend.Allocation, length: usize, alignment: usize) Error!Backend.Allocation {
            if (caller != root.owner) return error.WrongOwner;
            const group = try self.resolve(token, root);
            for (&group.children) |*entry| if (entry.* == null) {
                const allocation = try heap.alloc(caller, length, alignment);
                entry.* = allocation;
                return allocation;
            };
            return error.Full;
        }

        pub fn free(self: *Self, heap: *Backend.Heap, caller: u32, token: Token, root: Backend.Allocation, allocation: Backend.Allocation) Error!void {
            if (caller != root.owner) return error.WrongOwner;
            const group = try self.resolve(token, root);
            for (&group.children) |*entry| if (entry.*) |canonical| {
                if (!equal(canonical, allocation)) continue;
                try heap.free(caller, canonical);
                entry.* = null;
                return;
            };
            return error.InvalidAllocation;
        }

        pub fn count(self: *Self, token: Token, root: Backend.Allocation) Error!usize {
            const group = try self.resolve(token, root);
            var live: usize = 0;
            for (group.children) |entry| if (entry != null) {
                live += 1;
            };
            return live;
        }

        pub fn fromPointer(self: *Self, token: Token, root: Backend.Allocation, address: usize) Error!Backend.Allocation {
            const group = try self.resolve(token, root);
            for (group.children) |entry| if (entry) |canonical| {
                if (@intFromPtr(canonical.bytes.ptr) == address) return canonical;
            };
            return error.InvalidAllocation;
        }

        pub fn close(self: *Self, heap: *Backend.Heap, caller: u32, token: Token, root: Backend.Allocation) Error!void {
            if (group_limit == 0) return error.InvalidGroup;
            if (caller != root.owner) return error.WrongOwner;
            if (try self.count(token, root) != 0) return error.GroupBusy;
            try heap.free(caller, root);
            self.groups[token.index] = null;
        }

        /// Each call frees exactly one child, or the empty root. A heap failure
        /// preserves its canonical handle and blocks task-slot reuse upstream.
        pub fn drainOne(self: *Self, heap: *Backend.Heap, caller: u32, token: Token, root: Backend.Allocation) Error!bool {
            if (caller != root.owner) return error.WrongOwner;
            const group = try self.resolve(token, root);
            for (&group.children) |*entry| if (entry.*) |canonical| {
                try heap.free(caller, canonical);
                entry.* = null;
                return false;
            };
            try self.close(heap, caller, token, root);
            return true;
        }
    };
}
