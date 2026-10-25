//! Task-side scalar ABI. These wrappers run only in an active native task.
const control = @import("task_control");
pub const Status = control.Status;
pub const Handle = control.Handle;

extern fn nih_riscv_task_call(number: u32, argument: u32, payload: u32) callconv(.c) u64;
extern fn nih_riscv_task_exit(code: i32) callconv(.c) noreturn;

pub fn raw(number: u32, argument: u32) u64 {
    return nih_riscv_task_call(number, argument, 0);
}

fn status(number: control.Number, argument: u32) i32 {
    return @bitCast(@as(u32, @truncate(raw(@backingInt(number), argument))));
}

pub fn yieldNow() i32 {
    return status(.yield_now, 0);
}
pub fn sleep(ticks: u32) i32 {
    return status(.sleep, ticks);
}
pub fn block() i32 {
    return status(.block, 0);
}
pub fn wake(handle: Handle) i32 {
    return status(.wake, control.encodeHandle(handle));
}
pub fn nowTicks() u64 {
    return raw(@backingInt(control.Number.ticks), 0);
}

pub fn current() ?Handle {
    const value = raw(@backingInt(control.Number.current), 0);
    if (value >> 32 != 0) return null;
    return control.decodeHandle(@truncate(value));
}

pub fn exit(code: i32) noreturn {
    nih_riscv_task_exit(code);
}

pub const EventResult = union(enum) { received: u32, failed: i32 };

pub fn waitEvents(mask: u32) EventResult {
    const value = raw(@backingInt(control.Number.wait_events), mask);
    const low: u32 = @truncate(value);
    return if (value >> 32 == 0) .{ .received = low } else .{ .failed = @bitCast(low) };
}

pub fn notify(handle: Handle, bits: u32) i32 {
    const value = nih_riscv_task_call(@backingInt(control.Number.notify), control.encodeHandle(handle), bits);
    return @bitCast(@as(u32, @truncate(value)));
}

/// Stateless adapter for a channel owned by native tasks on this CPU.
pub const EventPort = struct {
    pub const Handle = control.Handle;

    pub fn post(_: *EventPort, target: control.Handle, bits: u32) i32 {
        return notify(target, bits);
    }

    pub fn wait(_: *EventPort, mask: u32) EventResult {
        return waitEvents(mask);
    }
};
