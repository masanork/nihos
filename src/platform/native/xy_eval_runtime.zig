//! A guarded foreground stack for Scheme while storage waits pump UI/network.
const tasks = @import("native_tasks");
const console = @import("text_console");
const options = @import("native_options");
const layout = @import("sqld_layout.zig");
extern fn nih_xy_eval_call(*console.scratch.Model, [*]const u8, usize, bool, usize, u32) callconv(.c) void;
extern fn nih_native_task_failed() callconv(.c) noreturn;
inline fn onForegroundCore() bool {
    const hart = asm volatile ("csrr %[hart], mhartid"
        : [hart] "=r" (-> u32),
    );
    return hart == 0;
}
pub export fn nih_xy_evaluate(model: *console.scratch.Model, source: [*]const u8, length: usize, named: bool) linksection(".flash.xytext") void {
    if (!onForegroundCore() or model.vm.running) return;
    evaluateOnForeground(model, source, length, named, false);
}
// Only the foreground service resumes a suspended scratch evaluation.
// Ordinary evaluation must never use an empty named command as a resume token.
pub export fn nih_xy_resume(model: *console.scratch.Model) linksection(".flash.xytext") void {
    if (!onForegroundCore() or !model.vm.running or !model.hasContinuation()) return;
    evaluateOnForeground(model, model.command[0..].ptr, 0, true, true);
}
fn evaluateOnForeground(model: *console.scratch.Model, source: [*]const u8, length: usize, named: bool, resuming: bool) linksection(".flash.xytext") void {
    if (comptime !(@hasDecl(options, "sqld") and options.sqld)) {
        const stack = @import("display_service").ui.xyEvaluationStack() orelse {
            model.evaluationStackUnavailable();
            return;
        };
        const guard: *const [4]u32 = @ptrCast(@alignCast(stack.ptr));
        if (resuming) {
            for (guard) |word| if (word != layout.guard) nih_native_task_failed();
        } else @memset(stack, 0xa5);
        const previous = asm volatile ("csrrci %[v],mstatus,8"
            : [v] "=r" (-> u32),
            :
            : .{ .memory = true });
        if (!tasks.memory.stacks.beginForeground(stack)) {
            if (previous & 8 != 0) asm volatile ("csrsi mstatus,8" ::: .{ .memory = true });
            model.evaluationStackUnavailable();
            return;
        }
        const low: u32 = @intCast(@intFromPtr(stack.ptr));
        const top: u32 = @intCast(@intFromPtr(stack.ptr) + stack.len);
        const original = tasks.beginForegroundStack(low + 256, top) orelse {
            tasks.memory.stacks.endForeground();
            if (previous & 8 != 0) asm volatile ("csrsi mstatus,8" ::: .{ .memory = true });
            model.evaluationStackUnavailable();
            return;
        };
        nih_xy_eval_call(model, source, length, named, top, previous & 8);
        if (!tasks.endForegroundStack(original)) nih_native_task_failed();
        tasks.memory.stacks.endForeground();
        if (previous & 8 != 0) asm volatile ("csrsi mstatus,8" ::: .{ .memory = true });
        for (guard) |word| if (word != layout.guard) nih_native_task_failed();
        return;
    }
    const low = layout.eval_stack;
    const top = low + layout.eval_stack_bytes;
    const guard: *[4]u32 = @ptrFromInt(low);
    if (resuming) {
        for (guard) |word| if (word != layout.guard) nih_native_task_failed();
    } else @memset(guard, layout.guard);
    const previous = asm volatile ("csrrci %[v],mstatus,8"
        : [v] "=r" (-> u32),
        :
        : .{ .memory = true });
    const original = tasks.beginForegroundStack(low + 256, top) orelse nih_native_task_failed();
    nih_xy_eval_call(model, source, length, named, top, previous & 8);
    if (!tasks.endForegroundStack(original)) nih_native_task_failed();
    if (previous & 8 != 0) asm volatile ("csrsi mstatus,8" ::: .{ .memory = true });
    for (guard) |word| if (word != layout.guard) nih_native_task_failed();
}
pub export fn nih_xy_eval_on_stack(model: *console.scratch.Model, source: [*]const u8, length: usize, named: bool) linksection(".flash.xytext") callconv(.c) void {
    if (!onForegroundCore()) return;
    if (named and length == 0 and model.hasContinuation()) {
        model.continuationTick();
        return;
    }
    model.evaluateOnStack(source[0..length], named);
}
