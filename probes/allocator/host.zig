//! Host oracle for the same C boundary; no hardware or native timing claims.
const buddy = @import("buddy_heap");
const resources = @import("task_resources");
const Table = resources.Resources(buddy, 2, 2);
const Object = resources.size_pool.Allocation;
// SAFETY: Initialized by the buddy/pool constructors before any payload is read.
var memory: [4 * 1024 * 1024]u8 align(64) = undefined;
// SAFETY: Assigned before initialized is set; every backend entry checks it.
var heap: buddy.Heap = undefined;
var table: Table = .{};
var bindings: [2]?Table.Objects = .{ null, null };
var generations: [2]u16 = .{ 1, 1 };
threadlocal var slot: u16 = 0;
var initialized = false;

fn key() resources.Key {
    return .{ .slot = slot, .generation = generations[slot] };
}

fn ensure() void {
    if (initialized) return;
    heap = buddy.Heap.init(&memory, 0).?;
    _ = table.open(.{ .slot = 0, .generation = 1 });
    _ = table.open(.{ .slot = 1, .generation = 1 });
    initialized = true;
}

const Backend = struct {
    fn pool() !Table.Objects {
        if (!initialized or !table.active(key())) return error.Inactive;
        return bindings[slot] orelse error.NotReady;
    }

    pub fn identity() !u32 {
        ensure();
        if (!table.active(key())) return error.Inactive;
        return resources.identity(0, key());
    }

    pub fn open(count: usize) !void {
        return openConfigured(resources.size_pool.Config.uniform(count) orelse return error.InvalidRequest);
    }

    pub fn openConfigured(config: resources.size_pool.Config) !void {
        ensure();
        if (bindings[slot] != null) return error.Full;
        const lease = try table.reserveConfiguredObjects(&heap, 0, key(), config);
        errdefer table.closeObjects(&heap, 0, key(), lease) catch @panic("host allocator rollback failed");
        try (try table.prepareObjects(0, key(), lease)).initialize();
        try table.publishObjects(0, key(), lease);
        bindings[slot] = lease;
    }

    pub fn close() !void {
        try table.closeObjects(&heap, 0, key(), try pool());
        bindings[slot] = null;
    }

    pub fn release(address: usize) !void {
        const lease = try pool();
        try table.freeObject(0, key(), lease, try table.objectFromPointer(0, key(), lease, address));
    }

    pub fn capacity(address: usize) !usize {
        const lease = try pool();
        return table.objectCapacity(0, key(), lease, try table.objectFromPointer(0, key(), lease, address));
    }

    pub fn resize(address: ?usize, length: usize) !?Object {
        const lease = try pool();
        const old = if (address) |a| try table.objectFromPointer(0, key(), lease, a) else null;
        switch (try table.beginObjectResize(0, key(), lease, old, length)) {
            .done => |object| return object,
            .move => |plan| {
                @memcpy(plan.next.cell.bytes[0..plan.old.cell.bytes.len], plan.old.cell.bytes);
                return try table.commitObjectResize(0, key(), lease, plan);
            },
        }
    }
};
comptime {
    resources.c_allocator.Adapter(Backend).exportSymbols();
}

export fn nih_host_select(next: u16) c_int {
    if (next >= bindings.len) return -1;
    slot = next;
    return 0;
}

export fn nih_host_retire() c_int {
    if (!initialized or !table.close(key())) return -1;
    bindings[slot] = null;
    while (!(table.drainOne(&heap, 0, key()) catch return -1)) {}
    generations[slot] += 1;
    if (!table.open(key())) return -1;
    return 0;
}

export fn nih_host_recovered() c_int {
    return @intFromBool(initialized and heap.free_bytes == heap.payload.len and table.owned() == 0);
}

export fn nih_host_parent_bytes() usize {
    const lease = bindings[slot] orelse return 0;
    return lease.allocation.bytes.len;
}

export fn nih_host_reserved_bytes() usize {
    return if (initialized) heap.payload.len - heap.free_bytes else 0;
}
