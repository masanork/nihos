//! Local, opt-in native tone fixture. Not an application audio service.
const codec = @import("tab5_es8388");
const tone = @import("audio_tone");
const lifecycle = @import("audio_probe_model");
extern fn nih_audio_tx_prepare(u32) callconv(.c) bool;
extern fn nih_audio_tx_start() callconv(.c) bool;
extern fn nih_audio_tx_status(*lifecycle.Status) callconv(.c) void;
extern fn nih_audio_tx_stop() callconv(.c) bool;
extern fn nih_audio_stage(u32) callconv(.c) void;
extern fn nih_rom_cache_writeback(u32, u32, u32) callconv(.c) i32;
extern fn nih_rom_cache_invalidate(u32, u32, u32) callconv(.c) i32;
var pcm: [tone.block_bytes]u8 align(64) = @splat(0);
var chain: [tone.blocks]tone.Descriptor align(64) = @splat(.{ .control = 0, .buffer = 0, .next = 0 });
const Output = struct {
    codec_off: bool = false,
    is_stopped: bool = true,
    is_returned: bool = true,
    started: bool = false,
    pub fn configure(self: *@This(), bus: anytype) !void {
        try codec.prepare(bus);
        self.codec_off = true;
    }
    pub fn prepare(self: *@This()) !void {
        tone.fill(&pcm);
        try tone.descriptors(&chain, @intFromPtr(&chain), @intFromPtr(&pcm));
        self.is_returned = false;
        nih_audio_stage(1);
        if (nih_rom_cache_writeback(1 << 4, @intFromPtr(&pcm), @sizeOf(@TypeOf(pcm))) != 0 or
            nih_rom_cache_writeback(1 << 4, @intFromPtr(&chain), @sizeOf(@TypeOf(chain))) != 0) return error.Hardware;
        nih_audio_stage(2);
        if (!nih_audio_tx_prepare(@intFromPtr(&chain))) return error.Hardware;
        self.is_stopped = false;
    }
    pub fn start(self: *@This()) !void {
        // A failed start handshake may have touched hardware. Always stop it.
        if (!nih_audio_tx_start()) return error.Start;
        self.started = true;
    }
    pub fn unmute(self: *@This(), bus: anytype) !void {
        self.codec_off = false;
        try codec.unmute(bus);
    }
    pub fn status(_: *@This()) lifecycle.Status {
        var value: lifecycle.Status = .{};
        nih_audio_tx_status(&value);
        return value;
    }
    pub fn endMatches(_: *@This(), address: u32) bool {
        return address == @intFromPtr(&chain[tone.blocks - 1]);
    }
    pub fn mute(self: *@This(), bus: anytype) !void {
        self.codec_off = false;
        try codec.shutdown(bus);
        self.codec_off = true;
    }
    pub fn stop(self: *@This()) !void {
        if (!nih_audio_tx_stop()) return error.Busy;
        self.is_stopped = true;
        // Retain static storage forever on cache/ownership failure. No reset
        // or timer expiration alone can authorize rewriting DMA-owned nodes.
        if (nih_rom_cache_invalidate(1 << 4, @intFromPtr(&chain), @sizeOf(@TypeOf(chain))) != 0) return error.Cache;
        if (self.started) for (&chain) |*node| {
            const observed: *const volatile tone.Descriptor = node;
            if (observed.control & (1 << 31) != 0) return error.Ownership;
        };
        self.is_returned = true;
    }
    pub fn codecOff(self: *@This()) bool {
        return self.codec_off;
    }
    pub fn stopped(self: *@This()) bool {
        return self.is_stopped;
    }
    pub fn returned(self: *@This()) bool {
        return self.is_returned;
    }
};
var player = lifecycle.Player(Output){ .output = .{} };
pub fn request() bool {
    return player.request();
}
pub fn poll(bus: anytype, clock: anytype) void {
    player.poll(bus, clock);
}
pub fn snapshot() lifecycle.Report {
    return player.report;
}
pub fn ioFailure() codec.Failure {
    return codec.failure;
}
