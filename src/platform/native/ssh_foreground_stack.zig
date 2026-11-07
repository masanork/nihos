//! Exclusive CPU0 SSH foreground stack in the boot-admitted PSRAM reservation.
//! This is synchronous, not a worker task and not an entropy source.
const std = @import("std");
const tasks = @import("native_tasks");
const region = @import("sqld_layout.zig");
const owner = @import("ssh_foreground.zig");
const ssh = @import("ssh_workspace");

const Call = struct { runtime: *owner.Runtime, model: ?*ssh.Model, ui: *ssh.Ui, now: u64 };
extern fn nih_ssh_foreground_stack_call(*const Call, usize, u32) callconv(.c) void;
extern fn nih_native_task_failed() callconv(.c) noreturn;

/// Called only after sqld's boot reservation has been admitted and bound.
pub noinline fn poll(runtime: *owner.Runtime, model: ?*ssh.Model, ui: *ssh.Ui, now: u64) void {
    if (comptime !owner.qualified) return;
    const visible = if (model) |current| current.nav.screen == .ssh else false;
    if (!runtime.active and !visible) return;
    comptime {
        if (region.ssh_stack_bytes != tasks.memory.stacks.ssh_bytes or region.ssh_stack % 16 != 0)
            @compileError("SSH stack reservation differs from the foreground stack contract");
    }
    const stack: []u8 = @as([*]u8, @ptrFromInt(region.ssh_stack))[0..region.ssh_stack_bytes];
    const previous = asm volatile ("csrrci %[v],mstatus,8"
        : [v] "=r" (-> u32),
        :
        : .{ .memory = true });
    if (previous & 8 == 0) return;
    if (!tasks.memory.stacks.beginForeground(stack)) {
        asm volatile ("csrsi mstatus,8" ::: .{ .memory = true });
        return;
    }
    const guard: *[4]u32 = @ptrCast(@alignCast(stack.ptr));
    @memset(guard, region.guard);
    const low: u32 = @intCast(@intFromPtr(stack.ptr));
    const top: u32 = @intCast(@intFromPtr(stack.ptr) + stack.len);
    const original = tasks.beginForegroundStack(low + 256, top) orelse {
        tasks.memory.stacks.endForeground();
        asm volatile ("csrsi mstatus,8" ::: .{ .memory = true });
        return;
    };
    const call = Call{ .runtime = runtime, .model = model, .ui = ui, .now = now };
    nih_ssh_foreground_stack_call(&call, top, previous & 8);
    if (!tasks.endForegroundStack(original)) nih_native_task_failed();
    for (guard) |word| if (word != region.guard) nih_native_task_failed();
    // The scheduler image now describes the restored boot stack. Keep the
    // foreground reservation through the wipe, but allow interrupts while
    // clearing PSRAM so another visit cannot reuse partially erased memory.
    asm volatile ("csrsi mstatus,8" ::: .{ .memory = true });
    std.crypto.secureZero(u8, stack[16..]);
    tasks.memory.stacks.endForeground();
}

comptime {
    if (owner.qualified) @export(&onStack, .{ .name = "nih_ssh_foreground_on_stack" });
}
fn onStack(call: *const Call) linksection(".flash.xytext") callconv(.c) void {
    if (comptime !owner.qualified) return;
    call.runtime.poll(call.model, call.ui, call.now);
}
