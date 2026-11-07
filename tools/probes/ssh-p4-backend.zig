//! RV32 code generation only. The stub ownership is not a real lease.
const backend_mod = @import("ssh_p4_backend");
const IO = struct {
    flag: u32,
    now: u64,
    pub fn acquire(self: *@This()) bool {
        return self.flag != 0;
    }
    pub fn release(self: *@This()) bool {
        return self.flag != 0;
    }
    pub fn owned(self: *@This()) bool {
        return self.flag != 0;
    }
    pub fn clockReady(self: *@This()) bool {
        return self.flag != 0;
    }
    pub fn cpuHz(_: *@This()) u32 {
        return 160_000_000;
    }
    pub fn apbHz(_: *@This()) u32 {
        return 80_000_000;
    }
    pub fn nowMicros(self: *@This()) u64 {
        return self.now;
    }
    pub fn cycles(_: *@This()) u32 {
        return asm volatile ("csrr %[value], mcycle"
            : [value] "=r" (-> u32),
        );
    }
    pub fn readRng(_: *@This()) u32 {
        return @as(*const volatile u32, @ptrFromInt(0x501101a4)).*;
    }
    pub fn lowTimerByte(_: *@This()) u8 {
        @as(*volatile u32, @ptrFromInt(0x50112010)).* = 1 << 28;
        return @truncate(@as(*const volatile u32, @ptrFromInt(0x50112014)).*);
    }
    pub fn read(_: *@This(), address: usize) u32 {
        return @as(*const volatile u32, @ptrFromInt(address)).*;
    }
    pub fn write(_: *@This(), address: usize, value: u32) void {
        @as(*volatile u32, @ptrFromInt(address)).* = value;
    }
};
const B = backend_mod.Backend(IO);
export fn nih_ssh_p4_backend_probe(backend: *B, io: *IO) u32 {
    backend.* = B.init(io, 10_000, 1_000, 160);
    backend.begin() catch return 0;
    _ = backend.sample() catch return 0;
    return @intFromBool(backend.release());
}

// Compile-only wiring. This reservation is deliberately not a hardware owner.
const leases = @import("p4_entropy_lease");
const Resources = struct {
    held: bool = false,
    pub fn tryReserve(self: *@This()) bool {
        if (self.held) return false;
        self.held = true;
        return true;
    }
    pub fn owned(self: *@This()) bool {
        return self.held;
    }
    pub fn releaseUnused(self: *@This()) void {
        self.held = false;
    }
    pub fn releaseRestored(self: *@This()) bool {
        self.held = false;
        return true;
    }
};
const Reservation = leases.Lease(leases.NativeRngGate, Resources);
const hw_mod = @import("p4_entropy_hardware");
const clock_mod = @import("p4_entropy_clock");
const ClockIO = struct {
    reservation: *Reservation,
    access: *hw_mod.NativeAccess,
    pub fn owned(self: *@This()) bool {
        return self.reservation.owned();
    }
    pub fn read(self: *@This(), address: usize) u32 {
        return self.access.read(address);
    }
    pub fn counter(_: *@This()) ?u64 {
        return 0;
    }
};
const Clock = clock_mod.Guard(ClockIO);
const Hardware = hw_mod.Hardware(hw_mod.NativeAccess, Clock);
const Platform = leases.Platform(Reservation, Hardware);
const ComposedBackend = backend_mod.Backend(Platform);
export fn nih_ssh_p4_composed_probe(backend: *ComposedBackend, platform: *Platform) u32 {
    backend.* = ComposedBackend.init(platform, 10_000, 1_000, 160);
    backend.begin() catch return 0;
    _ = backend.sample() catch return 0;
    return @intFromBool(backend.release());
}
