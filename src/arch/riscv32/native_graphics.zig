//! Opt-in native font fixture. The real scheduler identity owns every extent.
const options = @import("native_options");
const memory = @import("native_memory");
const heap = memory.reusable;
const context = @import("context.zig");
pub const exchange = @import("native_font_exchange.zig");
extern fn graphics_font_link_probe(*const Inputs) callconv(.c) c_int;
extern var graphics_result: FontResult;
extern var graphics_output: @import("font_protocol").Output;
extern var graphics_execution_pc: u32;
extern var __graphics_font_stack_bottom: u8;
extern var __graphics_font_stack_top: u8;
extern var nih_graphics_gothic_start: u8;
extern var nih_graphics_gothic_end: u8;
extern var nih_graphics_mincho_start: u8;
extern var nih_graphics_mincho_end: u8;
extern fn nih_native_task_failed() callconv(.c) noreturn;
const Inputs = extern struct { fonts: [2][*]const u8, lengths: [2]u32, heap: ?[*]u8 = null, heap_bytes: u32 = 0, load_mode: u32 = 1 };
pub const FontResult = extern struct {
    magic: u32,
    stage: u32,
    failure: u32,
    runs: u32,
    hashes: [16]u32,
    pool_peak: u32,
    raw_peak: u32,
    retained: u32,
    largest_extent: u32,
    unavailable_calls: u32,
    runtime_malloc_calls: u32,
    controller_bytes: u32,
    record_capacity: u32,
    record_peak: u32,
    record_failures: u32,
    allocation_failures: u32,
};
pub const Report = struct {
    status: u32 = 0,
    owner: u32 = 0,
    runs: u32 = 0,
    library_pc: u32 = 0,
    heap_before: u32 = 0,
    heap_after: u32 = 0,
    raw_peak: u32 = 0,
    retained: u32 = 0,
    stack_low: u32 = 0,
    stack_high: u32 = 0,
    observed_used: u32 = 0,
    captures: u32 = 0,
    render_captures: u32 = 0,
    bootstrap_progress: u32 = 0,
    record_peak: u32 = 0,
    controller_bytes: u32 = 0,
    allocations: u32 = 0,
    releases: u32 = 0,
    foreign_rejected: u32 = 0,
    irq_rejected: u32 = 0,
    forged_rejected: u32 = 0,
    client_cycles: u32 = 0,
    idle_retained: u32 = 0,
    idle_captures: u32 = 0,
    idle_progress: u32 = 0,
};
var report_state: Report = .{};
var group: ?heap.Group = null;
var initialized = false;
var used: usize = 0;
var peak: usize = 0;
var largest: usize = 0;
var min_frame: u32 = 0;

