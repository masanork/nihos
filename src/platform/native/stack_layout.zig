//! Data-only SRAM stack layout, shared with host validation tests.
const std = @import("std");
pub const base: u32 = 0x4ff60000;
pub const bootstrap_bytes: u32 = 8192;
pub const irq_bytes: u32 = 8192;
pub const worker_bytes: u32 = 4096;
pub const worker_count: u32 = 3;
pub const guard_bytes: u32 = 16;
pub const frame_bytes: u32 = 128;
pub const boot_guard: u32 = 0x6e696274;
pub const irq_guard: u32 = 0x6e696972;
pub const worker_guard: u32 = 0x6e697374;
pub const worker_base: u32 = base + 2 * (bootstrap_bytes + irq_bytes);
pub const end: u32 = worker_base + 2 * worker_count * worker_bytes;

pub const Region = struct {
    start: u32,
    end: u32,

    fn frameFits(self: Region, address: u32) bool {
        return address >= self.start + guard_bytes and address <= self.end and frame_bytes <= self.end - address;
    }

    fn spFits(self: Region, address: u32) bool {
        return address >= self.start + guard_bytes and address < self.end and address % 16 == 0;
    }
};

/// Validate a frame on a separately registered experiment stack. This does not
/// grant ownership or make external/cache-dependent memory safe for traps.
pub fn extraFrameFits(core: u32, region: Region, frame: u32, saved_sp: u32, irq_sp: u32) bool {
    const irq = interrupt(core) orelse return false;
    return region.start < region.end and region.start % 16 == 0 and region.end % 16 == 0 and
        frame % 16 == 0 and frame <= std.math.maxInt(u32) - frame_bytes and
        saved_sp == frame + frame_bytes and region.frameFits(frame) and irq.spFits(irq_sp);
}

pub fn bootstrap(core: u32) ?Region {
    if (core >= 2) return null;
    const start = base + core * bootstrap_bytes;
    return .{ .start = start, .end = start + bootstrap_bytes };
}

pub fn interrupt(core: u32) ?Region {
    if (core >= 2) return null;
    const start = base + 2 * bootstrap_bytes + core * irq_bytes;
    return .{ .start = start, .end = start + irq_bytes };
}

pub fn worker(core: u32, index: u32) ?Region {
    if (core >= 2 or index >= worker_count) return null;
    const start = worker_base + (core * worker_count + index) * worker_bytes;
    return .{ .start = start, .end = start + worker_bytes };
}

pub const Samples = struct {
    boot_frame: u32 = 0,
    irq_sp: u32 = 0,
    task_frames: [3]u32 = @splat(0),
    frames: u32 = 0,

    /// Snapshot points are observed frame bases/dispatcher SPs, not a
    /// complete peak-stack measurement. Caller owns one serialized hart.
    pub noinline fn observe(self: *Samples, core: u32, frame: u32, saved_sp: u32, irq_sp: u32) bool {
        const boot = bootstrap(core) orelse return false;
        const irq = interrupt(core).?;
        if (frame % 16 != 0 or frame > std.math.maxInt(u32) - frame_bytes or
            saved_sp != frame + frame_bytes or !irq.spFits(irq_sp)) return false;
        var target: ?*u32 = if (boot.frameFits(frame)) &self.boot_frame else null;
        for (0..worker_count) |index| if (worker(core, @intCast(index)).?.frameFits(frame)) {
            target = &self.task_frames[index];
        };
        const sample = target orelse return false;
        if (sample.* == 0 or frame < sample.*) sample.* = frame;
        if (self.irq_sp == 0 or irq_sp < self.irq_sp) self.irq_sp = irq_sp;
        self.frames +%= 1;
        return true;
    }

    pub fn complete(self: *const Samples) bool {
        if (self.boot_frame == 0 or self.irq_sp == 0 or self.frames < 4) return false;
        for (self.task_frames) |frame| if (frame == 0) return false;
        return true;
    }
};

