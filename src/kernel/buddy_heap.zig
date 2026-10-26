//! Owner-local reusable heap. External tree metadata, bounded path walks.
//! Handles detect stale frees within this heap lifetime, not stale accesses.
const std = @import("std");

pub const granule: usize = 64;
pub const header_bytes = @sizeOf(Header);
const allocated: u8 = 0x80;
const Header = extern struct { ticket: u64, length: u32, offset: u32 };

pub const Allocation = struct { bytes: []u8, ticket: u64, node: u32, owner: u32 };
pub const Error = error{ InvalidRequest, OutOfMemory, InvalidAllocation, WrongOwner, Corrupt, Faulted, SerialExhausted };

pub const Heap = struct {
    memory: []u8,
    tree: []u8,
    payload: []u8,
    leaves: usize,
    levels: u8,
    owner: u32,
    ticket: u64 = 0,
    free_bytes: usize,
    live: u32 = 0,
    allocations: u32 = 0,
    frees: u32 = 0,
    max_steps: u32 = 0,
    faulted: bool = false,

    /// Initialization is linear and boot-only. Operations afterwards walk
    /// at most three tree paths, never scan all blocks or fill payloads.
    pub fn init(memory: []u8, owner: u32) ?Heap {
        if (owner >= 2 or @intFromPtr(memory.ptr) % granule != 0 or memory.len % granule != 0 or
            memory.len < 512 or memory.len > 32 * 1024 * 1024) return null;
        const leaves = std.math.ceilPowerOfTwo(usize, (memory.len - 2 * granule) / granule) catch return null;
        const metadata = @max(granule, 2 * leaves);
        if (metadata + 3 * granule > memory.len) return null;
        const payload = memory[granule + metadata .. memory.len - granule];
        var self = Heap{
            .memory = memory,
            .tree = memory[granule .. granule + metadata],
            .payload = payload,
            .leaves = leaves,
            .levels = @intCast(std.math.log2_int(usize, leaves)),
            .owner = owner,
            .free_bytes = payload.len,
        };
        @memset(self.tree, 0);
        for (0..granule) |index| {
            memory[index] = self.guardByte(index);
            memory[memory.len - granule + index] = self.guardByte(index);
        }
        for (0..payload.len / granule) |index| self.tree[leaves + index] = 1;
        var node = leaves - 1;
        while (node != 0) : (node -= 1) self.tree[node] = self.join(node, self.nodeOrder(node));
        return self;
    }

    pub fn largestBlock(self: *const Heap) usize {
        const value = available(self.tree[1]);
        if (value == 0 or value > self.levels + 1) return 0;
        return granule << @as(std.math.Log2Int(usize), @intCast(value - 1));
    }

    pub noinline fn alloc(self: *Heap, caller: u32, length: usize, alignment: usize) Error!Allocation {
        if (caller != self.owner) return error.WrongOwner;
        if (self.faulted) return error.Faulted;
        if (length == 0 or alignment == 0 or alignment & (alignment - 1) != 0 or alignment > 65536 or
            length > self.payload.len or header_bytes + alignment - 1 > self.payload.len - length) return error.InvalidRequest;
        if (self.ticket == std.math.maxInt(u64)) return error.SerialExhausted;
        if (!self.guardsValid()) return self.corrupt();
        const required = length + header_bytes + alignment - 1;
        const units = (required + granule - 1) / granule;
        const count = std.math.ceilPowerOfTwo(usize, units) catch return error.OutOfMemory;
        const wanted: u8 = @intCast(std.math.log2_int(usize, count));
        var node: usize = 1;
        var order = self.levels;
        var steps: u32 = 0;
        defer self.max_steps = @max(self.max_steps, steps);
        while (true) {
            steps += 1;
            if (!self.nodeValid(node, order)) return self.corrupt();
            if (available(self.tree[node]) < wanted + 1) return error.OutOfMemory;
            if (order == wanted) break;
            const left = node * 2;
            node = if (available(self.tree[left]) >= wanted + 1) left else left + 1;
            order -= 1;
        }
        // Validate siblings/ancestors before changing any accounting or data.
        try self.validatePath(node, &steps);
        const block = self.blockSpan(node, order);
        if (block.len > self.free_bytes) return self.corrupt();
        const base = @intFromPtr(block.ptr);
        const address = (base + header_bytes + alignment - 1) & ~(alignment - 1);
        self.ticket += 1;
        const header: *Header = @ptrCast(@alignCast(block.ptr));
        header.* = .{ .ticket = self.ticket, .length = @intCast(length), .offset = @intCast(address - base) };
        self.tree[node] = allocated | order;
        self.update(node, &steps);
        self.free_bytes -= block.len;
        self.live += 1;
        self.allocations +%= 1;
        const bytes: [*]u8 = @ptrFromInt(address);
        return .{ .bytes = bytes[0..length], .ticket = self.ticket, .node = @intCast(node), .owner = caller };
    }

    pub noinline fn free(self: *Heap, caller: u32, allocation: Allocation) Error!void {
        if (caller != self.owner or allocation.owner != caller) return error.WrongOwner;
        if (self.faulted) return error.Faulted;
        if (!self.guardsValid()) return self.corrupt();
        const node: usize = allocation.node;
        if (node == 0 or node >= 2 * self.leaves) return error.InvalidAllocation;
        const order = self.nodeOrder(node);
        if (self.tree[node] != allocated | order) return error.InvalidAllocation;
        var steps: u32 = 0;
        defer self.max_steps = @max(self.max_steps, steps);
        try self.validatePath(node, &steps);
        const block = self.blockSpan(node, order);
        const header: *const Header = @ptrCast(@alignCast(block.ptr));
        if (header.ticket != allocation.ticket or allocation.ticket == 0 or
            allocation.bytes.len != header.length or header.length == 0 or
            header.offset < header_bytes or header.offset > block.len or header.length > block.len - header.offset or
            @intFromPtr(allocation.bytes.ptr) != @intFromPtr(block.ptr) + header.offset) return error.InvalidAllocation;
        if (self.live == 0 or block.len > self.payload.len - self.free_bytes) return self.corrupt();
        self.tree[node] = order + 1;
        self.update(node, &steps);
        self.free_bytes += block.len;
        self.live -= 1;
        self.frees +%= 1;
    }

    fn available(value: u8) u8 {
        return if (value & allocated != 0) 0 else value;
    }

    fn nodeOrder(self: *const Heap, node: usize) u8 {
        return self.levels - @as(u8, @intCast(std.math.log2_int(usize, node)));
    }

    fn blockSpan(self: *const Heap, node: usize, level: u8) []u8 {
        const depth = self.levels - level;
        const first = @as(usize, 1) << @as(std.math.Log2Int(usize), @intCast(depth));
        const length = granule << @as(std.math.Log2Int(usize), @intCast(level));
        const start = (node - first) * length;
        return self.payload[start .. start + length];
    }

    fn validValue(value: u8, level: u8) bool {
        return value <= level + 1 or value == allocated | level;
    }

    fn nodeValid(self: *const Heap, node: usize, level: u8) bool {
        const value = self.tree[node];
        if (!validValue(value, level)) return false;
        if (value == allocated | level or value == level + 1) {
            // Neither an allocated nor a wholly free forged node may
            // authorize an out-of-span header read or allocation.
            const length = granule << @as(std.math.Log2Int(usize), @intCast(level));
            const depth = self.levels - level;
            const first = @as(usize, 1) << @as(std.math.Log2Int(usize), @intCast(depth));
            const start = (node - first) * length;
            if (start > self.payload.len or length > self.payload.len - start) return false;
            if (value == allocated | level) return true;
        }
        if (level == 0) return value == @intFromBool(node - self.leaves < self.payload.len / granule);
        if (!validValue(self.tree[node * 2], level - 1) or !validValue(self.tree[node * 2 + 1], level - 1)) return false;
        return value == self.join(node, level);
    }

    fn join(self: *const Heap, node: usize, level: u8) u8 {
        const left = available(self.tree[node * 2]);
        const right = available(self.tree[node * 2 + 1]);
        return if (left == level and right == level) level + 1 else @max(left, right);
    }

    fn validatePath(self: *Heap, start: usize, steps: *u32) Error!void {
        var node = start;
        while (node != 0) : (node /= 2) {
            steps.* += 1;
            if (!self.nodeValid(node, self.nodeOrder(node))) return self.corrupt();
            // Allocated ancestors conceal stale child markers after merging.
            if (node != start and self.tree[node] & allocated != 0) return error.InvalidAllocation;
        }
    }

    fn update(self: *Heap, start: usize, steps: *u32) void {
        var node = start / 2;
        while (node != 0) : (node /= 2) {
            steps.* += 1;
            self.tree[node] = self.join(node, self.nodeOrder(node));
        }
    }

    fn corrupt(self: *Heap) Error {
        self.faulted = true;
        return error.Corrupt;
    }

    fn guardByte(self: *const Heap, index: usize) u8 {
        return @as(u8, @intCast(index)) ^ @as(u8, @intCast(self.owner)) ^ 0x6b;
    }

    pub fn guardsValid(self: *const Heap) bool {
        const bytes: [*]const volatile u8 = self.memory.ptr;
        for (0..granule) |index| if (bytes[index] != self.guardByte(index) or
            bytes[self.memory.len - granule + index] != self.guardByte(index)) return false;
        return true;
    }
};
