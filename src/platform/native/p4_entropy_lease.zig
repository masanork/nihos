//! Compose the SQLite RNG gate with a separate P4 hardware reservation.
//! This module does not provide or qualify the hardware reservation itself.

/// Resources must reserve ADCs, the analog master/selectors, clock/power and
/// timer as a single cooperative lease. tryReserve must not touch hardware;
/// releaseUnused must always undo that reservation. releaseRestored must
/// retain the reservation on false; true releases it after recovery. Both owners must remain alive
/// and must not be copied while the lease is held. The caller must serialize
/// calls on each Lease; the shared owners provide cross-core exclusion.
pub fn Lease(comptime Gate: type, comptime Resources: type) type {
    return struct {
        const Self = @This();
        const State = enum { idle, held, gate_only };
        gate: *Gate,
        resources: *Resources,
        state: State = .idle,
        token: u32 = 0,

        pub fn init(gate: *Gate, resources: *Resources) Self {
            return .{ .gate = gate, .resources = resources };
        }

        /// Failure leaves no reservation and does not alter hardware.
        pub fn acquire(self: *Self) bool {
            if (self.state != .idle or !self.resources.tryReserve()) return false;
            const token = self.gate.tryEntropy();
            if (token == 0) {
                self.resources.releaseUnused();
                return false;
            }
            self.token = token;
            self.state = .held;
            return true;
        }

        pub fn owned(self: *Self) bool {
            return self.state == .held and self.resources.owned() and self.gate.ownsEntropy(self.token);
        }

        /// Call only after ADC and analog restoration. Incomplete resource
        /// recovery retains both reservations. If the gate rejects its token,
        /// keep the residual gate reservation quarantined and never reacquire.
        pub fn release(self: *Self) bool {
            if (self.state == .idle) return true;
            if (self.state == .held) {
                if (!self.owned() or !self.resources.releaseRestored()) return false;
                self.state = .gate_only;
            }
            if (!self.gate.releaseEntropy(self.token)) return false;
            self.token = 0;
            self.state = .idle;
            return true;
        }
    };
}

/// Accesses the single gate owned by the native SQLite runtime. This adapter
/// is only linkable in configurations which include that runtime.
pub const NativeRngGate = struct {
    extern fn nih_p4_rng_try_entropy() callconv(.c) u32;
    extern fn nih_p4_rng_entropy_owned(u32) callconv(.c) bool;
    extern fn nih_p4_rng_release_entropy(u32) callconv(.c) bool;

    pub fn tryEntropy(_: *@This()) u32 {
        return nih_p4_rng_try_entropy();
    }
    pub fn ownsEntropy(_: *@This(), token: u32) bool {
        return nih_p4_rng_entropy_owned(token);
    }
    pub fn releaseEntropy(_: *@This(), token: u32) bool {
        return nih_p4_rng_release_entropy(token);
    }
};

const std = @import("std");
const TestGate = @import("p4_rng_gate.zig").Gate;
const FakeResources = struct {
    reserved: bool = false,
    recovery_ready: bool = true,
    pub fn tryReserve(self: *@This()) bool {
        if (self.reserved) return false;
        self.reserved = true;
        return true;
    }
    pub fn owned(self: *@This()) bool {
        return self.reserved;
    }
    pub fn releaseUnused(self: *@This()) void {
        std.debug.assert(self.reserved);
        self.reserved = false;
    }
    pub fn releaseRestored(self: *@This()) bool {
        if (!self.recovery_ready) return false;
        self.reserved = false;
        return true;
    }
};

test "failed acquisition rolls back the untouched hardware reservation" {
    var gate: TestGate = .{};
    var resources: FakeResources = .{};
    var lease = Lease(TestGate, FakeResources).init(&gate, &resources);
    try std.testing.expect(gate.trySqlite());
    try std.testing.expect(!lease.acquire());
    try std.testing.expect(!resources.reserved and !lease.owned());
    try std.testing.expect(gate.releaseSqlite());
    resources.reserved = true;
    try std.testing.expect(!lease.acquire());
    try std.testing.expect(gate.trySqlite());
    try std.testing.expect(gate.releaseSqlite());
}

test "incomplete recovery retains both owners until it succeeds" {
    var gate: TestGate = .{};
    var resources: FakeResources = .{ .recovery_ready = false };
    var lease = Lease(TestGate, FakeResources).init(&gate, &resources);
    try std.testing.expect(lease.acquire() and lease.owned());
    try std.testing.expect(!lease.release());
    try std.testing.expect(lease.owned() and !gate.trySqlite());
    try std.testing.expect(!lease.acquire());
    resources.recovery_ready = true;
    try std.testing.expect(lease.release());
    try std.testing.expect(!resources.reserved and gate.trySqlite());
    try std.testing.expect(gate.releaseSqlite());
    try std.testing.expect(lease.acquire() and lease.release());
}

test "lost ownership never releases the other reservation" {
    var gate: TestGate = .{};
    var resources: FakeResources = .{};
    var lease = Lease(TestGate, FakeResources).init(&gate, &resources);
    try std.testing.expect(lease.acquire());
    try std.testing.expect(gate.releaseEntropy(lease.token));
    try std.testing.expect(!lease.owned() and !lease.release());
    try std.testing.expect(resources.reserved and !lease.acquire());
}

test "failed final gate release quarantines the residual token" {
    const FailingGate = struct {
        held: bool = false,
        reject_release: bool = true,
        pub fn tryEntropy(self: *@This()) u32 {
            if (self.held) return 0;
            self.held = true;
            return 2;
        }
        pub fn ownsEntropy(self: *@This(), token: u32) bool {
            return self.held and token == 2;
        }
        pub fn releaseEntropy(self: *@This(), token: u32) bool {
            if (self.reject_release or !self.ownsEntropy(token)) return false;
            self.held = false;
            return true;
        }
    };
    var gate: FailingGate = .{};
    var resources: FakeResources = .{};
    var lease = Lease(FailingGate, FakeResources).init(&gate, &resources);
    try std.testing.expect(lease.acquire());
    try std.testing.expect(!lease.release());
    try std.testing.expect(gate.held and !resources.reserved and !lease.owned());
    try std.testing.expect(!lease.acquire());
    gate.reject_release = false;
    try std.testing.expect(lease.release());
    try std.testing.expect(!gate.held and lease.acquire() and lease.release());
}
