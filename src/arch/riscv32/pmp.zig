//! Unlocked PMP plan for one untrusted RV32 task.
//!
//! ESP32-P4 has Machine and User mode only. An unlocked entry constrains
//! U-mode and does not apply to M-mode, so kernel tasks keep running with
//! `mstatus.MPP = Machine` and an empty plan. The two TOR grants are the
//! same shape as an instruction/data split: code is readable and executable,
//! the private arena is readable and writable, and every other address is
//! denied. Entries stay unlocked. A locked table would give U-mode the same
//! permissions on those regions and could not be replaced for the next task.
//!
//! Granularity matches ESP-IDF v5.4.4 `SOC_CPU_PMP_REGION_GRANULARITY`.
//! This does not program the DMA permission controller.

const std = @import("std");

pub const entry_count = 16;
pub const cfg_words = 4;
pub const granularity: u32 = 128;
pub const frame_bytes: u32 = 128;
pub const mpp_mask: u32 = 0x1800;
pub const user_mpp: u32 = 0;
/// MPIE set, MPP = User. `mret` enables interrupts in U-mode.
pub const user_mstatus: u32 = 0x80;
pub const fault_exit: i32 = -70;
/// Cold writer. The graphics image's primary SRAM heap sits on the 48 KiB
/// floor, so the CSR sequence lives in the boot Flash page. Callers with an
/// empty plan return before reaching it.
pub const text_section = switch (@import("builtin").os.tag) {
    .freestanding => ".flash.text.pmp",
    .macos => "__TEXT,__text",
    else => ".text",
};

pub const Words = struct {
    addr: [entry_count]u32 = @splat(0),
    cfg: [cfg_words]u32 = @splat(0),
};

pub const Bounds = extern struct { lo: u32, hi: u32 };

/// Graphics keeps these out of the primary SRAM heap. The integer image
/// collects the same input section into ordinary BSS.
const state_section = switch (@import("builtin").os.tag) {
    .freestanding => ".user.pmp_state",
    .macos => "__DATA,__bss",
    else => ".bss",
};

export var nih_user_bounds: [2]Bounds align(8) linksection(state_section) = @splat(.{ .lo = 0, .hi = 0 });
export var nih_user_sp_bad: [2]u32 linksection(state_section) = @splat(0);
export var nih_user_fault_frames: [2][frame_bytes]u8 align(16) linksection(state_section) = @splat(@splat(0));

const tor = 1 << 3;
const read_bit = 1 << 0;
const write_bit = 1 << 1;
const execute_bit = 1 << 2;

fn aligned(address: u32) bool {
    return address & (granularity - 1) == 0;
}

fn separated(code_lo: u32, code_hi: u32, data_lo: u32, data_hi: u32) bool {
    return code_hi <= data_lo or data_hi <= code_lo;
}

/// Two TOR grants, entries 0–3. Entry 0 and 2 stay OFF and hold the lower
/// bounds. Code has no write bit. Data has no execute bit.
pub noinline fn grant(code_lo: u32, code_hi: u32, data_lo: u32, data_hi: u32) linksection(text_section) ?Words {
    if (!(code_lo < code_hi and data_lo < data_hi)) return null;
    if (!(aligned(code_lo) and aligned(code_hi) and aligned(data_lo) and aligned(data_hi))) return null;
    if (!separated(code_lo, code_hi, data_lo, data_hi)) return null;
    if (data_lo > std.math.maxInt(u32) - frame_bytes) return null;
    var words = Words{};
    words.addr[0] = code_lo >> 2;
    words.addr[1] = code_hi >> 2;
    words.cfg[0] |= (tor | read_bit | execute_bit) << 8;
    words.addr[2] = data_lo >> 2;
    words.addr[3] = data_hi >> 2;
    words.cfg[0] |= (tor | read_bit | write_bit) << 24;
    return words;
}

pub noinline fn protectionAccepted(
    code_lo: u32,
    code_hi: u32,
    data_lo: u32,
    data_hi: u32,
    mstatus: u32,
    floating: u32,
    stack_min: u32,
    stack_max: u32,
) linksection(text_section) bool {
    if (grant(code_lo, code_hi, data_lo, data_hi) == null) return false;
    if (floating != 0 or mstatus & mpp_mask != user_mpp) return false;
    // The trap accepts any aligned SP in the writable grant. That grant is
    // therefore the only range a saved frame may occupy.
    return stack_min == data_lo and stack_max == data_hi;
}

pub const Access = enum { read, write, execute };

