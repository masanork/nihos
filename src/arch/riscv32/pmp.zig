//! Unlocked PMP plan for one untrusted RV32 task.
//!
//! ESP32-P4 has Machine and User mode only. An unlocked entry constrains
//! U-mode and does not apply to M-mode, so kernel tasks keep running with
//! `mstatus.MPP = Machine` and an empty plan. The two TOR grants are the
//! same shape as an instruction/data split: code is readable and executable,
//! the private arena is readable and writable. Entries stay unlocked. The L
//! bit locks an entry and applies its R/W/X bits to M-mode as well. U-mode
//! still receives those bits, so `RW|L` is a peripheral read-write grant.
//!
//! The ESP-IDF v5.4.4 bootloader programs entries 0, 1, 2, and 15 with `PMP_L`
//! in the `RW`/`RX` constants. Entries 0 and 1 have the highest priority, so
//! the app cannot override them. The port bootloader programs those two as
//! unlocked NAPOT regions with no R, W, or X. The model denies U-mode;
//! M-mode ignores them because L is clear. On Tab5 v1.3, loading CLIC at
//! `0x20800000` stalls with asynchronous bus errors. While a user grant is
//! installed, mhint.SBE makes bus errors synchronous, so the fault is
//! attributed to the user instruction before the kernel trap saves registers.
//! Entry 2 denies the mask ROM (`0x4FC00000..0x4FC20000`) without locking;
//! kernel ROM calls remain permitted in M-mode. Entry 15 is left OFF. Entry 8 is an
//! unlocked NAPOT denial of the HP peripheral window. It matches before a
//! leftover locked entry 15, and M-mode ignores it because L is clear.
//!
//! The grants occupy entries 4–7, which the stock bootloader leaves unlocked.
//! Installing a plan clears the unlocked whole-SRAM, whole-flash, and LP
//! windows. `grant` writes entries 4–8. `portEntries` models the bootloader
//! words for entries 0, 1, and 2. A check of those words is the host model.
//! It does not show that ESP-EMU or the Tab5 raises the fault.
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
pub const synchronous_bus_error: u32 = 1 << 20;
/// Hardware probe cases. Case 0 returns after an allowed ECALL. Cases 1–5 are
/// the contained faults. Cases 6–8 load `0x50000000`, the cache block at
/// `0x3FF10000`, and CLIC at `0x20800000`. A completed load returns 10, 11,
/// or 12 and is rejected.
/// Cases 9–11 test valid kernel SRAM, ROM read, and ROM instruction fetch.
pub const probe_cases: u32 = 12;

/// Case 0 must exit 1 after an allowed ECALL. Every other case must exit by
/// the contained fault. Host checks do not show that the silicon raises them.
pub fn probeResultAccepted(case_id: u32, exit_code: i32) bool {
    if (case_id >= probe_cases) return false;
    if (case_id == 0) return exit_code == 1;
    return exit_code == fault_exit;
}

/// A different fault is not proof that the attempted access was denied.
/// In particular, executing a ROM function and faulting later is not a
/// successful instruction-fetch denial at the ROM boundary.
pub fn probeCauseAccepted(case_id: u32, cause: u32, pc: u32) bool {
    if (case_id >= probe_cases) return false;
    const code = cause & 0x8000_0fff;
    return switch (case_id) {
        0 => cause == 0,
        2 => code == 7,
        3 => code == 1,
        4 => code == 8,
        5 => code == 2,
        11 => code == 1 and pc == 0x4fc0_0000,
        else => code == 5,
    };
}
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

/// High bound published for the current user plan. Zero means the plan was dropped.
pub fn publishedGrantHi(hart: u32) u32 {
    if (hart >= nih_user_bounds.len) return 0xffff_ffff;
    return nih_user_bounds[hart].hi;
}
export var nih_user_sp_bad: [2]u32 linksection(state_section) = @splat(0);
export var nih_user_fault_frames: [2][frame_bytes]u8 align(16) linksection(state_section) = @splat(@splat(0));

