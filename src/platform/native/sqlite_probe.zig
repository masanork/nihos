//! First actual native SQLite execution: CPU0 bootstrap after the SMP soak.
//! No service task, RPC, file I/O, clock, entropy or hardware timing claim.
const memory = @import("native_tasks").memory;
const Result = extern struct { value: i64, has_value: u32 };
extern fn nih_task_identity() callconv(.c) u32;
extern fn nih_sqlite_session_open() callconv(.c) c_int;
extern fn nih_sqlite_session_eval([*]const u8, usize, *Result) callconv(.c) c_int;
extern fn nih_sqlite_session_close() callconv(.c) c_int;
extern fn nih_sqlite_stack_paint(u32) callconv(.c) u32;
extern var nih_sqlite_open_execution_pc: u32;
extern var nih_sqlite_native_failed_size: u32;
extern var nih_sqlite_native_peak: [10]u32;
extern var __flash_sql_text_start: u8;
extern var __flash_sql_text_end: u8;
extern var __flash_sql_rodata_start: u8;
extern var __flash_sql_rodata_end: u8;
extern fn nih_native_task_failed() callconv(.c) noreturn;
extern fn nih_rom_putc(u8) callconv(.c) i32;
fn fail(step: u32, code: c_int) noreturn {
    for ("NIHOS_SQLITE_DETAIL step=") |c| _ = nih_rom_putc(c);
    for ([_]u32{ step, @bitCast(code), @as(*volatile u32, &nih_sqlite_native_failed_size).* }, 0..) |word, index| {
        if (index != 0) {
            for (if (index == 1) " code=" else " need=") |c| _ = nih_rom_putc(c);
        }
        var shift: u6 = 28;
        while (true) {
            const nibble: u8 = @intCast((word >> @as(u5, @intCast(shift))) & 15);
            _ = nih_rom_putc(if (nibble < 10) '0' + nibble else 'a' + nibble - 10);
            if (shift == 0) break;
            shift -= 4;
        }
    }
    _ = nih_rom_putc('\n');
    nih_native_task_failed();
}
const paint: u32 = 0x5a7ec319;
pub const Report = struct {
    status: u32 = 0,
    owner: u32 = 0,
    sessions: u32 = 0,
    queries: u32 = 0,
    open_pc: u32 = 0,
    text_start: u32 = 0,
    text_end: u32 = 0,
    rodata_start: u32 = 0,
    rodata_end: u32 = 0,
    heap_before: u32 = 0,
    heap_after: u32 = 0,
    stack_low: u32 = 0,
    stack_high: u32 = 0,
    painted_to: u32 = 0,
    observed_used: u32 = 0,
    mie: u32 = 0,
};

fn interrupts() u32 {
    return asm volatile ("csrr %[status], mstatus"
        : [status] "=r" (-> u32),
    ) & 8;
}