test "ten reserved stack spans are disjoint and retain their capacities" {
    var regions: [10]Region = undefined;
    var count: usize = 0;
    for (0..2) |core| {
        regions[count] = bootstrap(@intCast(core)).?;
        regions[count + 1] = interrupt(@intCast(core)).?;
        count += 2;
        for (0..3) |index| {
            regions[count] = worker(@intCast(core), @intCast(index)).?;
            count += 1;
        }
    }
    var total: u32 = 0;
    for (regions, 0..) |region, index| {
        try std.testing.expect(region.start >= base and region.end <= end);
        total += region.end - region.start;
        for (regions[index + 1 ..]) |other| try std.testing.expect(region.end <= other.start or other.end <= region.start);
    }
    try std.testing.expectEqual(@as(u32, 57344), total);
    try std.testing.expect(bootstrap(2) == null and interrupt(2) == null and worker(0, 3) == null);
}

test "stack samples require owned aligned frames and preserve state on rejection" {
    for (0..2) |core_index| {
        const core: u32 = @intCast(core_index);
        var samples = Samples{};
        const irq = interrupt(core).?;
        const boot = bootstrap(core).?;
        try std.testing.expect(samples.observe(core, boot.end - 128, boot.end, irq.end - 64));
        try std.testing.expect(!samples.complete());
        for (0..3) |index| {
            const task = worker(core, @intCast(index)).?;
            try std.testing.expect(samples.observe(core, task.end - 128, task.end, irq.end - 64));
        }
        try std.testing.expect(samples.complete());
        try std.testing.expect(samples.observe(core, boot.end - 256, boot.end - 128, irq.end - 80));
        try std.testing.expectEqual(boot.end - 256, samples.boot_frame);
        try std.testing.expectEqual(irq.end - 80, samples.irq_sp);
        const before = samples;
        for ([_][3]u32{ .{ boot.start, boot.start + 128, irq.end - 64 }, .{ boot.end - 127, boot.end + 1, irq.end - 64 }, .{ boot.end - 128, boot.end - 16, irq.end - 64 }, .{ bootstrap(core ^ 1).?.end - 128, bootstrap(core ^ 1).?.end, irq.end - 64 }, .{ boot.end - 128, boot.end, interrupt(core ^ 1).?.end - 64 }, .{ boot.end - 128, boot.end, irq.end } }) |bad| {
            try std.testing.expect(!samples.observe(core, bad[0], bad[1], bad[2]));
            try std.testing.expectEqualDeep(before, samples);
        }
    }
}

test "invalid hart and overflowing frame addresses cannot change samples" {
    var samples = Samples{};
    const before = samples;
    try std.testing.expect(!samples.observe(2, base + 16, base + 144, base + 16400));
    try std.testing.expect(!samples.observe(0, 0xfffffff0, 0x70, interrupt(0).?.end - 64));
    try std.testing.expect(!samples.observe(0, bootstrap(0).?.end - 128, bootstrap(0).?.end, interrupt(0).?.end - 63));
    try std.testing.expectEqualDeep(before, samples);
}

test "extra stack frames remain within owner, frame and interrupt bounds" {
    const extra: Region = .{ .start = 0x4ff30000, .end = 0x4ff32000 };
    const irq = interrupt(0).?;
    try std.testing.expect(extraFrameFits(0, extra, extra.end - frame_bytes, extra.end, irq.end - 16));
    try std.testing.expect(!extraFrameFits(1, extra, extra.end - frame_bytes, extra.end, irq.end - 16));
    try std.testing.expect(!extraFrameFits(0, extra, extra.start, extra.start + frame_bytes, irq.end - 16));
    try std.testing.expect(!extraFrameFits(0, extra, extra.end - frame_bytes, extra.end - 16, irq.end - 16));
    try std.testing.expect(!extraFrameFits(0, extra, extra.end - frame_bytes, extra.end, irq.end));
}