const tor = 1 << 3;
const napot = 3 << 3;
const read_bit = 1 << 0;
const write_bit = 1 << 1;
const execute_bit = 1 << 2;
const lock_bit = 1 << 7;
/// HP APB window, `SOC_PERIPHERAL_LOW .. SOC_PERIPHERAL_HIGH`.
const peripheral_lo: u32 = 0x5000_0000;
const peripheral_bytes: u32 = 0x10_0000;

fn napotAddress(start: u32, size: u32) u32 {
    return (start | ((size - 1) >> 1)) >> 2;
}

fn putNapot(words: *Words, index: u32, start: u32, size: u32, cfg: u32) void {
    words.addr[index] = napotAddress(start, size);
    const shift: u5 = @intCast((index % 4) * 8);
    words.cfg[index / 4] |= cfg << shift;
}

/// Bootloader entries 0, 1, and 2. Entries 0 and 1 match with no R, W, X, or L.
/// Entry 2 denies mask-ROM access without locking. Entry 15 stays OFF.
fn portEntries() Words {
    var words = Words{};
    putNapot(&words, 0, 0x2000_0000, 0x1000_0000, napot);
    putNapot(&words, 1, 0x3ff0_0000, 0x0002_0000, napot);
    putNapot(&words, 2, 0x4fc0_0000, 0x0002_0000, napot);
    return words;
}

/// IDF bootloader entries 0, 1, 2, and 15. `RW|L` still grants R and W to U-mode.
fn stockLockedEntries() Words {
    var words = Words{};
    const rw_lock = napot | lock_bit | read_bit | write_bit;
    putNapot(&words, 0, 0x2000_0000, 0x1000_0000, rw_lock);
    putNapot(&words, 1, 0x3ff0_0000, 0x0002_0000, rw_lock);
    putNapot(&words, 2, 0x4fc0_0000, 0x0002_0000, napot | lock_bit | read_bit | execute_bit);
    putNapot(&words, 15, peripheral_lo, peripheral_bytes, rw_lock);
    return words;
}

fn overlayGrant(boot: Words, plan: Words) Words {
    var words = boot;
    var index: u32 = 4;
    while (index <= 8) : (index += 1) words.addr[index] = plan.addr[index];
    words.cfg[1] = plan.cfg[1];
    words.cfg[2] |= plan.cfg[2];
    return words;
}

fn aligned(address: u32) bool {
    return address & (granularity - 1) == 0;
}

fn separated(code_lo: u32, code_hi: u32, data_lo: u32, data_hi: u32) bool {
    return code_hi <= data_lo or data_hi <= code_lo;
}

/// TOR grants on entries 4–7 and an unlocked NAPOT denial on entry 8.
/// Entries 4 and 6 stay OFF and hold the lower bounds. Code has no write bit.
/// Data has no execute bit. Entry 8 has no R, W, X, or L bit.
pub noinline fn grant(code_lo: u32, code_hi: u32, data_lo: u32, data_hi: u32) linksection(text_section) ?Words {
    if (!(code_lo < code_hi and data_lo < data_hi)) return null;
    if (!(aligned(code_lo) and aligned(code_hi) and aligned(data_lo) and aligned(data_hi))) return null;
    if (!separated(code_lo, code_hi, data_lo, data_hi)) return null;
    if (data_lo > std.math.maxInt(u32) - frame_bytes) return null;
    var words = Words{};
    words.addr[4] = code_lo >> 2;
    words.addr[5] = code_hi >> 2;
    words.cfg[1] |= (tor | read_bit | execute_bit) << 8;
    words.addr[6] = data_lo >> 2;
    words.addr[7] = data_hi >> 2;
    words.cfg[1] |= (tor | read_bit | write_bit) << 24;
    words.addr[8] = napotAddress(peripheral_lo, peripheral_bytes);
    words.cfg[2] |= napot;
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
    if (comptime @import("builtin").cpu.arch == .riscv32) {
        if (!bootContractAccepted(.{
            asm volatile ("csrr %[value], pmpcfg0"
                : [value] "=r" (-> u32),
            ),
            asm volatile ("csrr %[value], pmpcfg1"
                : [value] "=r" (-> u32),
            ),
            asm volatile ("csrr %[value], pmpcfg2"
                : [value] "=r" (-> u32),
            ),
            asm volatile ("csrr %[value], pmpcfg3"
                : [value] "=r" (-> u32),
            ),
        }, .{
            asm volatile ("csrr %[value], pmpaddr0"
                : [value] "=r" (-> u32),
            ),
            asm volatile ("csrr %[value], pmpaddr1"
                : [value] "=r" (-> u32),
            ),
            asm volatile ("csrr %[value], pmpaddr2"
                : [value] "=r" (-> u32),
            ),
        })) return false;
    }
    // The trap accepts any aligned SP in the writable grant. That grant is
    // therefore the only range a saved frame may occupy.
    return stack_min == data_lo and stack_max == data_hi;
}