fn entryCfg(words: Words, index: u32) u32 {
    const shift: u5 = @intCast((index % 4) * 8);
    return (words.cfg[index / 4] >> shift) & 0xff;
}

/// U-mode result for one byte address. No match is a denial.
pub fn permits(words: Words, address: u32, access: Access) bool {
    for (0..entry_count) |index| {
        const cfg = entryCfg(words, @intCast(index));
        if (cfg >> 3 & 3 != 1) continue;
        const hi = words.addr[index] << 2;
        const lo = if (index == 0) 0 else words.addr[index - 1] << 2;
        if (address < lo or address >= hi) continue;
        const bit: u32 = switch (access) {
            .read => read_bit,
            .write => write_bit,
            .execute => execute_bit,
        };
        return cfg & bit != 0;
    }
    return false;
}

pub fn resumePointer(data_lo: u32, data_hi: u32, sp: u32) bool {
    if (data_hi == 0 or data_lo >= data_hi or sp & 15 != 0) return false;
    const lowest = std.math.add(u32, data_lo, frame_bytes) catch return false;
    return sp >= lowest and sp <= data_hi;
}

pub fn containedFault(from_user: bool, sp_rejected: bool, cause: u32) bool {
    if (!from_user) return false;
    if (sp_rejected) return true;
    // Causes 0–7 are the synchronous faults, illegal instruction, and breakpoint.
    // Cause 8 is an ECALL from U-mode and stays on the call path.
    return cause & 0x8000_0fff < 8;
}

/// True when this trap frame is the user stack inside the published grant, or
/// the kernel fault frame after a rejected SP. Kernel qualification samples
/// must not observe either frame.
fn dispatcherFrameAccepted(status: u32, bounds: Bounds, sp_rejected: bool, frame: u32, saved_sp: u32, fault_frame: u32) bool {
    const top = std.math.add(u32, frame, frame_bytes) catch return false;
    if (frame & 15 != 0 or saved_sp != top) return false;
    if (sp_rejected) return frame == fault_frame;
    if (status & mpp_mask != user_mpp or bounds.hi == 0) return false;
    return resumePointer(bounds.lo, bounds.hi, saved_sp);
}

pub fn acceptsDispatcherFrame(hart: u32, status: u32, frame: u32, saved_sp: u32) bool {
    if (hart >= nih_user_bounds.len) return false;
    const fault_address = @intFromPtr(&nih_user_fault_frames[hart]);
    if (fault_address > std.math.maxInt(u32)) return false;
    return dispatcherFrameAccepted(status, nih_user_bounds[hart], nih_user_sp_bad[hart] != 0, frame, saved_sp, @intCast(fault_address));
}

pub fn userCall(from_user: bool, cause: u32) bool {
    const code = cause & 0x8000_0fff;
    return code == 11 or (from_user and code == 8);
}

pub fn rejectedPending(hart: u32) bool {
    return hart < nih_user_sp_bad.len and nih_user_sp_bad[hart] != 0;
}

pub fn takeRejectedSp(hart: u32) bool {
    if (!rejectedPending(hart)) return false;
    nih_user_sp_bad[hart] = 0;
    return true;
}