pub noinline fn run() linksection(if (@import("native_options").cold_flash) ".flash.text.cold" else ".text") Report {
    var report = Report{
        .text_start = @intFromPtr(&__flash_sql_text_start),
        .text_end = @intFromPtr(&__flash_sql_text_end),
        .rodata_start = @intFromPtr(&__flash_sql_rodata_start),
        .rodata_end = @intFromPtr(&__flash_sql_rodata_end),
    };
    const before = memory.reusable.availableBytes() orelse return report;
    const stack = memory.stacks.layout.bootstrap(0).?;
    report.owner = nih_task_identity();
    if (report.owner == 0 or interrupts() != 8) fail(1, @bitCast(report.owner));
    report.heap_before = @intCast(before);
    report.stack_low = stack.start + memory.stacks.layout.guard_bytes;
    report.stack_high = stack.end;
    report.painted_to = nih_sqlite_stack_paint(report.stack_low);
    if (report.painted_to <= report.stack_low or report.painted_to >= stack.end) fail(2, @bitCast(report.painted_to));
    for (0..2) |_| {
        const opened = nih_sqlite_session_open();
        if (opened != 0) fail(3, opened);
        report.open_pc = @volatileCast(&nih_sqlite_open_execution_pc).*;
        const cases = .{
            .{ "SELECT 6*7", @as(i64, 42), @as(u32, 1) },
            .{ "SELECT CAST(1.5*2 AS INTEGER)", @as(i64, 3), @as(u32, 1) },
            .{ "SELECT -4294967297", @as(i64, -4294967297), @as(u32, 1) },
            .{ "SELECT unixepoch('1970-01-01')", @as(i64, 0), @as(u32, 1) },
            .{ "SELECT unixepoch('2000-02-29')", @as(i64, 951782400), @as(u32, 1) },
            .{ "SELECT unixepoch('2000-02-29','localtime')", @as(i64, 0), @as(u32, 0) },
            .{ "CREATE TABLE t(v INTEGER)", @as(i64, 0), @as(u32, 0) },
            .{ "BEGIN", @as(i64, 0), @as(u32, 0) },
            .{ "INSERT INTO t VALUES(3)", @as(i64, 0), @as(u32, 0) },
            .{ "INSERT INTO t VALUES(7)", @as(i64, 0), @as(u32, 0) },
            .{ "COMMIT", @as(i64, 0), @as(u32, 0) },
            .{ "SELECT sum(v) FROM t", @as(i64, 10), @as(u32, 1) },
            .{ "SELECT count(*) FROM t", @as(i64, 2), @as(u32, 1) },
        };
        inline for (cases) |item| {
            var value = Result{ .value = -1, .has_value = 1 };
            const sql = item[0];
            const rc = nih_sqlite_session_eval(sql, sql.len, &value);
            if (rc != 0) fail(0x100 + report.queries, rc);
            if (value.value != item[1] or value.has_value != item[2]) fail(0x200 + report.queries, @truncate(value.value));
            report.queries += 1;
        }
        const closed = nih_sqlite_session_close();
        if (closed != 0) fail(5, closed);
        if (nih_task_identity() != report.owner) fail(6, @bitCast(nih_task_identity()));
        if (memory.reusable.availableBytes() != before or interrupts() != 8) fail(7, 0);
        report.sessions += 1;
    }
    var first = report.stack_low;
    while (first < report.painted_to) : (first += 4) {
        const word: *const volatile u32 = @ptrFromInt(first);
        if (word.* != paint) break;
    }
    report.observed_used = stack.end - first;
    report.heap_after = @intCast(memory.reusable.availableBytes().?);
    report.mie = interrupts();
    if (first <= report.stack_low or report.open_pc < report.text_start or report.open_pc >= report.text_end or
        report.heap_after != report.heap_before) fail(8, @bitCast(first));
    report.status = 1;
    return report;
}

pub const ClassReport = extern struct {
    c8: u32,
    c16: u32,
    c32: u32,
    c64: u32,
    c128: u32,
    c256: u32,
    c512: u32,
    c1024: u32,
    c2048: u32,
    c4096: u32,
};
pub fn classPeaks() ClassReport {
    const values = @as(*volatile [10]u32, &nih_sqlite_native_peak).*;
    return .{ .c8 = values[0], .c16 = values[1], .c32 = values[2], .c64 = values[3], .c128 = values[4], .c256 = values[5], .c512 = values[6], .c1024 = values[7], .c2048 = values[8], .c4096 = values[9] };
}

pub const SoakReport = struct { loops: u32, sessions: u32, queries: u32, heap_before: u32, heap_after: u32, max_stack: u32, confirmed: u32 };

pub fn soak() SoakReport {
    const before = memory.reusable.availableBytes() orelse fail(0x300, 0);
    var report = SoakReport{ .loops = 0, .sessions = 0, .queries = 0, .heap_before = @intCast(before), .heap_after = 0, .max_stack = 0, .confirmed = 0 };
    for (0..1000) |_| {
        const batch = run();
        if (batch.status != 1 or batch.sessions != 2 or batch.queries != 26 or
            batch.heap_before != before or batch.heap_after != before) fail(0x301, 0);
        report.loops += 1;
        report.sessions += batch.sessions;
        report.queries += batch.queries;
        report.max_stack = @max(report.max_stack, batch.observed_used);
    }
    report.heap_after = @intCast(memory.reusable.availableBytes().?);
    if (report.heap_before != report.heap_after) fail(0x302, 0);
    report.confirmed = 1;
    return report;
}