/// A stale stock loader must not silently leave ROM, MMIO, or a locked RAM
/// grant accessible to a protected task. This checks the live loader ABI;
/// it is not evidence that a chip enforces the CLIC denial.
pub fn bootContractAccepted(cfg: [cfg_words]u32, first_addr: [3]u32) bool {
    return cfg[0] == 0x0018_1818 and cfg[3] == 0 and
        cfg[1] & 0x8080_8080 == 0 and cfg[2] & 0x8080_8080 == 0 and
        first_addr[0] == napotAddress(0x2000_0000, 0x1000_0000) and
        first_addr[1] == napotAddress(0x3ff0_0000, 0x0002_0000) and
        first_addr[2] == napotAddress(0x4fc0_0000, 0x0002_0000);
}

pub const Access = enum { read, write, execute };

fn entryCfg(words: Words, index: u32) u32 {
    const shift: u5 = @intCast((index % 4) * 8);
    return (words.cfg[index / 4] >> shift) & 0xff;
}

fn napotContains(address: u32, encoded: u32) bool {
    const trailing_ones: u32 = @ctz(~encoded);
    // 2^(trailing ones + 3) bytes. 29 or more trailing ones covers 4 GiB.
    if (trailing_ones >= 29) return true;
    const size: u32 = @as(u32, 1) << @intCast(trailing_ones + 3);
    const mask_bits = trailing_ones + 1;
    const addr_mask: u32 = (@as(u32, 1) << @intCast(mask_bits)) - 1;
    const base = (encoded & ~addr_mask) << 2;
    const end = base +% size;
    if (end <= base) return address >= base;
    return address >= base and address < end;
}

