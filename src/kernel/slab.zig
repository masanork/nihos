//! Fixed-size cells inside one owned parent. Caller serializes operations.
//! Metadata is in the parent; payloads are neither initialized nor scanned.
const std = @import("std");
pub const alignment: usize = 8;
pub const max_cells: usize = 65535;
const magic: u32 = 0x736c6162;
const allocated: u32 = 1 << 31;
const Header = extern struct { serial: u64, epoch: u64, head: u32, live: u32, cookie: u32, faulted: u32 };
const Cell = extern struct { ticket: u64, next: u32, cookie: u32 };
pub const header_bytes = @sizeOf(Header);
pub const cell_metadata_bytes = @sizeOf(Cell);
pub const Allocation = struct { bytes: []u8, ticket: u64, epoch: u64, index: u32 };
pub const Error = error{ InvalidRequest, OutOfMemory, InvalidAllocation, Corrupt, Faulted, SerialExhausted };

fn strideFor(object_bytes: usize) ?usize {
    if (object_bytes == 0 or object_bytes > 65536) return null;
    return (cell_metadata_bytes + object_bytes + alignment - 1) & ~(alignment - 1);
}

pub fn requiredBytes(object_bytes: usize, count: usize) ?usize {
    const stride = strideFor(object_bytes) orelse return null;
    if (count == 0 or count > max_cells) return null;
    const body = @mulWithOverflow(stride, count);
    const total = @addWithOverflow(body[0], header_bytes);
    return if (body[1] == 0 and total[1] == 0) total[0] else null;
}

pub const View = struct {
    memory: []u8,
    object_bytes: usize,
    count: u32,
    stride: usize,
    epoch: u64,

    /// Geometry comes from the tracked parent and its SRAM cell-size tag,
    /// never from untrusted words in the parent payload.
    pub noinline fn from(memory: []u8, object_bytes: usize, epoch: u64) ?View {
        const stride = strideFor(object_bytes) orelse return null;
        if (epoch == 0 or @intFromPtr(memory.ptr) % alignment != 0 or memory.len <= header_bytes or
            @addWithOverflow(@intFromPtr(memory.ptr), memory.len)[1] != 0) return null;
        const count = (memory.len - header_bytes) / stride;
        if (requiredBytes(object_bytes, count) != memory.len) return null;
        return .{ .memory = memory, .object_bytes = object_bytes, .count = @intCast(count), .stride = stride, .epoch = epoch };
    }

    fn header(self: View) *Header {
        return @ptrCast(@alignCast(self.memory.ptr));
    }

    fn cell(self: View, index: u32) *Cell {
        return @ptrCast(@alignCast(self.memory.ptr + header_bytes + @as(usize, index) * self.stride));
    }

    fn payload(self: View, index: u32) []u8 {
        const start = header_bytes + @as(usize, index) * self.stride + cell_metadata_bytes;
        return self.memory[start..][0..self.object_bytes];
    }

    fn fold(ticket: u64) u32 {
        return @as(u32, @truncate(ticket)) ^ @as(u32, @truncate(ticket >> 32));
    }

    fn headerCookie(self: View) u32 {
        const h = self.header();
        return magic ^ fold(self.epoch) ^ fold(h.serial) ^ h.head ^ h.live ^ self.count ^ @as(u32, @intCast(self.object_bytes));
    }

    fn cellCookie(self: View, index: u32, c: *const Cell) u32 {
        return magic ^ fold(self.epoch) ^ index ^ self.count ^ @as(u32, @intCast(self.object_bytes)) ^ fold(c.ticket) ^ c.next;
    }

    /// Linear initialization is deliberately separate from publication and
    /// from the bounded operations. Native callers leave interrupts enabled.
    /// Initialize exactly once per parent epoch; a raw View borrows its span.
    pub noinline fn initialize(self: View) void {
        self.header().* = .{ .serial = 0, .epoch = 0, .head = 0, .live = 0, .cookie = 0, .faulted = 0 };
        for (0..self.count) |index| {
            const c = self.cell(@intCast(index));
            c.* = .{ .ticket = 0, .next = @intCast(index + 1), .cookie = 0 };
            c.cookie = self.cellCookie(@intCast(index), c);
        }
        self.header().epoch = self.epoch;
        self.header().cookie = self.headerCookie();
    }

    fn corrupt(self: View) Error {
        self.header().faulted = 1;
        return error.Corrupt;
    }

    noinline fn checkedHeader(self: View) Error!*Header {
        const h = self.header();
        if (h.faulted != 0) return error.Faulted;
        if (h.epoch != self.epoch or h.cookie != self.headerCookie() or
            h.head > self.count or h.live > self.count or ((h.head == self.count) != (h.live == self.count))) return self.corrupt();
        return h;
    }

    pub fn ready(self: View) Error!void {
        _ = try self.checkedHeader();
    }

    noinline fn freeHead(self: View, index: u32) Error!*Cell {
        if (index >= self.count) return self.corrupt();
        const c = self.cell(index);
        if (c.next > self.count or c.next == index or c.cookie != self.cellCookie(index, c)) return self.corrupt();
        return c;
    }

    pub noinline fn alloc(self: View) Error!Allocation {
        return self.allocSized(self.object_bytes);
    }

    /// Sized users retain the same cell capacity but authenticate the exact
    /// exposed length in metadata. Fixed-size slab callers use alloc().
    pub noinline fn allocSized(self: View, length: usize) Error!Allocation {
        if (length == 0 or length > self.object_bytes) return error.InvalidRequest;
        const h = try self.checkedHeader();
        if (h.head == self.count) return error.OutOfMemory;
        if (h.serial == std.math.maxInt(u64)) return error.SerialExhausted;
        const index = h.head;
        const c = try self.freeHead(index);
        if (c.next != self.count) {
            const next = try self.freeHead(c.next);
            if (next.next == index) return self.corrupt();
        }
        h.serial += 1;
        h.head = c.next;
        h.live += 1;
        c.ticket = h.serial;
        c.next = allocated | @as(u32, @intCast(length));
        c.cookie = self.cellCookie(index, c);
        h.cookie = self.headerCookie();
        return .{ .bytes = self.payload(index)[0..length], .ticket = c.ticket, .epoch = self.epoch, .index = index };
    }

    fn liveCell(self: View, allocation: Allocation) Error!*Cell {
        if (allocation.epoch != self.epoch or allocation.index >= self.count) return error.InvalidAllocation;
        const c = self.cell(allocation.index);
        const bytes = self.payload(allocation.index);
        const length = c.next & ~allocated;
        if (c.next & allocated == 0 or length == 0 or length > self.object_bytes or
            c.ticket != allocation.ticket or allocation.ticket == 0 or
            allocation.bytes.ptr != bytes.ptr or allocation.bytes.len != length) return error.InvalidAllocation;
        if (c.cookie != self.cellCookie(allocation.index, c)) return self.corrupt();
        return c;
    }

    pub fn validate(self: View, allocation: Allocation) Error!void {
        _ = try self.checkedHeader();
        _ = try self.liveCell(allocation);
    }

    /// Transfer the same cell to a new length/ticket without copying data.
    /// Old operation handles become stale even when the address is unchanged.
    pub noinline fn renew(self: View, allocation: Allocation, length: usize) Error!Allocation {
        if (length == 0 or length > self.object_bytes) return error.InvalidRequest;
        const h = try self.checkedHeader();
        const c = try self.liveCell(allocation);
        if (h.serial == std.math.maxInt(u64)) return error.SerialExhausted;
        h.serial += 1;
        c.ticket = h.serial;
        c.next = allocated | @as(u32, @intCast(length));
        c.cookie = self.cellCookie(allocation.index, c);
        h.cookie = self.headerCookie();
        return .{ .bytes = self.payload(allocation.index)[0..length], .ticket = c.ticket, .epoch = self.epoch, .index = allocation.index };
    }

    pub noinline fn free(self: View, allocation: Allocation) Error!void {
        const h = try self.checkedHeader();
        const c = try self.liveCell(allocation);
        if (h.live == 0) return self.corrupt();
        if (h.head != self.count) _ = try self.freeHead(h.head);
        c.next = h.head;
        c.cookie = self.cellCookie(allocation.index, c);
        h.head = allocation.index;
        h.live -= 1;
        h.cookie = self.headerCookie();
    }
};