noinline fn writeWords(words: Words) linksection(text_section) void {
    switch (comptime @import("builtin").cpu.arch) {
        .riscv32 => {
            // Zero every configuration byte before publishing new addresses.
            const addr: *const [entry_count]u32 = &words.addr;
            const cfg: *const [cfg_words]u32 = &words.cfg;
            // SAFETY: the assembly block writes this scratch before every read.
            var word: u32 = undefined;
            asm volatile (
                \\csrw pmpcfg0, zero
                \\csrw pmpcfg1, zero
                \\csrw pmpcfg2, zero
                \\csrw pmpcfg3, zero
                \\lw %[word], 0(%[addr])
                \\csrw pmpaddr0, %[word]
                \\lw %[word], 4(%[addr])
                \\csrw pmpaddr1, %[word]
                \\lw %[word], 8(%[addr])
                \\csrw pmpaddr2, %[word]
                \\lw %[word], 12(%[addr])
                \\csrw pmpaddr3, %[word]
                \\lw %[word], 16(%[addr])
                \\csrw pmpaddr4, %[word]
                \\lw %[word], 20(%[addr])
                \\csrw pmpaddr5, %[word]
                \\lw %[word], 24(%[addr])
                \\csrw pmpaddr6, %[word]
                \\lw %[word], 28(%[addr])
                \\csrw pmpaddr7, %[word]
                \\lw %[word], 32(%[addr])
                \\csrw pmpaddr8, %[word]
                \\lw %[word], 36(%[addr])
                \\csrw pmpaddr9, %[word]
                \\lw %[word], 40(%[addr])
                \\csrw pmpaddr10, %[word]
                \\lw %[word], 44(%[addr])
                \\csrw pmpaddr11, %[word]
                \\lw %[word], 48(%[addr])
                \\csrw pmpaddr12, %[word]
                \\lw %[word], 52(%[addr])
                \\csrw pmpaddr13, %[word]
                \\lw %[word], 56(%[addr])
                \\csrw pmpaddr14, %[word]
                \\lw %[word], 60(%[addr])
                \\csrw pmpaddr15, %[word]
                \\lw %[word], 0(%[cfg])
                \\csrw pmpcfg0, %[word]
                \\lw %[word], 4(%[cfg])
                \\csrw pmpcfg1, %[word]
                \\lw %[word], 8(%[cfg])
                \\csrw pmpcfg2, %[word]
                \\lw %[word], 12(%[cfg])
                \\csrw pmpcfg3, %[word]
                \\fence iorw, iorw
                : [word] "=&r" (word),
                : [addr] "r" (addr),
                  [cfg] "r" (cfg),
                : .{ .memory = true });
        },
        else => {},
    }
}

/// Install this hart's plan, or drop one that was previously installed.
/// An empty plan does not touch the CSRs and does not call Flash.
pub fn arm(hart: u32, protection: ?@import("context.zig").Protection) void {
    if (hart >= nih_user_bounds.len) return;
    if (protection == null and nih_user_bounds[hart].hi == 0) return;
    commit(hart, protection);
}

noinline fn commit(hart: u32, protection: ?@import("context.zig").Protection) linksection(text_section) void {
    if (protection) |region| {
        const words = grant(region.code_lo, region.code_hi, region.data_lo, region.data_hi) orelse {
            nih_user_bounds[hart] = .{ .lo = 0, .hi = 0 };
            writeWords(.{});
            return;
        };
        writeWords(words);
        nih_user_bounds[hart] = .{ .lo = region.data_lo, .hi = region.data_hi };
        return;
    }
    nih_user_bounds[hart] = .{ .lo = 0, .hi = 0 };
    writeWords(.{});
}

test "two TOR grants are write-exclusive and execute-exclusive" {
    const words = grant(0x1000, 0x1200, 0x2000, 0x2800).?;
    try std.testing.expectEqual(@as(u32, 0x1000 >> 2), words.addr[0]);
    try std.testing.expectEqual(@as(u32, 0x1200 >> 2), words.addr[1]);
    try std.testing.expectEqual(@as(u32, 0x2000 >> 2), words.addr[2]);
    try std.testing.expectEqual(@as(u32, 0x2800 >> 2), words.addr[3]);
    try std.testing.expect(words.cfg[1] == 0 and words.cfg[2] == 0 and words.cfg[3] == 0);
    try std.testing.expect(permits(words, 0x1000, .read));
    try std.testing.expect(permits(words, 0x11ff, .execute));
    try std.testing.expect(!permits(words, 0x1000, .write));
    try std.testing.expect(!permits(words, 0x1200, .execute));
    try std.testing.expect(permits(words, 0x2000, .read));
    try std.testing.expect(permits(words, 0x27ff, .write));
    try std.testing.expect(!permits(words, 0x2000, .execute));
    try std.testing.expect(!permits(words, 0x2800, .write));
    try std.testing.expect(!permits(words, 0x0000, .read));
    try std.testing.expect(!permits(words, 0x1800, .execute));
    try std.testing.expect(!permits(words, 0x3000, .write));
}

test "grant rejects empty, unaligned, and overlapping ranges" {
    try std.testing.expect(grant(0x1000, 0x1000, 0x2000, 0x2100) == null);
    try std.testing.expect(grant(0x1040, 0x1200, 0x2000, 0x2100) == null);
    try std.testing.expect(grant(0x1000, 0x1800, 0x1400, 0x2000) == null);
    try std.testing.expect(grant(0x2000, 0x2100, 0x1000, 0x1200) != null);
    try std.testing.expect(grant(0xffff_ff80, 0xffff_ff80, 0x1000, 0x1100) == null);
}