/// U-mode result for the supplied words. No match is a denial. TOR and NAPOT
/// are applied in priority order. `grant` leaves entries 0, 1, and 2 empty.
/// `portEntries` carries the bootloader encoding for those three.
pub fn permits(words: Words, address: u32, access: Access) bool {
    for (0..entry_count) |index| {
        const cfg = entryCfg(words, @intCast(index));
        const mode = cfg >> 3 & 3;
        const matched = switch (mode) {
            1 => blk: {
                const hi = words.addr[index] << 2;
                const lo = if (index == 0) 0 else words.addr[index - 1] << 2;
                break :blk address >= lo and address < hi;
            },
            3 => napotContains(address, words.addr[index]),
            else => false,
        };
        if (!matched) continue;
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
            // The bootloader owns the deny entries 0–2. This writer leaves
            // pmpcfg0 unchanged. The bootloader owns
            // entries 0 and 1 (unlocked NAPOT, no R/W/X) and leaves entry 15
            // OFF. Entry 8 is 16 bytes after addr4: an unlocked NAPOT denial
            // of the HP peripherals, which matches before a leftover locked
            // entry 15. Clearing pmpcfg1 and pmpcfg2 drops the unlocked
            // whole-SRAM, whole-flash, and LP windows first.
            const addr4: *const u32 = &words.addr[4];
            const cfg1: *const u32 = &words.cfg[1];
            const sbe: u32 = if (words.cfg[1] != 0) synchronous_bus_error else 0;
            // SAFETY: the assembly block writes this scratch before every read.
            var word: u32 = undefined;
            asm volatile (
                \\csrw pmpcfg1, zero
                \\csrw pmpcfg2, zero
                \\lw %[word], 0(%[addr])
                \\csrw pmpaddr4, %[word]
                \\lw %[word], 4(%[addr])
                \\csrw pmpaddr5, %[word]
                \\lw %[word], 8(%[addr])
                \\csrw pmpaddr6, %[word]
                \\lw %[word], 12(%[addr])
                \\csrw pmpaddr7, %[word]
                \\lw %[word], 16(%[addr])
                \\csrw pmpaddr8, %[word]
                \\lw %[word], 0(%[cfg])
                \\csrw pmpcfg1, %[word]
                \\lw %[word], 4(%[cfg])
                \\csrw pmpcfg2, %[word]
                // v1.3 TRM 1.13.1.2: retain synchronous attribution while
                // user code runs; kernel-only operation uses default mode.
                \\csrr %[word], 0x7c5
                \\and %[word], %[word], %[sbe_clear]
                \\or %[word], %[word], %[sbe]
                \\csrw 0x7c5, %[word]
                \\fence.i
                \\fence iorw, iorw
                : [word] "=&r" (word),
                : [addr] "r" (addr4),
                  [cfg] "r" (cfg1),
                  [sbe_clear] "r" (~synchronous_bus_error),
                  [sbe] "r" (sbe),
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
    try std.testing.expectEqual(@as(u32, 0x1000 >> 2), words.addr[4]);
    try std.testing.expectEqual(@as(u32, 0x1200 >> 2), words.addr[5]);
    try std.testing.expectEqual(@as(u32, 0x2000 >> 2), words.addr[6]);
    try std.testing.expectEqual(@as(u32, 0x2800 >> 2), words.addr[7]);
    try std.testing.expect(words.addr[0] == 0 and words.addr[1] == 0 and words.addr[2] == 0 and words.addr[3] == 0);
    try std.testing.expectEqual(@as(u32, 0x1401_ffff), words.addr[8]);
    try std.testing.expect(words.addr[9] == 0 and words.addr[15] == 0);
    try std.testing.expect(words.cfg[0] == 0 and words.cfg[3] == 0);
    try std.testing.expectEqual(@as(u32, 0x0B000D00), words.cfg[1]);
    try std.testing.expectEqual(@as(u32, 0x18), words.cfg[2]);
    try std.testing.expect(words.cfg[1] & 0x80808080 == 0);
    try std.testing.expect(words.cfg[2] & 0x80 == 0);
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
    try std.testing.expect(!permits(words, peripheral_lo, .read));
    try std.testing.expect(!permits(words, 0x500f_ffff, .write));
    try std.testing.expect(!permits(words, 0x5008_0000, .execute));
}

test "NAPOT matching follows the encoded power-of-two window" {
    var words = Words{};
    words.addr[8] = 0x1401_ffff;
    words.cfg[2] = read_bit | napot;
    try std.testing.expect(permits(words, 0x5000_0000, .read));
    try std.testing.expect(permits(words, 0x500f_fffc, .read));
    try std.testing.expect(!permits(words, 0x5000_0000, .write));
    try std.testing.expect(!permits(words, 0x4fff_ffff, .read));
    try std.testing.expect(!permits(words, 0x5010_0000, .read));
}

test "entries 0, 1, and 2 are outside the words this writer programs" {
    // grant() leaves these addresses unmatched. The port bootloader entries
    // are covered by the following test.
    const words = grant(0x1000, 0x1200, 0x2000, 0x2800).?;
    try std.testing.expect(words.addr[0] == 0 and words.addr[1] == 0 and words.cfg[0] == 0);
    try std.testing.expect(!permits(words, 0x2000_0000, .read));
    try std.testing.expect(!permits(words, 0x3ff0_0000, .write));
    try std.testing.expect(!permits(words, 0x4fc0_0000, .execute));
}

test "locked peripheral RW grants U-mode and the port entries deny those loads" {
    const stock = stockLockedEntries();
    try std.testing.expectEqual(@as(u32, 0x009d9b9b), stock.cfg[0]);
    try std.testing.expectEqual(@as(u32, 0x9b000000), stock.cfg[3]);
    try std.testing.expect(permits(stock, 0x2080_0000, .read));
    try std.testing.expect(permits(stock, 0x2080_0000, .write));
    try std.testing.expect(permits(stock, 0x3ff1_0000, .read));
    try std.testing.expect(permits(stock, 0x3ff1_0000, .write));
    try std.testing.expect(permits(stock, 0x5000_0000, .read));
    try std.testing.expect(permits(stock, 0x5000_0000, .write));
    try std.testing.expect(permits(stock, 0x4fc0_0000, .execute));
    try std.testing.expect(!permits(stock, 0x4fc0_0000, .write));

    const plan = grant(0x1000, 0x1200, 0x2000, 0x2800).?;
    const port = overlayGrant(portEntries(), plan);
    try std.testing.expectEqual(@as(u32, 0x00181818), port.cfg[0]);
    try std.testing.expectEqual(@as(u32, 0x09ff_ffff), port.addr[0]);
    try std.testing.expectEqual(@as(u32, 0x0ffc_3fff), port.addr[1]);
    try std.testing.expectEqual(@as(u32, 0x13f0_3fff), port.addr[2]);
    try std.testing.expect(!permits(port, 0x2080_0000, .read));
    try std.testing.expect(!permits(port, 0x2080_0000, .write));
    try std.testing.expect(!permits(port, 0x2000_0000, .read));
    try std.testing.expect(!permits(port, 0x3ff1_0000, .read));
    try std.testing.expect(!permits(port, 0x3ff1_0000, .write));
    try std.testing.expect(!permits(port, 0x3ff0_0000, .read));
    try std.testing.expect(!permits(port, 0x5000_0000, .read));
    try std.testing.expect(!permits(port, 0x500f_ffff, .write));
    try std.testing.expect(!permits(port, 0x4fc0_0000, .execute));
    try std.testing.expect(!permits(port, 0x4fc1_fffc, .read));
    try std.testing.expect(!permits(port, 0x4fc0_0000, .write));
    try std.testing.expect(permits(port, 0x1000, .execute));
    try std.testing.expect(!permits(port, 0x1000, .write));
    try std.testing.expect(permits(port, 0x2000, .write));
    try std.testing.expect(!permits(port, 0x2000, .execute));
    // Entry 8 is lower-numbered than a leftover locked entry 15, so it wins.
    var leftover = port;
    putNapot(&leftover, 15, peripheral_lo, peripheral_bytes, napot | lock_bit | read_bit | write_bit);
    try std.testing.expect(!permits(leftover, 0x5000_0000, .read));
}

test "protected registration rejects a stale or locked boot PMP contract" {
    const port = portEntries();
    const addresses = port.addr[0..3].*;
    try std.testing.expect(bootContractAccepted(port.cfg, addresses));
    try std.testing.expect(!bootContractAccepted(stockLockedEntries().cfg, addresses));
    var cfg = port.cfg;
    cfg[0] = 0x009d_1818; // Old port loader still grants locked ROM RX.
    try std.testing.expect(!bootContractAccepted(cfg, addresses));
    cfg = port.cfg;
    cfg[1] = 0x80; // A debugger or old loader locked a task entry.
    try std.testing.expect(!bootContractAccepted(cfg, addresses));
    cfg = port.cfg;
    cfg[3] = 0x9b00_0000;
    try std.testing.expect(!bootContractAccepted(cfg, addresses));
    var wrong = addresses;
    wrong[2] = 0;
    try std.testing.expect(!bootContractAccepted(port.cfg, wrong));
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

test "probe results accept only the contained fault and the allowed return" {
    try std.testing.expect(probeResultAccepted(0, 1));
    try std.testing.expect(!probeResultAccepted(0, fault_exit));
    try std.testing.expect(!probeResultAccepted(0, 2));
    var case_id: u32 = 1;
    while (case_id < probe_cases) : (case_id += 1) {
        try std.testing.expect(probeResultAccepted(case_id, fault_exit));
        try std.testing.expect(!probeResultAccepted(case_id, 1));
    }
    try std.testing.expect(!probeResultAccepted(probe_cases, fault_exit));
    try std.testing.expect(probeCauseAccepted(11, 0x0800_0001, 0x4fc0_0000));
    try std.testing.expect(!probeCauseAccepted(11, 0x0800_0002, 0x4fc0_0004));
    try std.testing.expect(!probeCauseAccepted(11, 0x0800_0001, 0x4000_0000));
    try std.testing.expect(!probeCauseAccepted(9, 0x0800_0002, 0));
}
