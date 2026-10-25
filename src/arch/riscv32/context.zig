//! ESP32-P4/RV32 saved-context layouts.
//!
//! `IntegerContext` is the 128-byte frame consumed by the normal interrupt
//! return path. `ExceptionContext` adds diagnostic CSRs used by a fault path.
//! Floating-point state is deliberately separate so an integer-only task does
//! not pay 132 bytes or 33 stores on every switch.

const std = @import("std");

pub const stack_alignment: u32 = 16;
pub const integer_context_size: u32 = 128;
pub const exception_context_size: u32 = 148;
pub const exception_storage_size: u32 = 160;
pub const floating_context_size: u32 = 132;

/// Captured CSR state, separate from the stable integer-frame ABI. mstatus
/// follows the selected task; returningFrom supplies the active trap's CLIC
/// mcause before publication to assembly. Native traps do not nest.
pub const ReturnState = extern struct {
    mstatus: u32,
    mcause: u32,

    pub fn integerOnly(self: ReturnState) ReturnState {
        const interrupt_enable: u32 = 1 << 3;
        const floating_state: u32 = 3 << 13;
        return .{
            .mstatus = self.mstatus & ~(interrupt_enable | floating_state),
            .mcause = self.mcause,
        };
    }

    pub fn floatingReady(self: ReturnState) ReturnState {
        const clean_floating_state: u32 = 2 << 13;
        var state = self.integerOnly();
        state.mstatus |= clean_floating_state;
        return state;
    }

    /// Unwind the trap being serviced, even when the selected task's last
    /// capture was an ECALL. Restoring that old exception cause on an IRQ
    /// return can leave CLIC MIL at the handler's priority on P4 revision 1.
    pub fn returningFrom(self: ReturnState, active_trap: ReturnState) ReturnState {
        return .{ .mstatus = self.mstatus, .mcause = active_trap.mcause };
    }
};

/// One machine word for `mepc`, followed by the 31 non-zero RV32 integer
/// registers in architectural ABI order. Assembly may address this structure
/// directly, so field order and offsets are part of the native port ABI.
pub const IntegerContext = extern struct {
    mepc: u32,
    ra: u32,
    sp: u32,
    gp: u32,
    tp: u32,
    t0: u32,
    t1: u32,
    t2: u32,
    s0: u32,
    s1: u32,
    a0: u32,
    a1: u32,
    a2: u32,
    a3: u32,
    a4: u32,
    a5: u32,
    a6: u32,
    a7: u32,
    s2: u32,
    s3: u32,
    s4: u32,
    s5: u32,
    s6: u32,
    s7: u32,
    s8: u32,
    s9: u32,
    s10: u32,
    s11: u32,
    t3: u32,
    t4: u32,
    t5: u32,
    t6: u32,
};

/// Fault diagnostics extend the switch frame. The padded storage reservation
/// is 160 bytes so the next stack position remains 16-byte aligned.
pub const ExceptionContext = extern struct {
    integer: IntegerContext,
    mstatus: u32,
    mtvec: u32,
    mcause: u32,
    mtval: u32,
    mhartid: u32,
};

/// Raw RV32F register bits. Index zero through 31 maps directly to f0..f31.
pub const FloatingContext = extern struct {
    f: [32]u32,
    fcsr: u32,
};

/// Raw test-worker ABI consumed by fpu.S. The worker never returns, and its
/// single-word progress stores are read only after it has been descheduled.
pub const FloatingProbe = extern struct {
    pattern: u32,
    expected_fcsr: u32,
    iterations: u32 = 0,
    failed: u32 = 0,
    stack_address: u32 = 0,
};

/// Check the saved bank as well as the live-bank assembly probe. Called only
/// by the owner after the task has stopped and its final trap saved the bank.
pub fn matchesProbe(bank: *const FloatingContext, probe: *const FloatingProbe) bool {
    if (bank.fcsr != probe.expected_fcsr or probe.failed != 0) return false;
    const sum = std.math.add(u32, probe.pattern, 0x0080_0000) catch return false;
    for (0..31) |index| {
        const expected = std.math.add(u32, probe.pattern, @as(u32, @intCast(index))) catch return false;
        if (bank.f[index] != expected) return false;
    }
    return bank.f[31] == sum;
}

/// A fully captured task that the trap epilogue may resume. Runtime policy
/// owns its lifetime; assembly sees only the chosen integer-frame pointer.
pub const TaskContext = struct {
    frame: *IntegerContext,
    state: ReturnState,
    stack_min: u32,
    stack_max: u32,
    floating_context: u32 = 0,
};

pub const InitialTask = struct {
    entry: u32,
    argument: u32,
    trampoline: u32,
    global_pointer: u32,
    thread_pointer: u32 = 0,
};

/// Returns the address of a new exception-sized initial frame below a stack
/// top, or null when the 32-bit range cannot contain it.
pub fn initialFrameAddress(stack_base: u32, stack_size: u32) ?u32 {
    const top = std.math.add(u32, stack_base, stack_size) catch return null;
    if (top < exception_storage_size) return null;
    const frame = (top - exception_storage_size) & ~(stack_alignment - 1);
    if (frame < stack_base) return null;
    return frame;
}

/// Returns the 16-byte-aligned 128-byte switch frame at the top of a task
/// stack. Restoring this frame leaves `sp` at the aligned stack top.
pub fn initialTaskFrameAddress(stack_base: u32, stack_size: u32) ?u32 {
    const top = std.math.add(u32, stack_base, stack_size) catch return null;
    if (top < integer_context_size) return null;
    const frame = (top - integer_context_size) & ~(stack_alignment - 1);
    if (frame < stack_base) return null;
    return frame;
}

