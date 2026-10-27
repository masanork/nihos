//! Opt-in finite microphone input. Raw PCM never leaves internal SRAM.
const options = @import("native_options");
const codec = @import("tab5_es7210");
const speaker = @import("tab5_es8388");
const model = @import("microphone_model");
extern fn nih_microphone_prepare(u32) callconv(.c) bool;
extern fn nih_microphone_start() callconv(.c) bool;
extern fn nih_microphone_status(*model.Status) callconv(.c) void;
extern fn nih_microphone_stop() callconv(.c) bool;
extern fn nih_rom_cache_writeback(u32, u32, u32) callconv(.c) i32;
extern fn nih_rom_cache_invalidate(u32, u32, u32) callconv(.c) i32;
var pcm: [model.bytes]u8 align(64) = @splat(0);
// Isolate the 16-byte hardware descriptor in its own complete cache line.
var node: [4]model.Descriptor align(64) = @splat(.{ .control = 0, .buffer = 0 });
var stats: model.Statistics = .{};
const Input = struct {
    off: bool = false,
    amp_off: bool = false,
    stopped_ok: bool = true,
    returned_ok: bool = true,
    started: bool = false,
    pub fn configure(self: *@This(), bus: anytype) !void {
        try speaker.shutdown(bus);
        self.amp_off = true;
        try codec.prepare(bus);
    }
    pub fn prepare(self: *@This()) !void {
        node[0] = try model.descriptor(@intFromPtr(&node), @intFromPtr(&pcm));
        self.returned_ok = false;
        @memset(&pcm, 0xa5);
        if (nih_rom_cache_writeback(1 << 4, @intFromPtr(&pcm), @sizeOf(@TypeOf(pcm))) != 0 or
            nih_rom_cache_writeback(1 << 4, @intFromPtr(&node), @sizeOf(@TypeOf(node))) != 0) return error.Cache;
        self.stopped_ok = false;
        if (!nih_microphone_prepare(@intFromPtr(&node))) return error.Hardware;
    }
    pub fn unmute(_: *@This(), bus: anytype) !void {
        if (!options.microphone_muted) try codec.unmute(bus);
    }
    pub fn start(self: *@This()) !void {
        // Failed handshake may touch registers, so cleanup still stops DMA.
        if (!nih_microphone_start()) return error.Start;
        self.started = true;
    }
    pub fn status(_: *@This()) model.Status {
        var value: model.Status = .{};
        nih_microphone_status(&value);
        return value;
    }
    pub fn endMatches(_: *@This(), address: u32) bool {
        return address == @intFromPtr(&node);
    }
    pub fn shutdown(self: *@This(), bus: anytype) !void {
        self.off = false;
        try codec.shutdown(bus);
        self.off = self.amp_off;
    }
    pub fn stop(self: *@This()) !void {
        if (!nih_microphone_stop()) return error.Busy;
        self.stopped_ok = true;
        if (nih_rom_cache_invalidate(1 << 4, @intFromPtr(&node), @sizeOf(@TypeOf(node))) != 0 or
            nih_rom_cache_invalidate(1 << 4, @intFromPtr(&pcm), @sizeOf(@TypeOf(pcm))) != 0) return error.Cache;
        const observed: *const volatile model.Descriptor = &node[0];
        if (self.started) {
            if (observed.control & (1 << 31) != 0) return error.Ownership;
        }
        self.returned_ok = true;
    }
    pub fn codecOff(self: *@This()) bool {
        return self.off;
    }
    pub fn stopped(self: *@This()) bool {
        return self.stopped_ok;
    }
    pub fn returned(self: *@This()) bool {
        return self.returned_ok;
    }
    pub fn analyze(_: *@This()) !void {
        const observed: *const volatile model.Descriptor = &node[0];
        try model.validate(observed.*, @intFromPtr(&pcm));
        stats = model.analyze(&pcm);
    }
    pub fn erase(_: *@This()) !void {
        @memset(&pcm, 0);
        std.mem.doNotOptimizeAway(&pcm);
        if (nih_rom_cache_writeback(1 << 4, @intFromPtr(&pcm), @sizeOf(@TypeOf(pcm))) != 0) return error.Cache;
    }
};
const std = @import("std");
var player = model.Player(Input){ .input = .{} };
pub fn request() bool {
    return player.request();
}
pub fn poll(bus: anytype, clock: anytype) void {
    player.poll(bus, clock);
}
pub fn snapshot() model.Report {
    return player.report;
}
pub const Signal = extern struct { active: u32, clipped: u32, peak0: u32, peak1: u32, peak2: u32, peak3: u32, span0: u32, span1: u32, span2: u32, span3: u32 };
pub fn signal() Signal {
    return .{ .active = stats.active, .clipped = stats.clipped, .peak0 = stats.peak[0], .peak1 = stats.peak[1], .peak2 = stats.peak[2], .peak3 = stats.peak[3], .span0 = stats.span[0], .span1 = stats.span[1], .span2 = stats.span[2], .span3 = stats.span[3] };
}
pub fn ioFailure() codec.Failure {
    return codec.failure;
}
