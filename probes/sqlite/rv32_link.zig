//! Link/host oracle only: one fixed context, not the native scheduler or PSRAM.
const std = @import("std");
const buddy = @import("buddy_heap");
const resources = @import("task_resources");
const Table = resources.Resources(buddy, 1, 1);
const Object = resources.size_pool.Allocation;
const key = resources.Key{ .slot = 0, .generation = 1 };
// SAFETY: Heap construction and pool publication initialize metadata before use.
var memory: [262144]u8 align(64) = undefined;
// SAFETY: Initialized by ensure before any backend operation reads the heap.
var heap: buddy.Heap = undefined;
var table: Table = .{};
var binding: ?Table.Objects = null;
var initialized = false;

fn ensure() void {
    if (initialized) return;
    heap = buddy.Heap.init(&memory, 0).?;
    if (!table.open(key)) @panic("link oracle task init");
    initialized = true;
}

const Backend = struct {
    pub fn identity() !u32 {
        ensure();
        return resources.identity(0, key);
    }
    fn pool() !Table.Objects {
        if (!initialized or !table.active(key)) return error.Inactive;
        return binding orelse error.NotReady;
    }
    pub fn open(count: usize) !void {
        return openConfigured(resources.size_pool.Config.uniform(count) orelse return error.InvalidRequest);
    }
    pub fn openConfigured(config: resources.size_pool.Config) !void {
        ensure();
        if (binding != null) return error.Full;
        const lease = try table.reserveConfiguredObjects(&heap, 0, key, config);
        errdefer table.closeObjects(&heap, 0, key, lease) catch @panic("link oracle rollback");
        try (try table.prepareObjects(0, key, lease)).initialize();
        try table.publishObjects(0, key, lease);
        binding = lease;
    }
    pub fn close() !void {
        try table.closeObjects(&heap, 0, key, try pool());
        binding = null;
    }
    pub fn release(address: usize) !void {
        const lease = try pool();
        try table.freeObject(0, key, lease, try table.objectFromPointer(0, key, lease, address));
    }
    pub fn capacity(address: usize) !usize {
        const lease = try pool();
        return table.objectCapacity(0, key, lease, try table.objectFromPointer(0, key, lease, address));
    }
    pub fn resize(address: ?usize, length: usize) !?Object {
        const lease = try pool();
        const old = if (address) |a| try table.objectFromPointer(0, key, lease, a) else null;
        switch (try table.beginObjectResize(0, key, lease, old, length)) {
            .done => |object| return object,
            .move => |plan| {
                @memcpy(plan.next.cell.bytes[0..plan.old.cell.bytes.len], plan.old.cell.bytes);
                return try table.commitObjectResize(0, key, lease, plan);
            },
        }
    }
};
comptime {
    resources.c_allocator.Adapter(Backend).exportSymbols();
}
const Result = extern struct { value: i64, has_value: u32 };
comptime {
    if (@sizeOf(Result) != 16 or @offsetOf(Result, "has_value") != 8) @compileError("scalar C result ABI");
}
extern fn nih_sqlite_session_open() callconv(.c) c_int;
extern fn nih_sqlite_session_eval([*]const u8, usize, *Result) callconv(.c) c_int;
extern fn nih_sqlite_session_close() callconv(.c) c_int;

/// This entry returns to its caller; the standalone ELF has no boot/CRT setup.
export fn nih_sqlite_link_probe() c_int {
    const opened = nih_sqlite_session_open();
    if (opened != 0) return opened;
    const outcome: c_int = blk: {
        const cases = .{
            .{ "SELECT 6*7", @as(i64, 42), @as(u32, 1) },
            .{ "SELECT CAST(1.5*2 AS INTEGER)", @as(i64, 3), @as(u32, 1) },
            .{ "SELECT unixepoch('1970-01-01')", @as(i64, 0), @as(u32, 1) },
            .{ "SELECT unixepoch('2000-02-29')", @as(i64, 951782400), @as(u32, 1) },
            .{ "SELECT unixepoch('2000-02-29','localtime')", @as(i64, 0), @as(u32, 0) },
        };
        inline for (cases) |item| {
            var result = Result{ .value = -1, .has_value = 1 };
            const sql = item[0];
            const rc = nih_sqlite_session_eval(sql, sql.len, &result);
            if (rc != 0) break :blk rc;
            if (result.value != item[1] or result.has_value != item[2]) break :blk -20;
        }
        break :blk 0;
    };
    const closed = nih_sqlite_session_close();
    if (outcome != 0) return outcome;
    if (closed != 0) return closed;
    if (binding != null or table.owned() != 0 or heap.free_bytes != heap.payload.len) return -21;
    return 0;
}

pub const panic = std.debug.no_panic;
