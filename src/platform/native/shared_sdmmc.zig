//! Normal-boot implementation, linked once into the filesystem service object.
//! Only CPU0 foreground tasks enter here. IRQs never reset/fence this host.
const core = @import("sdmmc_host");
const timers = @import("timer_group");
const abi = @import("shared_sdmmc_abi.zig");
const test_hooks = @import("normal_fs_test_hooks.zig");
extern fn nih_sdmmc_clock_init() callconv(.c) void;
extern fn nih_normal_c6_dma_release() callconv(.c) u32;
extern fn nih_normal_card_dma_release() callconv(.c) u32;
const base: u32 = 0x50083000;
const IO = struct {
    clock: timers.Timer = timers.Timer.fromGroup(0x500c3000, 0).?,
    pub fn read(_: @This(), register: usize) u32 {
        if (test_hooks.enabled) return test_hooks.nih_fs_test_read(@intCast(register));
        return @as(*volatile u32, @ptrFromInt(base + register)).*;
    }
    pub fn write(_: @This(), register: usize, value: u32) void {
        if (test_hooks.enabled) return test_hooks.nih_fs_test_write(@intCast(register), value);
        @as(*volatile u32, @ptrFromInt(base + register)).* = value;
        asm volatile ("fence iorw,iorw" ::: .{ .memory = true });
    }
    fn clear(self: @This(), register: usize, mask: u32) bool {
        const started = self.now() orelse return false;
        for (0..100_000) |_| {
            if (self.read(register) & mask == 0) return true;
            const current = self.now() orelse return false;
            if (current -| started >= 20_000) return false;
        }
        return false;
    }
    fn now(self: @This()) ?u64 {
        return if (test_hooks.enabled) test_hooks.nih_fs_test_now() else self.clock.counter();
    }
    pub fn idle(self: @This()) bool {
        return self.read(0x2c) & (1 << 31) == 0 and self.read(0x48) & (1 << 9) == 0 and
            self.read(0) & ((1 << 25) | (1 << 5) | (1 << 4) | 7) == 0 and
            self.read(0x80) == 0 and self.read(0x8c) & (15 << 13) == 0 and self.read(0x88) == 0;
    }
    pub fn reset(self: @This()) bool {
        nih_sdmmc_clock_init(); // Global peripheral reset, only this owner.
        self.write(0, 7);
        if (!self.clear(0, 7)) return false;
        self.write(0, 0);
        self.write(0x24, 0);
        self.write(0x90, 0);
        self.write(0x80, 0);
        self.write(0x88, 0);
        self.write(0x44, 0xffffffff);
        self.write(0x8c, 0xffffffff);
        return self.idle();
    }
    pub fn fence(self: @This(), slot: core.Slot) bool {
        self.write(0x24, 0);
        self.write(0x90, 0);
        self.write(0x80, 0);
        self.write(0, (self.read(0) & ~@as(u32, (1 << 25) | (1 << 5) | (1 << 4))) | 4);
        if (!self.clear(0, 4) or !self.clear(0x8c, 15 << 13) or !self.clear(0x48, 1 << 9) or
            !self.clear(0x2c, 1 << 31)) return false;
        self.write(0x88, 0);
        if (self.read(0x88) != 0) return false;
        const released = switch (slot) {
            .card => nih_normal_card_dma_release(),
            .c6 => nih_normal_c6_dma_release(),
        };
        if (released != 1) return false;
        self.write(0x44, 0xffffffff);
        self.write(0x8c, 0xffffffff);
        return self.idle();
    }
};
var host = core.Host(IO){ .io = .{} };
fn foreground() bool {
    if (test_hooks.enabled) return true;
    const hart = asm volatile ("csrr %[hart],mhartid"
        : [hart] "=r" (-> u32),
    );
    const status = asm volatile ("csrr %[status],mstatus"
        : [status] "=r" (-> u32),
    );
    return hart == 0 and status & 8 != 0;
}
fn decode(lease: *const abi.Lease) ?core.Lease {
    if (lease.slot > 1 or lease.serial == 0 or lease.generation == 0) return null;
    return .{ .slot = @fromBackingInt(@intCast(lease.slot)), .serial = lease.serial, .generation = lease.generation };
}
pub fn begin(clock: timers.Timer) bool {
    if (!foreground()) return false;
    host.io.clock = clock;
    host.initialize() catch return false;
    return true;
}
export fn nih_shared_sdmmc_acquire(slot: u32, output: *abi.Lease) callconv(.c) u32 {
    if (!foreground() or slot > 1) return 3;
    // Two foreground tasks can preempt each other. Publish ownership atomically
    // with the short idle check; transfer/fence waits retain MIE and the lease.
    const previous = if (test_hooks.enabled) test_hooks.nih_fs_test_mask() else asm volatile ("csrrci %[v],mstatus,8"
        : [v] "=r" (-> u32),
        :
        : .{ .memory = true });
    defer {
        if (test_hooks.enabled) test_hooks.nih_fs_test_restore(previous) else if (previous & 8 != 0) asm volatile ("csrsi mstatus,8" ::: .{ .memory = true });
    }
    const held = host.acquire(@fromBackingInt(@intCast(slot))) catch |err| return if (err == error.Busy) 1 else 2;
    output.* = .{ .serial = held.serial, .generation = held.generation, .slot = slot };
    return 0;
}
export fn nih_shared_sdmmc_release(input: *const abi.Lease) callconv(.c) u32 {
    if (!foreground()) return 3;
    const lease = decode(input) orelse return 3;
    host.release(lease) catch {
        // Recovery retains this owner's backing until the real fence succeeds.
        // Both consumers observe the new generation and must reinitialize.
        if (!host.quarantined) return 3;
        host.recover(lease) catch return 2;
        return 1; // Transfer failed; recovery does not turn it into success.
    };
    return 0;
}
export fn nih_shared_sdmmc_owns(input: *const abi.Lease) callconv(.c) u32 {
    if (!foreground()) return 0;
    const lease = decode(input) orelse return 0;
    return @intFromBool(host.owns(lease));
}
export fn nih_shared_sdmmc_read(input: *const abi.Lease, register: u32) callconv(.c) u32 {
    if (!foreground() or register > 0x200 or register & 3 != 0) return 0xffffffff;
    const lease = decode(input) orelse return 0xffffffff;
    return host.read(lease, register);
}
export fn nih_shared_sdmmc_write(input: *const abi.Lease, register: u32, value: u32) callconv(.c) void {
    if (!foreground() or register > 0x200 or register & 3 != 0) return;
    const lease = decode(input) orelse return;
    host.write(lease, register, value);
}
export fn nih_shared_sdmmc_generation() callconv(.c) u32 {
    return host.generation;
}
