//! Separate internal-SRAM stack bank; owner-local observations, no allocator.
pub const layout = @import("stack_layout.zig");
extern var __stacks_start: u8;
extern var __stacks_end: u8;
extern var __task_stacks_start: u8;
extern var __task_stacks_end: u8;
extern var __bss_start: u8;
extern var __bss_end: u8;
const options = @import("native_options");
var extra: ?layout.Region = null;
var extra_captures: u32 = 0;

fn cpu0Masked() bool {
    const hart = asm volatile ("csrr %[result], mhartid"
        : [result] "=r" (-> u32),
    );
    const status = asm volatile ("csrr %[result], mstatus"
        : [result] "=r" (-> u32),
    );
    return hart == 0 and status & 8 == 0;
}

/// Experimental CPU0-only BSS stack. Must register with local IRQs masked
/// before publishing a task; the guard and frame bounds are checked in traps.
pub fn registerExperimental(start: u32, end: u32) bool {
    if (!options.pqc_worker_probe or !cpu0Masked() or extra != null or start % 64 != 0 or end -| start != 8192 or
        start < @intFromPtr(&__bss_start) or end > @intFromPtr(&__bss_end)) return false;
    const words: *volatile [4]u32 = @ptrFromInt(start);
    words.* = @splat(layout.worker_guard);
    extra = .{ .start = start, .end = end };
    return true;
}

/// Caller must have retired the worker and must hold local IRQs masked.
pub fn unregisterExperimental(start: u32, end: u32) bool {
    if (!options.pqc_worker_probe or !cpu0Masked()) return false;
    const region = extra orelse return false;
    if (region.start != start or region.end != end) return false;
    const words: *const volatile [4]u32 = @ptrFromInt(start);
    for (words) |word| if (word != layout.worker_guard) return false;
    extra = null;
    return true;
}

pub fn experimentalCaptures() u32 {
    return @atomicLoad(u32, &extra_captures, .acquire);
}

const Owner = struct {
    samples: layout.Samples align(64) = .{},
    zeroed: u32 = 0,
    initialized: u32 = 0,
    confirmed: u32 = 0,
};
var owners: [2]Owner = .{ .{}, .{} };

pub const Report = struct {
    start: u32,
    end: u32,
    boot_start: u32,
    boot_end: u32,
    irq_start: u32,
    irq_end: u32,
    task_start: u32,
    task_end: u32,
    boot_frame: u32,
    irq_sp: u32,
    task0_frame: u32,
    task1_frame: u32,
    task2_frame: u32,
    frames: u32,
    zeroed: u32,
    confirmed: u32,
};

fn linked() bool {
    return @intFromPtr(&__stacks_start) == layout.base and @intFromPtr(&__stacks_end) == layout.end and
        @intFromPtr(&__task_stacks_start) == layout.worker_base and @intFromPtr(&__task_stacks_end) == layout.end;
}

fn guard(core: u32) *volatile [4]u32 {
    return @ptrFromInt(layout.bootstrap(core).?.start);
}

/// Before this hart initializes its IRQ/task guards or takes any trap.
/// Assembly cleared the whole bank before either native stack was selected.
pub noinline fn begin(core: u32) bool {
    if (core >= 2 or !linked() or owners[core].initialized != 0) return false;
    const irq = layout.interrupt(core).?;
    const first = layout.worker(core, 0).?;
    for ([_]layout.Region{ irq, .{ .start = first.start, .end = first.start + 3 * layout.worker_bytes } }) |region| {
        const words: [*]const volatile u32 = @ptrFromInt(region.start);
        for (0..(region.end - region.start) / 4) |index| if (words[index] != 0) return false;
        owners[core].zeroed += region.end - region.start;
    }
    guard(core).* = @splat(layout.boot_guard);
    owners[core].initialized = 1;
    return true;
}

/// Permanent trap dispatcher only, with MIE clear. After completion the
/// immutable samples stay published; later traps still validate bounds.
pub fn capture(core: u32, frame: u32, saved_sp: u32, irq_sp: u32) bool {
    if (core >= 2 or owners[core].initialized != 1) return false;
    for (guard(core)) |word| if (word != layout.boot_guard) return false;
    const ordinary = if (owners[core].confirmed != 0) blk: {
        var sample = layout.Samples{};
        break :blk sample.observe(core, frame, saved_sp, irq_sp);
    } else owners[core].samples.observe(core, frame, saved_sp, irq_sp);
    if (ordinary) return true;
    if (options.pqc_worker_probe and core == 0) if (extra) |region| {
        const words: *const volatile [4]u32 = @ptrFromInt(region.start);
        for (words) |word| if (word != layout.worker_guard) return false;
        if (!layout.extraFrameFits(core, region, frame, saved_sp, irq_sp)) return false;
        _ = @atomicRmw(u32, &extra_captures, .Add, 1, .release);
        return true;
    };
    return false;
}

/// Renderer may run before worker qualification; validate only live boot/IRQ guards.
pub fn bootGuardsIntact(core: u32) bool {
    if (core >= 2 or owners[core].initialized != 1 or !linked()) return false;
    for (guard(core)) |word| if (word != layout.boot_guard) return false;
    const irq_guard: *volatile [4]u32 = @ptrFromInt(layout.interrupt(core).?.start);
    for (irq_guard) |word| if (word != layout.irq_guard) return false;
    return true;
}

pub noinline fn finish(core: u32) bool {
    if (core >= 2) return false;
    const status = asm volatile ("csrrci %[result], mstatus, 8"
        : [result] "=r" (-> u32),
        :
        : .{ .memory = true });
    defer if (status & 8 != 0) asm volatile ("csrsi mstatus, 8" ::: .{ .memory = true });
    if (!linked() or owners[core].initialized != 1 or !owners[core].samples.complete() or
        owners[core].zeroed != layout.irq_bytes + 3 * layout.worker_bytes) return false;
    for (guard(core)) |word| if (word != layout.boot_guard) return false;
    const irq_guard: *volatile [4]u32 = @ptrFromInt(layout.interrupt(core).?.start);
    for (irq_guard) |word| if (word != layout.irq_guard) return false;
    for (0..3) |index| {
        const worker_guard: *volatile [4]u32 = @ptrFromInt(layout.worker(core, @intCast(index)).?.start);
        for (worker_guard) |word| if (word != layout.worker_guard) return false;
    }
    @atomicStore(u32, &owners[core].confirmed, 1, .release);
    return true;
}

pub fn report(core: u32) ?Report {
    if (core >= 2 or @atomicLoad(u32, &owners[core].confirmed, .acquire) != 1) return null;
    const boot = layout.bootstrap(core).?;
    const irq = layout.interrupt(core).?;
    const first = layout.worker(core, 0).?;
    const sample = owners[core].samples;
    return .{ .start = layout.base, .end = layout.end, .boot_start = boot.start, .boot_end = boot.end, .irq_start = irq.start, .irq_end = irq.end, .task_start = first.start, .task_end = first.start + 3 * layout.worker_bytes, .boot_frame = sample.boot_frame, .irq_sp = sample.irq_sp, .task0_frame = sample.task_frames[0], .task1_frame = sample.task_frames[1], .task2_frame = sample.task_frames[2], .frames = sample.frames, .zeroed = owners[core].zeroed, .confirmed = 1 };
}
