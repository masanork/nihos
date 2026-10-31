//! A guarded foreground stack for Scheme while storage waits pump UI/network.
const tasks = @import("native_tasks");
const console = @import("text_console");
const options = @import("native_options");
const layout = @import("sqld_layout.zig");
extern fn nih_xy_eval_call(*console.scratch.Model, [*]const u8, usize, bool, usize, u32) callconv(.c) void;
extern fn nih_native_task_failed() callconv(.c) noreturn;
pub export fn nih_xy_evaluate(model: *console.scratch.Model, source: [*]const u8, length: usize, named: bool) linksection(".flash.xytext") void {
    if (comptime !(@hasDecl(options, "sqld") and options.sqld)) return model.evaluateOnStack(source[0..length], named);
    if (model.vm.running) return;
    const low = layout.eval_stack;
    const top = low + 65536;
    const bytes: [*]u8 = @ptrFromInt(low);
    @memset(bytes[0..65536], 0xa5);
    const previous = asm volatile ("csrrci %[v],mstatus,8"
        : [v] "=r" (-> u32),
        :
        : .{ .memory = true });
    const original = tasks.beginForegroundStack(low + 256, top) orelse nih_native_task_failed();
    nih_xy_eval_call(model, source, length, named, top, previous & 8);
    if (!tasks.endForegroundStack(original)) nih_native_task_failed();
    if (previous & 8 != 0) asm volatile ("csrsi mstatus,8" ::: .{ .memory = true });
    const guard: *const [4]u32 = @ptrFromInt(low);
    for (guard) |word| if (word != layout.guard) nih_native_task_failed();
}
pub export fn nih_xy_eval_on_stack(model: *console.scratch.Model, source: [*]const u8, length: usize, named: bool) linksection(".flash.xytext") callconv(.c) void {
    model.evaluateOnStack(source[0..length], named);
}