pub fn bottom() u32 {
    return @intFromPtr(&__graphics_font_stack_bottom);
}
pub fn top() u32 {
    return @intFromPtr(&__graphics_font_stack_top);
}
pub fn guardsValid() bool {
    if (!options.graphics or report_state.stack_low == 0) return true;
    const words: *const volatile [4]u32 = @ptrFromInt(bottom());
    for (words) |word| if (word != 0x67726166) return false;
    return true;
}
pub fn ownsFrame(frame: u32, saved_sp: u32) bool {
    return report_state.stack_low != 0 and frame % 16 == 0 and frame >= bottom() + 16 and
        frame <= top() - context.integer_context_size and saved_sp == frame + context.integer_context_size and guardsValid();
}
pub fn prepare() bool {
    if (report_state.stack_low != 0 or top() - bottom() != 32768) return false;
    const words: [*]volatile u32 = @ptrFromInt(bottom());
    for (0..32768 / 4) |index| words[index] = 0x67726166;
    report_state.stack_low = bottom() + 16;
    report_state.stack_high = top();
    report_state.heap_before = @intCast(heap.availableBytes() orelse return false);
    return true;
}
pub fn capture(frame: *const context.IntegerContext, timer: bool) void {
    const address = @intFromPtr(frame);
    if (!ownsFrame(address, frame.sp)) nih_native_task_failed();
    if (min_frame == 0 or address < min_frame) min_frame = address;
    if (timer) {
        report_state.captures += 1;
        const stage = @as(*const volatile u32, &graphics_result.stage).*;
        if (stage >= 10 and stage < 26) report_state.render_captures += 1;
        if (stage == 50) report_state.idle_captures += 1;
    }
    if (initialized) {
        if (backingAcquire(65536) != null or backingRelease(@ptrFromInt(1)) != -1) nih_native_task_failed();
        report_state.irq_rejected += 1;
    }
}
pub fn progress() void {
    report_state.bootstrap_progress += 1;
    if (@as(*const volatile u32, &graphics_result.stage).* == 50) report_state.idle_progress += 1;
    if (initialized) {
        const before = heap.availableBytes() orelse nih_native_task_failed();
        if (backingAcquire(65536) != null or backingRelease(@ptrFromInt(1)) != -1 or heap.availableBytes() != before) nih_native_task_failed();
        report_state.foreign_rejected += 1;
    }
}
// Client memory is gone; only service-owned HB state crosses this wait.
fn nextRequest(completed: u32, retained: u32, job: *@import("font_protocol").Job) callconv(.c) u32 {
    if (!caller() or completed > 9 or (completed != 0 and completed != report_state.client_cycles + 1) or
        retained == 0 or (report_state.idle_retained != 0 and retained != report_state.idle_retained)) nih_native_task_failed();
    report_state.client_cycles = completed;
    report_state.idle_retained = retained;
    const request = exchange.next(completed, retained, graphics_result.hashes, graphics_result.runs, job, &graphics_output);
    if (!caller() or heap.availableBytes() != report_state.heap_before - retained - exchange.raster.liveCharge()) nih_native_task_failed();
    return request;
}
pub fn entry(_: u32) callconv(.c) i32 {
    const inputs = Inputs{
        .fonts = .{ @ptrCast(&nih_graphics_gothic_start), @ptrCast(&nih_graphics_mincho_start) },
        .lengths = .{ @intFromPtr(&nih_graphics_gothic_end) - @intFromPtr(&nih_graphics_gothic_start), @intFromPtr(&nih_graphics_mincho_end) - @intFromPtr(&nih_graphics_mincho_start) },
    };
    const rc = graphics_font_link_probe(&inputs);
    report_state.library_pc = @as(*const volatile u32, &graphics_execution_pc).*;
    if (rc != 0 or graphics_result.stage != 100 or graphics_result.runs != 16 or graphics_result.failure != 0 or
        graphics_result.runtime_malloc_calls != 0 or graphics_result.unavailable_calls != 0 or !guardsValid()) nih_native_task_failed();
    report_state.runs = graphics_result.runs;
    report_state.raw_peak = graphics_result.raw_peak;
    report_state.retained = graphics_result.retained;
    report_state.record_peak = graphics_result.record_peak;
    report_state.controller_bytes = graphics_result.controller_bytes;
    // Pattern scanning observes modified words; trap samples cover saved frames.
    var first = bottom() + 16;
    while (first < top()) : (first += 4) if (@as(*const volatile u32, @ptrFromInt(first)).* != 0x67726166) break;
    if (min_frame != 0) first = @min(first, min_frame);
    report_state.observed_used = top() - first;
    report_state.status = 1;
    const before = heap.availableBytes() orelse nih_native_task_failed();
    if (backingRelease(@ptrFromInt(1)) != -1 or heap.availableBytes() != before) nih_native_task_failed();
    report_state.forged_rejected = 1;
    return 0;
}
pub fn finish() ?Report {
    report_state.heap_after = @intCast(heap.availableBytes() orelse return null);
    if (report_state.status != 1 or report_state.heap_after != report_state.heap_before or
        report_state.captures == 0 or report_state.render_captures == 0 or report_state.bootstrap_progress == 0 or
        report_state.foreign_rejected == 0 or report_state.irq_rejected == 0 or report_state.forged_rejected != 1 or report_state.client_cycles != 9 or
        report_state.idle_retained != report_state.retained or report_state.idle_progress < 10 or
        !exchange.finished() or !guardsValid()) return null;
    return report_state;
}
pub fn hashes() [16]u32 {
    return graphics_result.hashes;
}
fn caller() bool {
    return initialized and (heap.currentIdentity() catch return false) == report_state.owner;
}
fn backingInit(pointer: ?[*]u8, bytes: usize) callconv(.c) c_int {
    if (initialized or pointer != null or bytes != 0) return -1;
    report_state.owner = heap.currentIdentity() catch return -1;
    initialized = true;
    return 0;
}
fn backingAcquire(raw: usize) callconv(.c) ?*anyopaque {
    if (!caller()) return null;
    var charge: usize = 0;
    const pointer = heap.acquireExtent(&group, raw, &charge) catch return null;
    used += charge;
    peak = @max(peak, used);
    largest = @max(largest, raw);
    report_state.allocations += 1;
    return @ptrCast(pointer);
}
fn backingRelease(pointer: ?*anyopaque) callconv(.c) c_int {
    if (pointer == null) return 0;
    if (!caller()) return -1;
    const charge = heap.releaseExtent(&group, @intFromPtr(pointer.?)) catch return -1;
    used -= charge;
    report_state.releases += 1;
    return 0;
}
fn rawUsed() callconv(.c) usize {
    return used;
}
fn rawPeak() callconv(.c) usize {
    return peak;
}
fn maxExtent() callconv(.c) usize {
    return largest;
}
comptime {
    if (options.graphics) {
        @export(&nextRequest, .{ .name = "nih_graphics_next_request" });
        @export(&backingInit, .{ .name = "nih_graphics_backing_init" });
        @export(&backingAcquire, .{ .name = "nih_graphics_backing_acquire" });
        @export(&backingRelease, .{ .name = "nih_graphics_backing_release" });
        @export(&rawUsed, .{ .name = "nih_graphics_backing_raw_used" });
        @export(&rawPeak, .{ .name = "nih_graphics_backing_raw_peak" });
        @export(&maxExtent, .{ .name = "nih_graphics_backing_largest_extent" });
    }
}