/// Constructs the register image restored before a task first executes.
/// `trampoline` receives `entry` in a0 and `argument` in a1; it owns task
/// return handling, so an arbitrary task function never returns into a trap.
pub fn initialize(frame: *IntegerContext, task: InitialTask) void {
    frame.* = std.mem.zeroes(IntegerContext);
    frame.mepc = task.trampoline;
    frame.gp = task.global_pointer;
    frame.tp = task.thread_pointer;
    frame.a0 = task.entry;
    frame.a1 = task.argument;
}

comptime {
    if (@sizeOf(ReturnState) != 8 or @offsetOf(ReturnState, "mcause") != 4)
        @compileError("RV32 return-state assembly layout changed");
    if (@sizeOf(IntegerContext) != integer_context_size)
        @compileError("RV32 integer context must be 128 bytes");
    if (@alignOf(IntegerContext) != @alignOf(u32))
        @compileError("RV32 integer context must have word alignment");
    if (@offsetOf(IntegerContext, "mepc") != 0 or
        @offsetOf(IntegerContext, "sp") != 8 or
        @offsetOf(IntegerContext, "a0") != 40 or
        @offsetOf(IntegerContext, "t6") != 124)
    {
        @compileError("RV32 integer context offsets changed");
    }
    if (@sizeOf(ExceptionContext) != exception_context_size or
        @offsetOf(ExceptionContext, "mstatus") != integer_context_size or
        @offsetOf(ExceptionContext, "mhartid") != 144)
    {
        @compileError("RV32 exception context offsets changed");
    }
    if (@sizeOf(FloatingContext) != floating_context_size or
        @offsetOf(FloatingContext, "fcsr") != 128)
    {
        @compileError("RV32 floating-point context offsets changed");
    }
    if (@sizeOf(FloatingProbe) != 20 or
        @offsetOf(FloatingProbe, "iterations") != 8 or
        @offsetOf(FloatingProbe, "failed") != 12 or
        @offsetOf(FloatingProbe, "stack_address") != 16)
        @compileError("RV32 floating probe assembly layout changed");
}

test "task status follows selection while CLIC cause unwinds the active trap" {
    const incoming = ReturnState{ .mstatus = 0x7888, .mcause = 0xb835_0014 };
    const outgoing = incoming.integerOnly();
    try std.testing.expectEqual(@as(u32, 0x1880), outgoing.mstatus);
    try std.testing.expectEqual(incoming.mcause, outgoing.mcause);
    const floating = incoming.floatingReady();
    try std.testing.expectEqual(@as(u32, 0x5880), floating.mstatus);
    try std.testing.expectEqual(incoming.mcause, floating.mcause);
    const suspended_call = ReturnState{ .mstatus = 0x1880, .mcause = 0x3800_000b };
    const from_irq = suspended_call.returningFrom(incoming);
    try std.testing.expectEqual(suspended_call.mstatus, from_irq.mstatus);
    try std.testing.expectEqual(incoming.mcause, from_irq.mcause);
    const from_call = floating.returningFrom(suspended_call);
    try std.testing.expectEqual(floating.mstatus, from_call.mstatus);
    try std.testing.expectEqual(suspended_call.mcause, from_call.mcause);
}

test "saved FP bank rejects register, flag and sum corruption" {
    var probe = FloatingProbe{ .pattern = 0x3f80_1000, .expected_fcsr = 33 };
    var bank: FloatingContext = undefined;
    for (0..31) |index| bank.f[index] = probe.pattern + @as(u32, @intCast(index));
    bank.f[31] = probe.pattern + 0x0080_0000;
    bank.fcsr = 33;
    try std.testing.expect(matchesProbe(&bank, &probe));
    bank.f[11] ^= 1;
    try std.testing.expect(!matchesProbe(&bank, &probe));
    bank.f[11] ^= 1;
    bank.fcsr = 1;
    try std.testing.expect(!matchesProbe(&bank, &probe));
    bank.fcsr = 33;
    bank.f[31] ^= 1;
    try std.testing.expect(!matchesProbe(&bank, &probe));
    bank.f[31] ^= 1;
    probe.failed = 1;
    try std.testing.expect(!matchesProbe(&bank, &probe));
}

test "initial task frame is bounded and follows the trampoline ABI" {
    var frame: IntegerContext = undefined;
    initialize(&frame, .{
        .entry = 0x4200_1000,
        .argument = 0x4ff0_2000,
        .trampoline = 0x4200_0100,
        .global_pointer = 0x4ff0_0000,
        .thread_pointer = 0x4ff0_3000,
    });

    try std.testing.expectEqual(@as(u32, 0x4200_0100), frame.mepc);
    try std.testing.expectEqual(@as(u32, 0x4200_1000), frame.a0);
    try std.testing.expectEqual(@as(u32, 0x4ff0_2000), frame.a1);
    try std.testing.expectEqual(@as(u32, 0x4ff0_0000), frame.gp);
    try std.testing.expectEqual(@as(u32, 0x4ff0_3000), frame.tp);
    try std.testing.expectEqual(@as(u32, 0), frame.ra);
}

test "initial frame placement preserves alignment and rejects bad ranges" {
    try std.testing.expectEqual(
        @as(?u32, 0x2000_0f60),
        initialFrameAddress(0x2000_0003, 0x1000),
    );
    try std.testing.expect(initialFrameAddress(0xffff_ff80, 0x100) == null);
    try std.testing.expect(initialFrameAddress(0x2000_0000, 64) == null);
    try std.testing.expectEqual(
        @as(?u32, 0x2000_0f80),
        initialTaskFrameAddress(0x2000_0003, 0x1000),
    );
    try std.testing.expect(initialTaskFrameAddress(0x2000_0000, 64) == null);
}