test "resume pointer must leave a frame inside the writable grant" {
    try std.testing.expect(resumePointer(0x2000, 0x2800, 0x2800));
    try std.testing.expect(resumePointer(0x2000, 0x2800, 0x2080));
    try std.testing.expect(!resumePointer(0x2000, 0x2800, 0x2070));
    try std.testing.expect(!resumePointer(0x2000, 0x2800, 0x2804));
    try std.testing.expect(!resumePointer(0x2000, 0x2800, 0x2810));
    try std.testing.expect(!resumePointer(0, 0, 0x2080));
}

test "protected acceptance requires user privilege and a stack inside the arena" {
    try std.testing.expect(protectionAccepted(0x1000, 0x1200, 0x2000, 0x2800, user_mstatus, 0, 0x2000, 0x2800));
    try std.testing.expect(!protectionAccepted(0x1000, 0x1200, 0x2000, 0x2800, 0x1880, 0, 0x2000, 0x2800));
    try std.testing.expect(!protectionAccepted(0x1000, 0x1200, 0x2000, 0x2800, user_mstatus, 4, 0x2000, 0x2800));
    try std.testing.expect(!protectionAccepted(0x1000, 0x1200, 0x2000, 0x2800, user_mstatus, 0, 0x1f00, 0x2800));
    try std.testing.expect(!protectionAccepted(0x1000, 0x1200, 0x2000, 0x2800, user_mstatus, 0, 0x2000, 0x2900));
    try std.testing.expect(!protectionAccepted(0x1000, 0x1200, 0x2000, 0x2800, user_mstatus, 0, 0x2100, 0x2700));
}

test "user faults are contained and machine calls stay on the existing path" {
    try std.testing.expect(containedFault(true, false, 0));
    try std.testing.expect(containedFault(true, false, 1));
    try std.testing.expect(containedFault(true, false, 2));
    try std.testing.expect(containedFault(true, false, 3));
    try std.testing.expect(containedFault(true, false, 4));
    try std.testing.expect(containedFault(true, false, 5));
    try std.testing.expect(containedFault(true, false, 6));
    try std.testing.expect(containedFault(true, false, 7));
    try std.testing.expect(containedFault(true, true, 0x8000_0010));
    try std.testing.expect(!containedFault(false, true, 1));
    try std.testing.expect(!containedFault(true, false, 8));
    try std.testing.expect(!containedFault(true, false, 11));
    try std.testing.expect(!containedFault(true, false, 0x8000_0010));
    try std.testing.expect(userCall(false, 11));
    try std.testing.expect(userCall(true, 8));
    try std.testing.expect(!userCall(false, 8));
    try std.testing.expect(!userCall(true, 0x8000_000b));
}

test "host user state section names a real bss section" {
    // A bare ".bss" is not a Mach-O specifier. Freestanding uses a distinct
    // input section so the primary BSS wildcard does not swallow the frames.
    const tag = @import("builtin").os.tag;
    if (tag == .macos) {
        try std.testing.expectEqualStrings("__DATA,__bss", state_section);
    } else if (tag != .freestanding) {
        try std.testing.expectEqualStrings(".bss", state_section);
    }
}

test "dispatcher frames stay inside the grant or the kernel fault frame" {
    const bounds = Bounds{ .lo = 0x2000, .hi = 0x2800 };
    const fault_frame: u32 = 0x1000;
    try std.testing.expect(dispatcherFrameAccepted(user_mstatus, bounds, false, 0x2700, 0x2780, fault_frame));
    try std.testing.expect(dispatcherFrameAccepted(user_mstatus, bounds, false, 0x2000, 0x2080, fault_frame));
    try std.testing.expect(dispatcherFrameAccepted(user_mstatus, bounds, false, 0x2780, 0x2800, fault_frame));
    try std.testing.expect(!dispatcherFrameAccepted(user_mstatus, bounds, false, 0x2700, 0x2784, fault_frame));
    try std.testing.expect(!dispatcherFrameAccepted(0x1880, bounds, false, 0x2700, 0x2780, fault_frame));
    try std.testing.expect(!dispatcherFrameAccepted(user_mstatus, .{ .lo = 0, .hi = 0 }, false, 0x2700, 0x2780, fault_frame));
    try std.testing.expect(!dispatcherFrameAccepted(user_mstatus, bounds, false, 0x1f80, 0x2000, fault_frame));
    try std.testing.expect(dispatcherFrameAccepted(0x1880, bounds, true, fault_frame, fault_frame + frame_bytes, fault_frame));
    try std.testing.expect(!dispatcherFrameAccepted(user_mstatus, bounds, true, 0x2700, 0x2780, fault_frame));
}
