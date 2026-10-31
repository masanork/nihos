//! Separate internal-SRAM stack bank; owner-local observations, no allocator.
pub const layout = @import("stack_layout.zig");
extern var __stacks_start: u8;
extern var __stacks_end: u8;
extern var __task_stacks_start: u8;
extern var __task_stacks_end: u8;
extern var __graphics_font_stack_bottom: u8;
extern var __graphics_font_stack_top: u8;

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

// CPU0's owner retains this lease across frames. Publication is limited to the
// synchronous render call; an IRQ may then validate its interrupted PSRAM SP.
pub const foreground_bytes = 512 * 1024;
var foreground_low: u32 = 0;
var foreground_high: u32 = 0;
pub inline fn beginForeground(stack: []u8) bool {
    const low = @intFromPtr(stack.ptr);
    if (@atomicLoad(u32, &foreground_high, .acquire) != 0 or stack.len != foreground_bytes or
        low % 16 != 0 or low < 0x48030000 or low > 0x4a000000 - stack.len) return false;
    foreground_low = @intCast(low);
    @atomicStore(u32, &foreground_high, @intCast(low + stack.len), .release);
    return true;
}
pub inline fn endForeground() void {
    @atomicStore(u32, &foreground_high, 0, .release);
}

/// Permanent trap dispatcher only, with MIE clear. After completion the
/// immutable samples stay published; later traps still validate bounds.
pub fn capture(core: u32, frame: u32, saved_sp: u32, irq_sp: u32) bool {
    if (core >= 2 or owners[core].initialized != 1) return false;
    for (guard(core)) |word| if (word != layout.boot_guard) return false;
    if (@import("native_options").graphics and core == 0 and
        frame >= @intFromPtr(&__graphics_font_stack_bottom) + 16 and frame <= @intFromPtr(&__graphics_font_stack_top) - 128)
    {
        const low = @intFromPtr(&__graphics_font_stack_bottom);
        const high = @intFromPtr(&__graphics_font_stack_top);
        if (low != 0x4ff6e000 or high != 0x4ff76000 or frame % 16 != 0 or saved_sp != frame + 128) return false;
        const irq = layout.interrupt(0).?;
        const words: *const volatile [4]u32 = @ptrFromInt(low);
        for (words) |word| if (word != 0x67726166) return false;
        return irq_sp >= irq.start + 16 and irq_sp < irq.end and irq_sp % 16 == 0;
    }
    if (core == 0) {
        const high = @atomicLoad(u32, &foreground_high, .acquire);
        const low = foreground_low;
        if (high != 0 and frame >= low + 256 and frame <= high - 128) {
            if (frame % 16 != 0 or saved_sp != frame + 128) return false;
            const words: *const volatile [4]u32 = @ptrFromInt(low);
            for (words) |word| if (word != 0xa5a5a5a5) return false;
            const irq = layout.interrupt(0).?;
            return irq_sp >= irq.start + 16 and irq_sp < irq.end and irq_sp % 16 == 0;
        }
    }
    if (owners[core].confirmed != 0) {
        var sample = layout.Samples{};
        return sample.observe(core, frame, saved_sp, irq_sp);
    }
    return owners[core].samples.observe(core, frame, saved_sp, irq_sp);
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
