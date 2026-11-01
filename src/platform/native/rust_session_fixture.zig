//! Headless normal-profile emulator fixture for the actual UI session backend.
//! No scanout claim: host tests separately check the shared rotated copy.
const app = @import("display_service").ui.rust_session;
const tasks = @import("native_tasks");
const clock = @import("timer_group").Timer.fromGroup(0x500c2000, 0).?;
extern fn nih_rom_rx_one_char(*u8) callconv(.c) i32;
var began: u64 = 0;
var free_before: usize = 0;
var charged: usize = 0;
var ticks_before: [2]u32 = .{ 0, 0 };
var presentations: u32 = 0;
var ready_hash: u32 = 0;
var selected: u32 = 0;
var received: u32 = 0;
var rejected: u32 = 0;
var input_frames: u32 = 0;
var ended: bool = false;
var ending_at: u64 = 0;
var result: i32 = 0;
fn present(bytes: [*]const u8, len: u32) callconv(.c) i32 {
    if (len != 25600) return -1;
    const pressed = bytes[0] == 0x0c and bytes[1] == 0x22;
    if (!pressed and (bytes[0] != 0x82 or bytes[1] != 0x10)) return -1;
    var hash: u32 = 2166136261;
    for (bytes[0..len]) |byte| hash = (hash ^ byte) *% 16777619;
    if (presentations == 0) ready_hash = hash;
    if (!pressed and hash != ready_hash) return -1;
    selected = @intFromBool(pressed);
    presentations += 1;
    return 0;
}
pub fn start() bool {
    began = clock.counter() orelse return false;
    free_before = (tasks.memory.reusable.localUsage() orelse return false).free;
    ticks_before = .{ tasks.report(0).ticks, tasks.report(1).ticks };
    if (app.start(&present) != 0) return false;
    charged = free_before - (tasks.memory.reusable.localUsage() orelse return false).free;
    return true;
}
pub fn service(log: anytype) bool {
    const now = clock.counter() orelse return false;
    if (!ended) {
        var byte: u8 = 0;
        if (nih_rom_rx_one_char(&byte) == 0) {
            received += 1;
            const before = app.frames();
            result = app.input(byte);
            if (byte == 'x') {
                const valid = result == -1 and app.frames() == before;
                rejected += 1;
                result = if (valid) 0 else -44;
            } else if (byte == '0' or byte == '1') {
                if (result != 0 or input_frames >= 3 or selected != ([_]u32{ 0, 1, 0 })[input_frames]) result = -44;
                input_frames += 1;
            } else if (byte != 'q' or result != 0 or input_frames != 3 or rejected != 1) result = -44;
            if (received > 16) result = -43;
        }
        if (now - began > 500_000) result = -42;
        if (result != 0 or !app.active()) {
            _ = app.cancel();
            ended = true;
            ending_at = now;
        }
        return true;
    }
    // Keep normal timers/idle running for two more periods after cleanup.
    if (now - ending_at < 20_000) return true;
    const free_after = (tasks.memory.reusable.localUsage() orelse return false).free;
    const report: extern struct {
        status: u32,
        bytes: u32,
        input_frames: u32,
        presentations: u32,
        rejected: u32,
        released: u32,
        requested: u32,
        charged: u32,
        free_before: u32,
        free_after: u32,
        ticks0: u32,
        ticks1: u32,
    } = .{
        .status = @as(u32, @bitCast(result)),
        .bytes = received,
        .input_frames = input_frames,
        .presentations = presentations,
        .rejected = rejected,
        .released = @as(u32, @intFromBool(!app.active() and free_after == free_before)),
        .requested = @as(u32, 32768),
        .charged = @as(u32, @intCast(charged)),
        .free_before = @as(u32, @intCast(free_before)),
        .free_after = @as(u32, @intCast(free_after)),
        .ticks0 = tasks.report(0).ticks -% ticks_before[0],
        .ticks1 = tasks.report(1).ticks -% ticks_before[1],
    };
    log.record("NIHOS_NATIVE_RUST_SESSION", null, .{ "status", "bytes", "input_frames", "presentations", "rejected", "released", "requested", "charged", "free_before", "free_after", "ticks0", "ticks1" }, &report);
    return false; // Caller prints a finite completion marker after this record.
}
