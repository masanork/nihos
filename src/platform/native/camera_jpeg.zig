//! Opt-in, CPU0-only JPEG fixture: known RGB565 bars, then one real ISP frame.
//! No SD write, streaming JPEG, user API or buffer retirement is claimed.
const options = @import("native_options");
const board = @import("board_devices.zig");
const workspace = @import("csi_workspace.zig");
extern fn nih_jpeg_begin(u32, u32, u32) callconv(.c) i32;
extern fn nih_jpeg_poll() callconv(.c) i32;
extern fn nih_jpeg_status(u32) callconv(.c) u32;
extern fn nih_jpeg_abort() callconv(.c) void;
extern fn nih_rom_cache_writeback(u32, u32, u32) callconv(.c) i32;
extern fn nih_rom_cache_invalidate(u32, u32, u32) callconv(.c) i32;
extern fn nih_diagnostic_serial_write(u8) callconv(.c) void;
const Phase = enum(u32) { idle, prepare, pattern, output, begin, encode, export_data, clear_source, capture, wait_capture, invalidate_source, done, failed };
var phase: Phase = .idle;
var offset: usize = 0;
var kind: u32 = 0;
var source_hash: u32 = 2166136261;
var output_hash: u32 = 2166136261;
var encoded_bytes: usize = 0;
var encode_started: u64 = 0;
var deadline: u64 = 0;
noinline fn write(bytes: []const u8) linksection(".flash.text.devices") void {
    for (bytes) |b| nih_diagnostic_serial_write(b);
}
noinline fn hex(value: u32) linksection(".flash.text.devices") void {
    const digits = "0123456789abcdef";
    var shift: u5 = 28;
    while (true) {
        nih_diagnostic_serial_write(digits[(value >> shift) & 15]);
        if (shift == 0) break;
        shift -= 4;
    }
}
noinline fn field(name: []const u8, value: u32) linksection(".flash.text.devices") void {
    write(" ");
    write(name);
    write("=");
    hex(value);
}
noinline fn sync(bytes: []u8, invalidate: bool) linksection(".flash.text.devices") bool {
    const previous = asm volatile ("csrrci %[previous], mstatus, 8"
        : [previous] "=r" (-> u32),
        :
        : .{ .memory = true });
    defer if (previous & 8 != 0) asm volatile ("csrsi mstatus, 8" ::: .{ .memory = true });
    const address: u32 = @intCast(@intFromPtr(bytes.ptr));
    const status = if (invalidate) nih_rom_cache_invalidate(48, address, @intCast(bytes.len)) else nih_rom_cache_writeback(48, address, @intCast(bytes.len));
    asm volatile ("fence iorw,iorw" ::: .{ .memory = true });
    return status == 0;
}
noinline fn fail(code: u32) linksection(".flash.text.devices") void {
    nih_jpeg_abort();
    write("\nNIHOS_JPEG_FAIL");
    field("stage", @backingInt(phase));
    field("code", code);
    field("rx", nih_jpeg_status(0));
    field("tx", nih_jpeg_status(1));
    field("jpeg", nih_jpeg_status(2));
    const snapshot = board.cameraFirstFrameSnapshot();
    const detail = board.cameraFirstFrameDetail();
    field("capture", snapshot.result);
    field("reason", detail.reason);
    write("\n");
    phase = .failed;
}
pub noinline fn poll() linksection(".flash.text.devices") void {
    if (!options.camera_jpeg) return;
    const now = board.cameraJpegClock() orelse return;
    if (phase == .idle) {
        if (now < 10_000_000) return;
        if (!workspace.begin()) return fail(1);
        phase = .prepare;
    }
    if (phase == .prepare) {
        for (0..128) |_| {
            workspace.poll();
            if (workspace.phase() == .pinned) return fail(2);
            if (workspace.phase() == .ready_dma) {
                phase = .pattern;
                break;
            }
            if ((board.cameraJpegClock() orelse now) - now >= 1000) break;
        }
        return;
    }
    const address = workspace.address() orelse return;
    const source = @as([*]u8, @ptrFromInt(address))[0..workspace.frame_bytes];
    const destination = @as([*]u8, @ptrFromInt(address + workspace.frame_bytes))[0..workspace.frame_bytes];
    if (phase == .pattern or phase == .clear_source or phase == .invalidate_source) {
        for (0..128) |_| {
            const chunk = source[offset..][0..1024];
            if (phase == .pattern) {
                const colors = [_]u16{ 0xf800, 0x07e0, 0x001f, 0xffff, 0, 0x07ff, 0xf81f, 0xffe0 };
                for (0..512) |pixel| {
                    const color = colors[((offset / 2 + pixel) % 1280) / 160];
                    chunk[pixel * 2] = @truncate(color);
                    chunk[pixel * 2 + 1] = @truncate(color >> 8);
                }
                if (!sync(chunk, false)) return fail(3);
            } else if (phase == .clear_source) {
                @memset(chunk, 0);
                if (!sync(chunk, false)) return fail(4);
            }
            if (!sync(chunk, true)) return fail(5);
            if (phase != .clear_source) {
                for (chunk) |b| source_hash = (source_hash ^ b) *% 16777619;
            }
            offset += 1024;
            if (offset == source.len) {
                offset = 0;
                phase = if (phase == .clear_source) .capture else .output;
                break;
            }
            if ((board.cameraJpegClock() orelse now) - now >= 1000) break;
        }
        return;
    }
    if (phase == .output) {
        for (0..128) |_| {
            const ready = workspace.prepareStreamSecond() orelse return fail(6);
            if (ready) {
                phase = .begin;
                break;
            }
            if ((board.cameraJpegClock() orelse now) - now >= 1000) break;
        }
        return;
    }
    if (phase == .capture) {
        if (!board.requestDevice(26)) return fail(7);
        deadline = now + 10_000_000;
        phase = .wait_capture;
        return;
    }
    if (phase == .wait_capture) {
        if (board.cameraCaptureFailed() or now >= deadline) return fail(8);
        if (board.cameraJpegFrame() != null) {
            phase = .invalidate_source;
            source_hash = 2166136261;
        }
        return;
    }
    if (phase == .begin) {
        const previous = asm volatile ("csrrci %[previous], mstatus, 8"
            : [previous] "=r" (-> u32),
            :
            : .{ .memory = true });
        const status = nih_jpeg_begin(address, address + workspace.frame_bytes, workspace.frame_bytes);
        if (previous & 8 != 0) asm volatile ("csrsi mstatus, 8" ::: .{ .memory = true });
        if (status != 0) return fail(@bitCast(status));
        encode_started = now;
        deadline = now + 5_000_000;
        phase = .encode;
        return;
    }
    if (phase == .encode) {
        const result = nih_jpeg_poll();
        if (result < 0 or now >= deadline) return fail(if (result < 0) @bitCast(result) else 9);
        if (result == 0) return;
        encoded_bytes = @intCast(result);
        if (encoded_bytes > destination.len or destination[0] != 0xff or destination[1] != 0xd8 or destination[encoded_bytes - 2] != 0xff or destination[encoded_bytes - 1] != 0xd9) return fail(10);
        write("\nNIHOS_JPEG_BEGIN");
        field("kind", kind);
        field("bytes", @intCast(encoded_bytes));
        field("width", 1280);
        field("height", 720);
        field("quality", 75);
        field("source_fnv", source_hash);
        field("encode_us", @intCast(now - encode_started));
        write("\n");
        phase = .export_data;
        return;
    }
    if (phase == .export_data) {
        const end = @min(offset + 96, encoded_bytes);
        write("\nNIHOS_JPEG_DATA");
        field("kind", kind);
        field("offset", @intCast(offset));
        write(" data=");
        const digits = "0123456789abcdef";
        for (destination[offset..end]) |b| {
            nih_diagnostic_serial_write(digits[b >> 4]);
            nih_diagnostic_serial_write(digits[b & 15]);
            output_hash = (output_hash ^ b) *% 16777619;
        }
        write("\n");
        offset = end;
        if (offset == encoded_bytes) {
            write("NIHOS_JPEG_END");
            field("kind", kind);
            field("bytes", @intCast(encoded_bytes));
            field("fnv", output_hash);
            write("\n");
            offset = 0;
            output_hash = 2166136261;
            if (kind == 0) {
                kind = 1;
                phase = .clear_source;
            } else {
                phase = .done;
                write("NIHOS_JPEG_DONE\n");
            }
        }
    }
}
