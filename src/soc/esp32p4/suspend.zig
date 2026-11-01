//! ESP32-P4 Suspend-to-RAM context capture and state retention.
//! Provides low-overhead register capture, cache write-back coordination,
//! and signature-validated restore verification.
const std = @import("std");
pub const lp_core = @import("lp_core.zig");

pub const magic_signature: u32 = 0x53555350; // "SUSP"
pub const version_tag: u32 = 1;

/// Suspend state snapshot capturing CPU registers, CSRs, and validation checksum.
pub const SuspendSnapshot = extern struct {
    magic: u32 = magic_signature,
    version: u32 = version_tag,
    hart_id: u32 = 0,
    mstatus: u32 = 0,
    mepc: u32 = 0,
    sp: u32 = 0,
    ra: u32 = 0,
    s0: u32 = 0,
    s1: u32 = 0,
    s2: u32 = 0,
    s3: u32 = 0,
    s4: u32 = 0,
    s5: u32 = 0,
    s6: u32 = 0,
    s7: u32 = 0,
    s8: u32 = 0,
    s9: u32 = 0,
    s10: u32 = 0,
    s11: u32 = 0,
    checksum: u32 = 0,

    /// Calculate XOR checksum across all state fields (excluding the checksum field itself).
    pub fn calculateChecksum(self: *const SuspendSnapshot) u32 {
        var sum: u32 = 0;
        const ptr: [*]const u32 = @ptrCast(self);
        const words = (@sizeOf(SuspendSnapshot) - @sizeOf(u32)) / @sizeOf(u32);
        for (0..words) |i| sum ^= ptr[i];
        return sum;
    }

    /// Seal the snapshot by computing and storing its checksum.
    pub fn seal(self: *SuspendSnapshot) void {
        self.checksum = self.calculateChecksum();
    }

    /// Verify signature, version, and integrity checksum.
    pub fn isValid(self: *const SuspendSnapshot) bool {
        if (self.magic != magic_signature) return false;
        if (self.version != version_tag) return false;
        return self.checksum == self.calculateChecksum();
    }
};

/// Dedicated storage region for suspend snapshot inside LP SRAM.
/// Offset: 0x7e00 (512 bytes before mailbox at 0x7ff0).
pub const lp_snapshot_offset: usize = 0x7e00;
pub const lp_snapshot_address: usize = lp_core.lp_ram_base + lp_snapshot_offset;

/// Save snapshot to given target memory address.
pub fn saveSnapshot(target_address: usize, snapshot: SuspendSnapshot) bool {
    var sealed = snapshot;
    sealed.seal();
    const dest: *volatile SuspendSnapshot = @ptrFromInt(target_address);
    dest.* = sealed;
    return true;
}

/// Load and validate snapshot from memory.
pub fn loadSnapshot(source_address: usize) ?SuspendSnapshot {
    const src: *const volatile SuspendSnapshot = @ptrFromInt(source_address);
    const snap = src.*;
    if (!snap.isValid()) return null;
    return snap;
}

// --- Unit tests ---

test "SuspendSnapshot seals and validates integrity" {
    var snap = SuspendSnapshot{
        .hart_id = 0,
        .mstatus = 0x1880,
        .mepc = 0x4ff01234,
        .sp = 0x4ff1ff00,
        .ra = 0x4ff00100,
    };
    try std.testing.expect(!snap.isValid()); // Not sealed yet
    snap.seal();
    try std.testing.expect(snap.isValid());

    // Corrupted field fails validation
    var corrupted = snap;
    corrupted.mepc = 0xdeadbeef;
    try std.testing.expect(!corrupted.isValid());

    // Bad magic fails validation
    var bad_magic = snap;
    bad_magic.magic = 0;
    try std.testing.expect(!bad_magic.isValid());
}

test "saveSnapshot and loadSnapshot roundtrip across memory buffer" {
    var buffer: [@sizeOf(SuspendSnapshot) / 4 + 4]u32 = @splat(0);
    const addr = @intFromPtr(&buffer[0]);

    const snap = SuspendSnapshot{
        .hart_id = 1,
        .mstatus = 0x1800,
        .mepc = 0x4ff04000,
        .sp = 0x4ff1f000,
        .ra = 0x4ff04010,
        .s0 = 42,
    };

    try std.testing.expect(saveSnapshot(addr, snap));
    const loaded = loadSnapshot(addr);
    try std.testing.expect(loaded != null);
    try std.testing.expectEqual(snap.mepc, loaded.?.mepc);
    try std.testing.expectEqual(snap.sp, loaded.?.sp);
    try std.testing.expectEqual(snap.s0, loaded.?.s0);
}