test "slab serial exhaustion and corrupt header fail before consuming a cell" {
    var memory: [224]u8 align(8) = undefined;
    const view = View.from(&memory, 32, 1).?;
    view.initialize();
    view.header().serial = std.math.maxInt(u64);
    view.header().cookie = view.headerCookie();
    try std.testing.expectError(error.SerialExhausted, view.alloc());
    try std.testing.expectEqual(@as(u32, 0), view.header().live);
    view.header().head = view.count + 1;
    view.header().cookie = view.headerCookie();
    try std.testing.expectError(error.Corrupt, view.alloc());
    try std.testing.expectError(error.Faulted, view.alloc());
}

test "slab in-place renewal exhaustion preserves live length ticket and data" {
    var memory: [224]u8 align(8) = undefined;
    const view = View.from(&memory, 32, 1).?;
    view.initialize();
    const old = try view.allocSized(13);
    @memset(old.bytes, 0x34);
    view.header().serial = std.math.maxInt(u64);
    view.header().cookie = view.headerCookie();
    try std.testing.expectError(error.SerialExhausted, view.renew(old, 20));
    try view.validate(old);
    try std.testing.expectEqual(@as(u32, 1), view.header().live);
    for (old.bytes) |byte| try std.testing.expectEqual(@as(u8, 0x34), byte);
    try view.free(old);
}

test "slab free-list corruption is bounded and poisons further operations" {
    var memory: [224]u8 align(8) = undefined;
    const view = View.from(&memory, 32, 1).?;
    view.initialize();
    view.cell(0).next = view.count + 1;
    view.cell(0).cookie = view.cellCookie(0, view.cell(0));
    try std.testing.expectError(error.Corrupt, view.alloc());
    try std.testing.expectError(error.Faulted, view.alloc());
    view.initialize();
    view.cell(1).next = 0;
    view.cell(1).cookie = view.cellCookie(1, view.cell(1));
    try std.testing.expectError(error.Corrupt, view.alloc());
}

test "full parent epoch and allocated-cell consistency failures are fail-stop" {
    var memory: [224]u8 align(8) = undefined;
    const view = View.from(&memory, 32, 1).?;
    view.initialize();
    view.header().epoch ^= @as(u64, 1) << 32;
    try std.testing.expectError(error.Corrupt, view.ready());
    view.initialize();
    const cell = try view.alloc();
    view.cell(cell.index).cookie ^= 1;
    try std.testing.expectError(error.Corrupt, view.free(cell));
    try std.testing.expectError(error.Faulted, view.alloc());
}
